#!/usr/bin/env node
// Prints the import payload as JSON. Used by the test suite, and handy
// for inspecting what would be sent before sending it.
//
//   node scripts/build-import-payload.mjs data/legacy-import > payload.json

import { buildImportPayload } from "./lib/import-payload.mjs";

const directory = process.argv[2];
if (!directory) {
  console.error("Usage: node scripts/build-import-payload.mjs <directory-of-csv-files>");
  process.exit(2);
}

try {
  const { payload } = await buildImportPayload(directory);
  process.stdout.write(JSON.stringify(payload));
} catch (error) {
  console.error(error.message);
  process.exit(1);
}
