// Tests for the rules enforced by the manage-staff-account edge
// function: Change Staff Role, Deactivate and Reactivate.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  handleManageStaffAccount,
  type PortResult,
  type StaffManagementPorts,
} from "../supabase/functions/manage-staff-account/handler.ts";

const STAFF_ID = "44444444-4444-4444-4444-444444444444";
const ROLE_ID = "22222222-2222-2222-2222-222222222222";

type Calls = { changed: unknown[]; deactivated: unknown[]; reactivated: unknown[] };

function makePorts(overrides: Partial<StaffManagementPorts> = {}): StaffManagementPorts & { calls: Calls } {
  const calls: Calls = { changed: [], deactivated: [], reactivated: [] };

  return {
    calls,
    getCaller: async () => ({ id: "caller-id" }),
    callerIsActiveCouncilAdministrator: async () => true,
    changeStaffRole: async (input) => {
      calls.changed.push(input);
      return { data: { staff_id: input.staff_id, new_role: "Land Officer" } };
    },
    deactivateStaffAccount: async (input) => {
      calls.deactivated.push(input);
      return { data: { staff_id: input.staff_id, account_status: "deactivated" } };
    },
    reactivateStaffAccount: async (input) => {
      calls.reactivated.push(input);
      return { data: { staff_id: input.staff_id, account_status: "active" } };
    },
    ...overrides,
  };
}

const refuses = (code: string): Partial<StaffManagementPorts> => {
  const result = async (): Promise<PortResult> => ({ error: { code, message: `database said ${code}` } });
  return {
    changeStaffRole: result,
    deactivateStaffAccount: result,
    reactivateStaffAccount: result,
  };
};

const CHANGE = { action: "change_role", staff_id: STAFF_ID, role_id: ROLE_ID };
const DEACTIVATE = { action: "deactivate", staff_id: STAFF_ID, reason: "Staff member resigned" };
const REACTIVATE = { action: "reactivate", staff_id: STAFF_ID, reason: "Returned from leave" };

// ---- who may use it -------------------------------------------------

test("a signed-out request is refused", async () => {
  const ports = makePorts({ getCaller: async () => null });
  const result = await handleManageStaffAccount({ ...CHANGE }, ports);

  assert.equal(result.status, 401);
  assert.equal(ports.calls.changed.length, 0);
});

for (const [name, payload] of [["change a role", CHANGE], ["deactivate", DEACTIVATE], ["reactivate", REACTIVATE]] as const) {
  test(`an ordinary staff member cannot ${name}`, async () => {
    const ports = makePorts({ callerIsActiveCouncilAdministrator: async () => false });
    const result = await handleManageStaffAccount({ ...payload }, ports);

    assert.equal(result.status, 403);
    assert.match(result.body.error?.message ?? "", /only the active council administrator/i);
    assert.deepEqual(ports.calls, { changed: [], deactivated: [], reactivated: [] });
  });
}

test("an unknown action is refused", async () => {
  const ports = makePorts();
  const result = await handleManageStaffAccount({ action: "delete_staff", staff_id: STAFF_ID }, ports);

  assert.equal(result.status, 400);
  assert.deepEqual(ports.calls, { changed: [], deactivated: [], reactivated: [] });
});

// ---- change role ----------------------------------------------------

test("a role change is passed to the database", async () => {
  const ports = makePorts();
  const result = await handleManageStaffAccount({ ...CHANGE }, ports);

  assert.equal(result.status, 200);
  assert.deepEqual(ports.calls.changed, [{ staff_id: STAFF_ID, role_id: ROLE_ID }]);
  assert.match(result.body.message ?? "", /role has been changed/i);
});

test("a role change without a staff member is refused", async () => {
  const result = await handleManageStaffAccount({ action: "change_role", role_id: ROLE_ID }, makePorts());
  assert.equal(result.status, 400);
  assert.equal(result.body.fields?.staff_id, "Choose a staff member.");
});

test("a role change without a role is refused", async () => {
  const result = await handleManageStaffAccount({ action: "change_role", staff_id: STAFF_ID }, makePorts());
  assert.equal(result.status, 400);
  assert.equal(result.body.fields?.role_id, "Choose a new role.");
});

test("the database refusing the Council Administrator role is reported clearly", async () => {
  const result = await handleManageStaffAccount({ ...CHANGE }, makePorts(refuses("TA014")));

  assert.equal(result.status, 403);
  assert.match(result.body.error?.message ?? "", /cannot be assigned to a staff member/i);
  assert.match(result.body.fields?.role_id ?? "", /cannot be assigned/i);
});

