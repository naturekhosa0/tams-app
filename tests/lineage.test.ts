// Two things are easy to get wrong here, and both would mislead a clerk
// reading someone's family: which way round a relationship points, and
// which relationships are permanent.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  groupLineage, isTimeBased, mayBeEnded, relationshipPeriod,
  relationshipSentence, RELATIONSHIP_GROUPS, sectionGroups,
} from "../src/registry/lineage.ts";
import type { LineageRow } from "../src/registry/types.ts";

const row = (
  type: string,
  name: string,
  status: "active" | "inactive" = "active",
  started: string | null = null,
  ended: string | null = null,
): LineageRow => ({
  relationship_id: `${type}-${name}-${status}-${started ?? ""}`,
  relationship_type: type as LineageRow["relationship_type"],
  relationship_status: status,
  relationship_started_at: started,
  relationship_ended_at: ended,
  time_based: ["spouse", "guardian", "dependant"].includes(type),
  related_resident_id: name,
  related_full_name: name,
  related_id_number: "SYN0000000000",
  related_status: "active",
  related_household_code: "HH-0001",
});

// ---- which way round ------------------------------------------------

test("someone this resident is the parent of is shown as their child", () => {
  assert.deepEqual(groupLineage([row("parent", "Kabelo")]).map((g) => g.heading), ["Children"]);
});

test("someone this resident is the child of is shown as their parent", () => {
  assert.deepEqual(groupLineage([row("child", "Samuel")]).map((g) => g.heading), ["Parents"]);
});

test("grandparent and grandchild are shown the other way round too", () => {
  assert.deepEqual(groupLineage([row("grandparent", "Thato")]).map((g) => g.heading), ["Grandchildren"]);
  assert.deepEqual(groupLineage([row("grandchild", "Samuel")]).map((g) => g.heading), ["Grandparents"]);
});

test("a guardian is shown as a dependant, and the other way round", () => {
  assert.deepEqual(groupLineage([row("guardian", "Ward")]).map((g) => g.heading), ["Current dependants"]);
  assert.deepEqual(groupLineage([row("dependant", "Carer")]).map((g) => g.heading), ["Current guardians"]);
});

// ---- permanent against time-based -----------------------------------

test("lineage is permanent; marriage and guardianship are not", () => {
  for (const type of ["parent", "child", "sibling", "grandparent", "grandchild"]) {
    assert.equal(isTimeBased(type as never), false, `${type} should be permanent`);
  }
  for (const type of ["spouse", "guardian", "dependant"]) {
    assert.equal(isTimeBased(type as never), true, `${type} should be time based`);
  }
});

test("permanent lineage is never offered an ending", () => {
  for (const type of ["parent", "child", "sibling", "grandparent", "grandchild"]) {
    assert.equal(mayBeEnded(row(type, "Someone")), false, `${type} must not be endable`);
  }
});

test("a current marriage or guardianship can be ended; one already ended cannot", () => {
  assert.equal(mayBeEnded(row("spouse", "Maria")), true);
  assert.equal(mayBeEnded(row("guardian", "Ward")), true);
  assert.equal(mayBeEnded(row("spouse", "Maria", "inactive", "2010-05-15", "2022-08-01")), false);
});

test("permanent lineage is shown whatever its status", () => {
  // Nothing should ever set one inactive, but if one were, it would
  // still be that person's parent and must not silently vanish.
  assert.deepEqual(groupLineage([row("child", "Samuel", "inactive")]).map((g) => g.heading), ["Parents"]);
});

// ---- current against former -----------------------------------------

test("a marriage that has ended moves to Former spouse", () => {
  const rows = [
    row("spouse", "Lerato", "inactive", "2010-05-15", "2022-08-01"),
    row("spouse", "Lerato", "active", "2025-03-10"),
  ];
  assert.deepEqual(groupLineage(rows).map((g) => g.heading), ["Current spouse", "Former spouse"]);
});

test("remarrying the same person leaves both episodes on the page", () => {
  const rows = [
    row("spouse", "Lerato", "inactive", "2010-05-15", "2022-08-01"),
    row("spouse", "Lerato", "active", "2025-03-10"),
  ];
  const current = sectionGroups(rows, "current");
  const former = sectionGroups(rows, "former");
  assert.equal(current[0].rows[0].relationship_started_at, "2025-03-10");
  assert.equal(former[0].rows[0].relationship_ended_at, "2022-08-01");
});

test("more than one current spouse is shown, not hidden", () => {
  const rows = [row("spouse", "Lerato", "active", "2025-03-10"), row("spouse", "Naledi", "active", "2025-09-01")];
  assert.equal(sectionGroups(rows, "current")[0].rows.length, 2);
});

test("the three sections keep their order and drop what is empty", () => {
  const rows = [
    row("child", "Samuel"),
    row("spouse", "Maria", "active", "2015-06-20"),
    row("spouse", "Lerato", "inactive", "2005-01-01", "2012-01-01"),
  ];
  assert.deepEqual(groupLineage(rows).map((g) => [g.section, g.heading]), [
    ["permanent", "Parents"],
    ["current", "Current spouse"],
    ["former", "Former spouse"],
  ]);
});

// ---- wording ---------------------------------------------------------

test("dates are shown where they are known, and left out where they are not", () => {
  const show = (value: string) => value;
  assert.equal(relationshipPeriod(row("spouse", "M", "active", "2010-05-15"), show), "Started 2010-05-15");
  assert.equal(
    relationshipPeriod(row("spouse", "M", "inactive", "2010-05-15", "2022-08-01"), show),
    "Started 2010-05-15 · Ended 2022-08-01",
  );
  // The imported relationships have no dates at all.
  assert.equal(relationshipPeriod(row("parent", "K"), show), "");
});

test("the long form states the direction in words", () => {
  assert.equal(
    relationshipSentence("Samuel Rachidi", row("parent", "Kabelo Rachidi")),
    "Samuel Rachidi is the parent of Kabelo Rachidi",
  );
});

test("every relationship type has somewhere to go", () => {
  const covered = [...new Set(RELATIONSHIP_GROUPS.map((group) => group.fromType))].sort();
  assert.deepEqual(covered, [
    "child", "dependant", "grandchild", "grandparent", "guardian", "parent", "sibling", "spouse",
  ]);
});
