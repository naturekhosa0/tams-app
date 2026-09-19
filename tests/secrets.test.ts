// The shared-secret comparison must not leak the secret through timing.

import { test } from "node:test";
import assert from "node:assert/strict";
import { secretsMatch } from "../supabase/functions/_shared/http.ts";

test("identical secrets match", () => {
  assert.equal(secretsMatch("abc123", "abc123"), true);
});

test("different secrets of the same length do not match", () => {
  assert.equal(secretsMatch("abc123", "abc124"), false);
});

test("secrets of different lengths do not match", () => {
  assert.equal(secretsMatch("abc", "abc123"), false);
});

test("an empty secret never matches a real one", () => {
  assert.equal(secretsMatch("", "abc123"), false);
});