test("changing the Council Administrator's own role is reported clearly", async () => {
  const result = await handleManageStaffAccount({ ...CHANGE }, makePorts(refuses("TA011")));

  assert.equal(result.status, 403);
  assert.match(result.body.error?.message ?? "", /managed separately/i);
});

test("choosing the role they already hold is reported clearly", async () => {
  const result = await handleManageStaffAccount({ ...CHANGE }, makePorts(refuses("TA015")));

  assert.equal(result.status, 409);
  assert.match(result.body.fields?.role_id ?? "", /already holds the role/i);
});

test("changing a deactivated staff member's role is reported clearly", async () => {
  const result = await handleManageStaffAccount({ ...CHANGE }, makePorts(refuses("TA012")));

  assert.equal(result.status, 409);
  assert.match(result.body.error?.message ?? "", /not active/i);
});

test("an unknown staff member is reported as not found", async () => {
  const result = await handleManageStaffAccount({ ...CHANGE }, makePorts(refuses("TA010")));
  assert.equal(result.status, 404);
});

// ---- deactivate -----------------------------------------------------

test("a deactivation is passed to the database with its reason", async () => {
  const ports = makePorts();
  const result = await handleManageStaffAccount({ ...DEACTIVATE }, ports);

  assert.equal(result.status, 200);
  assert.deepEqual(ports.calls.deactivated, [{ staff_id: STAFF_ID, reason: "Staff member resigned" }]);
  assert.match(result.body.message ?? "", /no longer use the system/i);
});

test("a deactivation without a reason is refused before the database is touched", async () => {
  const ports = makePorts();
  const result = await handleManageStaffAccount({ ...DEACTIVATE, reason: "   " }, ports);

  assert.equal(result.status, 400);
  assert.equal(result.body.fields?.reason, "A reason is required.");
  assert.equal(ports.calls.deactivated.length, 0);
});

test("an over-long reason is refused", async () => {
  const ports = makePorts();
  const result = await handleManageStaffAccount({ ...DEACTIVATE, reason: "x".repeat(501) }, ports);

  assert.equal(result.status, 400);
  assert.match(result.body.fields?.reason ?? "", /too long/i);
  assert.equal(ports.calls.deactivated.length, 0);
});

test("the reason is trimmed before it is stored", async () => {
  const ports = makePorts();
  await handleManageStaffAccount({ ...DEACTIVATE, reason: "  Staff member resigned  " }, ports);

  assert.deepEqual(ports.calls.deactivated, [{ staff_id: STAFF_ID, reason: "Staff member resigned" }]);
});

test("deactivating an already deactivated account is reported clearly", async () => {
  const result = await handleManageStaffAccount({ ...DEACTIVATE }, makePorts(refuses("TA016")));

  assert.equal(result.status, 409);
  assert.match(result.body.error?.message ?? "", /already deactivated/i);
});

test("deactivating the Council Administrator is reported clearly", async () => {
  const result = await handleManageStaffAccount({ ...DEACTIVATE }, makePorts(refuses("TA011")));

  assert.equal(result.status, 403);
  assert.match(result.body.error?.message ?? "", /managed separately/i);
});

// ---- reactivate -----------------------------------------------------

test("a reactivation is passed to the database with its reason", async () => {
  const ports = makePorts();
  const result = await handleManageStaffAccount({ ...REACTIVATE }, ports);

  assert.equal(result.status, 200);
  assert.deepEqual(ports.calls.reactivated, [{ staff_id: STAFF_ID, reason: "Returned from leave" }]);
  assert.match(result.body.message ?? "", /existing password/i);
});

test("a reactivation without a reason is refused", async () => {
  const ports = makePorts();
  const result = await handleManageStaffAccount({ ...REACTIVATE, reason: "" }, ports);

  assert.equal(result.status, 400);
  assert.equal(ports.calls.reactivated.length, 0);
});

test("reactivating an already active account is reported clearly", async () => {
  const result = await handleManageStaffAccount({ ...REACTIVATE }, makePorts(refuses("TA017")));

  assert.equal(result.status, 409);
  assert.match(result.body.error?.message ?? "", /already active/i);
});

test("the database turning away a non-administrator is honoured even if the check above passed", async () => {
  // Belt and braces: if the caller lost the role between the two calls,
  // the database still refuses and that refusal is what is reported.
  const result = await handleManageStaffAccount({ ...REACTIVATE }, makePorts(refuses("42501")));

  assert.equal(result.status, 403);
  assert.match(result.body.error?.message ?? "", /only the active council administrator/i);
});

test("an unexpected database error is not reported as success", async () => {
  const result = await handleManageStaffAccount({ ...CHANGE }, makePorts(refuses("XX000")));

  assert.equal(result.status, 500);
  assert.equal(result.body.result, undefined);
});
