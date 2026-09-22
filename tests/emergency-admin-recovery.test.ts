// Tests for the emergency Council Administrator recovery rules.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  handleRecovery,
  type RecoveryCandidate,
  type RecoveryPorts,
} from "../supabase/functions/emergency-admin-recovery/handler.ts";

const SECRET = "a-long-random-recovery-secret";

const CANDIDATE: RecoveryCandidate = {
  staff_id: "staff-1",
  employee_number: "2026072",
  full_name: "Cynthia Secretary",
  email: "councilsec@ta.example",
  role_name: "Council Secretary",
};

type Calls = { promoted: { staff_id: string; reason: string }[] };

function makePorts(overrides: Partial<RecoveryPorts> = {}): RecoveryPorts & { calls: Calls } {
  const calls: Calls = { promoted: [] };
  return {
    calls,
    configuredSecret: () => SECRET,
    secretsMatch: (a, b) => a === b,
    // No administrator anybody can sign in as: the emergency.
    administratorHealth: async () => ({ active_administrators: 0, valid_administrators: 0 }),
    listCandidates: async () => [CANDIDATE],
    promote: async (input) => {
      calls.promoted.push(input);
      return { data: { full_name: CANDIDATE.full_name, previous_role: CANDIDATE.role_name } };
    },
    ...overrides,
  };
}

test("recovery promotes an existing staff member when no administrator can sign in", async () => {
  const ports = makePorts();
  const result = await handleRecovery(SECRET, {
    action: "promote",
    staff_id: "staff-1",
    reason: "The administrator left and their sign-in was removed",
  }, ports);

  assert.equal(result.status, 200);
  assert.equal(ports.calls.promoted.length, 1);
  assert.equal(ports.calls.promoted[0].staff_id, "staff-1");
});

test("recovery refuses while a valid administrator exists", async () => {
  const ports = makePorts({
    administratorHealth: async () => ({ active_administrators: 1, valid_administrators: 1 }),
  });
  const result = await handleRecovery(SECRET, {
    staff_id: "staff-1",
    reason: "I would like to be the administrator",
  }, ports);

  assert.equal(result.status, 409);
  assert.match(result.body.error!.message, /already has a Council Administrator/);
  assert.equal(ports.calls.promoted.length, 0);
});

test("a forgotten password is not an emergency: the healthy case is refused", async () => {
  // An administrator whose account is fine but who cannot remember
  // their password still counts as valid, so recovery says no.
  const ports = makePorts({
    administratorHealth: async () => ({ active_administrators: 1, valid_administrators: 1 }),
  });
  assert.equal((await handleRecovery(SECRET, { action: "candidates" }, ports)).status, 409);
});

test("recovery refuses without the secret", async () => {
  const ports = makePorts();
  assert.equal((await handleRecovery(null, { staff_id: "staff-1", reason: "x" }, ports)).status, 403);
  assert.equal((await handleRecovery("wrong", { staff_id: "staff-1", reason: "x" }, ports)).status, 403);
  assert.equal(ports.calls.promoted.length, 0);
});

test("recovery is off entirely until the secret is configured", async () => {
  const ports = makePorts({ configuredSecret: () => null });
  const result = await handleRecovery(SECRET, { staff_id: "staff-1", reason: "x" }, ports);
  assert.equal(result.status, 503);
  assert.match(result.body.error!.message, /TAMS_ADMIN_RECOVERY_SECRET/);
});

test("the eligible staff can be listed without changing anything", async () => {
  const ports = makePorts();
  const result = await handleRecovery(SECRET, { action: "candidates" }, ports);

  assert.equal(result.status, 200);
  assert.deepEqual(result.body.candidates, [CANDIDATE]);
  assert.equal(ports.calls.promoted.length, 0);
});

test("recovery requires both a staff member and a reason", async () => {
  const ports = makePorts();
  assert.equal((await handleRecovery(SECRET, { reason: "x" }, ports)).status, 400);
  assert.equal((await handleRecovery(SECRET, { staff_id: "staff-1" }, ports)).status, 400);
  assert.equal((await handleRecovery(SECRET, { staff_id: "staff-1", reason: "  " }, ports)).status, 400);
  assert.equal(
    (await handleRecovery(SECRET, { staff_id: "s", reason: "x".repeat(501) }, ports)).status,
    400,
  );
  assert.equal(ports.calls.promoted.length, 0);
});

test("the database refusing is reported rather than swallowed", async () => {
  const ports = makePorts({
    promote: async () => ({ error: { code: "TA138", message: "That staff member could not be found." } }),
  });
  const result = await handleRecovery(SECRET, { staff_id: "nobody", reason: "x" }, ports);
  assert.equal(result.status, 400);
  assert.match(result.body.error!.message, /could not be found/);
});

test("the recovery secret is never echoed back in any answer", async () => {
  const ports = makePorts();
  for (const payload of [
    { action: "candidates" },
    { staff_id: "staff-1", reason: "The administrator account was deleted" },
  ]) {
    const result = await handleRecovery(SECRET, payload, ports);
    assert.ok(!JSON.stringify(result).includes(SECRET));
  }
});
