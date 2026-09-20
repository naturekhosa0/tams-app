// Turns the six legacy CSV files into the single JSON document that
// public.import_legacy_village_data() validates and writes.
//
// Only the columns listed here are read. Anything else in a file — a
// note, a data_source, an occupancy_status — is reported and left out,
// because none of it has a place in the database.

import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { readCsvRows } from "./csv.mjs";

export const FILES = [
  {
    key: "land_sites",
    fileName: "land_sites.csv",
    required: ["site_code", "site_type", "street_address", "site_status"],
    optional: ["stand_number", "village_section", "village_name"],
  },
  {
    key: "residents",
    fileName: "residents.csv",
    required: ["resident_code", "id_number", "first_name", "last_name",
               "date_of_birth", "gender", "resident_status"],
    optional: ["contact_number", "email"],
  },
  {
    key: "households",
    fileName: "households.csv",
    required: ["household_code", "primary_site_code", "household_status"],
    optional: ["head_resident_code"],
  },
  {
    key: "household_memberships",
    fileName: "household_memberships.csv",
    required: ["household_code", "resident_code"],
  },
  {
    key: "family_relationships",
    fileName: "family_relationships.csv",
    required: ["resident_code", "related_resident_code", "relationship_type", "relationship_status"],
  },
  {
    key: "land_allocations",
    fileName: "land_allocations.csv",
    required: ["allocation_code", "site_code", "allocated_to_resident_code",
               "allocation_date", "allocation_status"],
  },
];

/**
 * Reads every file in the import order and returns
 * { payload, summary } — summary describing what was read and what was
 * ignored, for the operator to look at before committing.
 */
export async function buildImportPayload(directory) {
  const payload = {};
  const summary = [];

  for (const file of FILES) {
    let text;
    try {
      text = await readFile(join(directory, file.fileName), "utf8");
    } catch {
      throw new Error(
        `${file.fileName} was not found in ${directory}. ` +
          `All six files are needed: ${FILES.map((f) => f.fileName).join(", ")}.`,
      );
    }

    const { records, ignored } = readCsvRows(text, {
      fileName: file.fileName,
      required: file.required,
      optional: file.optional ?? [],
    });

    payload[file.key] = records;
    summary.push({ fileName: file.fileName, rows: records.length, ignoredColumns: ignored });
  }

  return { payload, summary };
}
