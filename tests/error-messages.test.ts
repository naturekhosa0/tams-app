// =====================================================================
// What somebody sees when something goes wrong.
//
// TAMS raises its own refusals, in words written for the person at the
// screen, and those must survive untouched. Everything else — the
// things PostgreSQL and PostgREST say to a developer reading a log —
// must never reach a page.
// =====================================================================

import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";

import { GENERIC_FAILURE, readableError } from "../src/lib/errorMessage.ts";

const root = path.resolve(import.meta.dirname, "..");
const read = (file: string) => readFileSync(path.join(root, file), "utf8");

// ---------------------------------------------------------------------
// TAMS's own wording is the wording.
// ---------------------------------------------------------------------

test("a refusal TAMS wrote is shown exactly as written", () => {
  for (const message of [
    "The outgoing administrator must take one of the three ordinary roles.",
    "An applicant must be 21 or older.",
    "This household already holds farming land.",
    "Choose the ordinary role the outgoing administrator will hold.",
  ]) {
    assert.equal(readableError(message), message);
  }
});

test("the SQLSTATE Supabase prepends is stripped, and the sentence kept", () => {
  assert.equal(
    readableError("TA135: The transfer would not have left exactly one active Council Administrator."),
    "The transfer would not have left exactly one active Council Administrator.",
  );
  assert.equal(readableError("P0001: That site is already allocated."), "That site is already allocated.");
});

// ---------------------------------------------------------------------
// The database's own wording never reaches a page.
// ---------------------------------------------------------------------

test("a constraint violation becomes something a person can act on", () => {
  const duplicate = readableError(
    'duplicate key value violates unique constraint "residents_id_number_key"',
  );
  assert.match(duplicate, /already exists/);
  assert.ok(!duplicate.includes("residents_id_number_key"));
  assert.ok(!duplicate.includes("constraint"));

  const foreign = readableError(
    'insert or update on table "ptos" violates foreign key constraint "ptos_land_allocation_id_fkey"',
  );
  assert.match(foreign, /no longer there/);
  assert.ok(!foreign.includes("ptos_land_allocation_id_fkey"));
});

test("two people saving at the same moment is explained, not dumped", () => {
  const clash = readableError("could not serialize access due to concurrent update");
  assert.match(clash, /at the same moment/);
  assert.match(clash, /try again/);

  assert.match(readableError("deadlock detected"), /at the same moment/);
});

test("a refused privilege becomes a sentence about roles", () => {
  const denied = readableError("permission denied for table residents");
  assert.match(denied, /role does not allow/);
  assert.ok(!denied.includes("permission denied"));
  assert.ok(!denied.includes("table"));
});

test("anything else that reads like the database is replaced wholesale", () => {
  for (const raw of [
    'relation "public.residents" does not exist',
    'column "id_numberr" of relation "residents" does not exist',
    "function public.registry_search_residents(unknown) does not exist",
    "invalid input syntax for type uuid: \"not-a-uuid\"",
    "syntax error at or near \"SELECT\"",
    "Could not find the function public.foo(bar) in the schema cache",
    "JSON object requested, multiple (or no) rows returned",
    "pg_catalog.pg_class is not accessible",
  ]) {
    assert.equal(readableError(raw), GENERIC_FAILURE, `leaked: ${raw}`);
  }
});

test("a stack trace never reaches a page", () => {
  const trace = "TypeError: x is not a function\n    at load (/app/src/registry/api.ts:42:17)";
  assert.equal(readableError(trace), GENERIC_FAILURE);
});

test("nothing at all still says something", () => {
  for (const nothing of [null, undefined, "", "   "]) {
    assert.equal(readableError(nothing), GENERIC_FAILURE);
  }
});

test("the generic failure says what to do and blames nobody", () => {
  assert.match(GENERIC_FAILURE, /try again/i);
  assert.ok(!/error|failed|invalid/i.test(GENERIC_FAILURE));
});

// ---------------------------------------------------------------------
// Every module that talks to the database goes through it.
// ---------------------------------------------------------------------

test("every API module translates its refusals", () => {
  for (const file of [
    "src/registry/api.ts", "src/registry/adminApi.ts", "src/registry/landApi.ts",
    "src/registry/residentApi.ts", "src/registry/secretaryApi.ts",
  ]) {
    const source = read(file);
    assert.match(source, /readableError\(error\.message\)/, `${file} does not translate refusals`);
    // And none of them passes the raw message through beside it.
    assert.ok(
      !/message:\s*error\.message/.test(source),
      `${file} passes a raw message straight through`,
    );
  }
});

test("no page interpolates a raw error into what it shows", () => {
  function sources(dir: string): string[] {
    return readdirSync(path.join(root, dir)).flatMap((entry) => {
      const rel = path.join(dir, entry);
      if (statSync(path.join(root, rel)).isDirectory()) return sources(rel);
      return /\.tsx?$/.test(entry) ? [rel] : [];
    });
  }

  for (const file of sources("src/pages")) {
    const source = read(file);
    // `${...error.message}` inside JSX is the shape that leaks.
    assert.ok(
      !/\$\{[^}]*\berror\.message\b[^}]*\}/.test(source),
      `${file} interpolates a raw error message`,
    );
  }
});

// ---------------------------------------------------------------------
// Empty states say what is empty.
// ---------------------------------------------------------------------

test("no list falls back to a bare \"Nothing here\"", () => {
  function sources(dir: string): string[] {
    return readdirSync(path.join(root, dir)).flatMap((entry) => {
      const rel = path.join(dir, entry);
      if (statSync(path.join(root, rel)).isDirectory()) return sources(rel);
      return /\.tsx?$/.test(entry) ? [rel] : [];
    });
  }

  for (const file of sources("src/pages")) {
    assert.ok(!/Nothing here\./.test(read(file)), `${file} has a bare "Nothing here." empty state`);
  }
});
