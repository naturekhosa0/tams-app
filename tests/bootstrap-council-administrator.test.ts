// Tests for the one-time first Council Administrator bootstrap.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  type BootstrapPorts,
  handleBootstrap,
} from "../supabase/functions/bootstrap-council-administrator/handler.ts";

const SECRET = "a-long-random-bootstrap-secret";

const VALID_FORM = {
  employee_number: "2026011",
  first_name: "Nature",
  last_name: "Khosa",
  email: "admin@ta.example",
  contact_number: "0728217377",
};

type Calls = { bootstrapped: Record<string, unknown>[] };

function makePorts(overrides: Partial<BootstrapPorts> = {}): BootstrapPorts & { calls: Calls } {
  const calls: Calls = { bootstrapped: [] };

  return {
    calls,
    configuredSecret: () => SECRET,
    // The real implementation is constant time; equality is enough here.
    secretsMatch: (a, b) => a === b,
    findAuthUserByEmail: async (email) =>
      email === "admin@ta.example" ? { id: "auth-user-id" } : null,
    bootstrapAdministrator: async (input) => {
      calls.bootstrapped.push(input);
      return { data: { staff_id: "staff-id", role_name: "Council Administrator" } };
    },
    ...overrides,
  };
}

test("the first Council Administrator is created from an existing auth user", async () => {
  const ports = makePorts();
  const result = await handleBootstrap(SECRET, { ...VALID_FORM }, ports);

  assert.equal(result.status, 201);
  assert.equal(ports.calls.bootstrapped.length, 1);
  assert.equal(ports.calls.bootstrapped[0].auth_user_id, "auth-user-id");
  assert.equal(ports.calls.bootstrapped[0].employee_number, "2026011");
  assert.match(result.body.message ?? "", /Council Administrator/);
});

test("the process is closed when no bootstrap secret is configured", async () => {
  const ports = makePorts({ configuredSecret: () => null });
  const result = await handleBootstrap("anything", { ...VALID_FORM }, ports);

  assert.equal(result.status, 503);
  assert.equal(ports.calls.bootstrapped.length, 0);
});

test("a wrong secret is refused", async () => {
  const ports = makePorts();
  const result = await handleBootstrap("not-the-secret", { ...VALID_FORM }, ports);

  assert.equal(result.status, 403);
  assert.equal(ports.calls.bootstrapped.length, 0);
});

test("a missing secret is refused", async () => {
  const ports = makePorts();
  const result = await handleBootstrap(null, { ...VALID_FORM }, ports);

  assert.equal(result.status, 403);
  assert.equal(ports.calls.bootstrapped.length, 0);
});

test("incomplete details are reported field by field", async () => {
  const ports = makePorts();
  const result = await handleBootstrap(SECRET, { email: "admin@ta.example" }, ports);

  assert.equal(result.status, 400);
  assert.deepEqual(Object.keys(result.body.fields ?? {}).sort(), [
    "contact_number",
    "employee_number",
    "first_name",
    "last_name",
  ]);
  assert.equal(ports.calls.bootstrapped.length, 0);
});

test("the auth user must already exist — the process never creates one", async () => {
  const ports = makePorts();
  const result = await handleBootstrap(SECRET, { ...VALID_FORM, email: "nobody@ta.example" }, ports);

  assert.equal(result.status, 404);
  assert.match(result.body.error?.message ?? "", /create that user first/i);
  assert.equal(ports.calls.bootstrapped.length, 0);
});

test("a second Council Administrator is refused", async () => {
  const ports = makePorts({
    bootstrapAdministrator: async () => ({
      error: { code: "TA001", message: "A Council Administrator already exists." },
    }),
  });
  const result = await handleBootstrap(SECRET, { ...VALID_FORM }, ports);

  assert.equal(result.status, 409);
  assert.match(result.body.error?.message ?? "", /may only be used once/i);
});

test("an employee number already in use is reported", async () => {
  const ports = makePorts({
    bootstrapAdministrator: async () => ({
      error: { code: "23505", message: "duplicate key value" },
    }),
  });
  const result = await handleBootstrap(SECRET, { ...VALID_FORM }, ports);

  assert.equal(result.status, 409);
});
