#!/usr/bin/env node
// =====================================================================
// The one-time legacy village data import.
//
//   SUPABASE_URL=https://<ref>.supabase.co \
//   SUPABASE_SERVICE_ROLE_KEY=<service role key> \
//   node scripts/import-legacy-data.mjs data/legacy-import
//
// Add --dry-run to read and check the files and print what would be
// sent, without touching the database.
//
// This is deliberately a command you run yourself, not a page in the
// application. The service role key belongs in this terminal and
// nowhere near the browser.
//
// The database does the work in one transaction: it validates the whole
// dataset first and writes nothing at all unless everything passes.
// =====================================================================

import { createClient } from "@supabase/supabase-js";
import { buildImportPayload } from "./lib/import-payload.mjs";

const directory = process.argv[2] ?? "data/legacy-import";
const dryRun = process.argv.includes("--dry-run");

const url = process.env.SUPABASE_URL;
const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!dryRun && (!url || !serviceRoleKey)) {
  console.error("Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY, or pass --dry-run.");
  process.exit(2);
}

let payload, summary;
try {
  ({ payload, summary } = await buildImportPayload(directory));
} catch (error) {
  console.error(`\nThe files could not be read:\n  ${error.message}\n`);
  process.exit(1);
}

console.log(`\nRead from ${directory}:`);
for (const file of summary) {
  console.log(`  ${file.fileName.padEnd(28)} ${String(file.rows).padStart(5)} row(s)`);
  if (file.ignoredColumns.length > 0) {
    console.log(`  ${" ".repeat(28)}       ignored column(s): ${file.ignoredColumns.join(", ")}`);
  }
}

if (dryRun) {
  console.log("\nDry run: nothing was sent to the database.\n");
  process.exit(0);
}

console.log("\nSending to the database for validation and import…");

const supabase = createClient(url, serviceRoleKey, {
  auth: { persistSession: false, autoRefreshToken: false },
});

const { data, error } = await supabase.rpc("import_legacy_village_data", { p_payload: payload });

if (error) {
  console.error(`\nThe import did not run. Nothing was written.\n\n${error.message}\n`);
  process.exit(1);
}

console.log("\nImported successfully:\n");
for (const [name, count] of Object.entries(data)) {
  console.log(`  ${name.replace(/_/g, " ").padEnd(32)} ${count}`);
}
console.log("");
