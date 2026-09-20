// The CSV reader has to cope with what spreadsheet exports really look like.

import { test } from "node:test";
import assert from "node:assert/strict";
import { parseCsv, readCsvRows } from "../scripts/lib/csv.mjs";

test("a byte order mark does not become part of the first column name", () => {
  const { records } = readCsvRows("﻿site_code,site_type\nRES-0001,residential\n", {
    fileName: "land_sites.csv",
    required: ["site_code", "site_type"],
  });
  assert.deepEqual(records, [{ site_code: "RES-0001", site_type: "residential" }]);
});

test("quoted values may contain commas", () => {
  const rows = parseCsv('a,b\n"12 Main Street, Ext 4",residential\n');
  assert.deepEqual(rows[1], ["12 Main Street, Ext 4", "residential"]);
});

test("quoted values may contain quotes and newlines", () => {
  const rows = parseCsv('a,b\n"He said ""hello""","line one\nline two"\n');
  assert.deepEqual(rows[1], ['He said "hello"', "line one\nline two"]);
});

test("CRLF line endings are handled", () => {
  const rows = parseCsv("a,b\r\n1,2\r\n");
  assert.deepEqual(rows, [["a", "b"], ["1", "2"]]);
});

test("trailing blank lines are ignored", () => {
  const rows = parseCsv("a,b\n1,2\n\n\n");
  assert.equal(rows.length, 2);
});

test("an empty quoted value is kept", () => {
  const rows = parseCsv('a,b\n"",2\n');
  assert.deepEqual(rows[1], ["", "2"]);
});

test("values are trimmed", () => {
  const { records } = readCsvRows("code,name\n  R-0001 , Jane \n", {
    fileName: "residents.csv",
    required: ["code", "name"],
  });
  assert.deepEqual(records, [{ code: "R-0001", name: "Jane" }]);
});

test("a missing required column is reported", () => {
  assert.throws(
    () => readCsvRows("site_code\nRES-0001\n", {
      fileName: "land_sites.csv",
      required: ["site_code", "street_address"],
    }),
    /missing the column\(s\): street_address/,
  );
});

test("columns that are not imported are reported rather than dropped silently", () => {
  const { records, ignored } = readCsvRows(
    "site_code,notes,data_source\nRES-0001,something,spreadsheet\n",
    { fileName: "land_sites.csv", required: ["site_code"] },
  );
  assert.deepEqual(ignored, ["notes", "data_source"]);
  assert.deepEqual(records, [{ site_code: "RES-0001" }]);
});

test("a short row is a hard error, not a silent shift", () => {
  assert.throws(
    () => readCsvRows("a,b,c\n1,2\n", { fileName: "x.csv", required: ["a", "b", "c"] }),
    /line 2 has 2 value\(s\) but the header has 3/,
  );
});

test("an unterminated quote is a hard error", () => {
  assert.throws(() => parseCsv('a,b\n"unclosed,2\n'), /ends inside a quoted value/);
});

test("optional columns missing from the file come back empty", () => {
  const { records } = readCsvRows("id_number\n8001015800081\n", {
    fileName: "residents.csv",
    required: ["id_number"],
    optional: ["email"],
  });
  assert.deepEqual(records, [{ id_number: "8001015800081", email: "" }]);
});
