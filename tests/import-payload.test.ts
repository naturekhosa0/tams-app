// The payload builder reads the real CSV package and shapes it for
// public.import_legacy_village_data().

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, writeFile, rm, copyFile, readdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildImportPayload, FILES } from "../scripts/lib/import-payload.mjs";

const REAL_DATA = new URL("../data/legacy-import/", import.meta.url).pathname;

test("the supplied CSV package reads into a payload", async () => {
  const { payload, summary } = await buildImportPayload(REAL_DATA);

  assert.deepEqual(
    summary.map((file) => [file.fileName, file.rows]),
    [
      ["land_sites.csv", 20],
      ["residents.csv", 70],
      ["households.csv", 20],
      ["household_memberships.csv", 70],
      ["family_relationships.csv", 200],
      ["land_allocations.csv", 20],
    ],
  );
  assert.deepEqual(summary.flatMap((file) => file.ignoredColumns), [], "no column should be silently dropped");
});

test("every import code the other files refer to exists", async () => {
  const { payload } = await buildImportPayload(REAL_DATA);

  const siteCodes = new Set(payload.land_sites.map((s) => s.site_code));
  const residentCodes = new Set(payload.residents.map((r) => r.resident_code));
  const householdCodes = new Set(payload.households.map((h) => h.household_code));

  for (const household of payload.households) {
    assert.ok(siteCodes.has(household.primary_site_code), `unknown site ${household.primary_site_code}`);
    assert.ok(residentCodes.has(household.head_resident_code), `unknown head ${household.head_resident_code}`);
  }
  for (const membership of payload.household_memberships) {
    assert.ok(householdCodes.has(membership.household_code));
    assert.ok(residentCodes.has(membership.resident_code));
  }
  for (const allocation of payload.land_allocations) {
    assert.ok(siteCodes.has(allocation.site_code));
    assert.ok(residentCodes.has(allocation.allocated_to_resident_code));
  }
});

test("the head of each household is one of its members", async () => {
  const { payload } = await buildImportPayload(REAL_DATA);
  const members = new Map();
  for (const membership of payload.household_memberships) {
    if (!members.has(membership.household_code)) members.set(membership.household_code, new Set());
    members.get(membership.household_code).add(membership.resident_code);
  }
  for (const household of payload.households) {
    assert.ok(
      members.get(household.household_code)?.has(household.head_resident_code),
      `${household.household_code}: head is not a member`,
    );
  }
});

test("the data includes households whose head is not the allocation holder", async () => {
  const { payload } = await buildImportPayload(REAL_DATA);
  const holderOfSite = new Map(
    payload.land_allocations.map((a) => [a.site_code, a.allocated_to_resident_code]),
  );
  const differing = payload.households.filter(
    (h) => holderOfSite.get(h.primary_site_code) !== h.head_resident_code,
  );
  assert.ok(differing.length > 0, "the two concepts must be able to differ");
});

test("a missing file is reported by name", async () => {
  const directory = await mkdtemp(join(tmpdir(), "tams-import-"));
  try {
    await writeFile(join(directory, "land_sites.csv"), "site_code\nRES-0001\n");
    await assert.rejects(
      () => buildImportPayload(directory),
      /land_sites\.csv is missing the column/,
    );
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("an entirely absent file names all six that are needed", async () => {
  const directory = await mkdtemp(join(tmpdir(), "tams-import-"));
  try {
    await assert.rejects(
      () => buildImportPayload(directory),
      /land_sites\.csv was not found.*All six files are needed/s,
    );
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("columns the database has no home for are reported, not imported", async () => {
  const directory = await mkdtemp(join(tmpdir(), "tams-import-"));
  try {
    for (const name of await readdir(REAL_DATA)) {
      if (name.endsWith(".csv")) await copyFile(join(REAL_DATA, name), join(directory, name));
    }
    // A file that still carries the columns the cleaned package drops.
    await writeFile(
      join(directory, "land_sites.csv"),
      "site_code,site_type,stand_number,street_address,village_section,village_name,site_status,notes,data_source\n" +
        "RES-0001,residential,ST-1001,13 Marula Street,Central,Mahlasedi,allocated,some note,a spreadsheet\n",
    );
    const { payload, summary } = await buildImportPayload(directory);
    const sites = summary.find((file) => file.fileName === "land_sites.csv");

    assert.deepEqual(sites.ignoredColumns, ["notes", "data_source"]);
    assert.deepEqual(Object.keys(payload.land_sites[0]).sort(), [
      "site_code", "site_status", "site_type", "stand_number",
      "street_address", "village_name", "village_section",
    ].sort());
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("the import order matches the order the files must be read in", () => {
  assert.deepEqual(FILES.map((file) => file.fileName), [
    "land_sites.csv",
    "residents.csv",
    "households.csv",
    "household_memberships.csv",
    "family_relationships.csv",
    "land_allocations.csv",
  ]);
});
