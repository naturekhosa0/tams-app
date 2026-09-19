// Tests for the rules enforced by the create-staff-account edge function.
// Run with: npm test

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  type CreatedStaff,
  handleCreateStaffAccount,
  type PortError,
  type StaffCreationPorts,
} from "../supabase/functions/create-staff-account/handler.ts";

const ADMIN_ROLE = { id: "11111111-1111-1111-1111-111111111111", role_name: "Council Administrator" };
const CLERK_ROLE = { id: "22222222-2222-2222-2222-222222222222", role_name: "Registry Clerk" };

const VALID_FORM = {
  employee_number: "2026022",
  first_name: "Jane",
  last_name: "Doe",
  email: "jane@ta.example",
  contact_number: "0728217377",
  role_id: CLERK_ROLE.id,
};

type Calls = {
  invited: string[];
  deleted: string[];
  created: Record<string, unknown>[];
};

function makePorts(overrides: Partial<StaffCreationPorts> = {}): StaffCreationPorts & { calls: Calls } {
  const calls: Calls = { invited: [], deleted: [], created: [] };

  const ports: StaffCreationPorts & { calls: Calls } = {
    calls,
    getCaller: async () => ({ id: "caller-id" }),
    callerIsActiveCouncilAdministrator: async () => true,
    findRoleById: async (roleId) =>
      roleId === CLERK_ROLE.id ? CLERK_ROLE : roleId === ADMIN_ROLE.id ? ADMIN_ROLE : null,
    employeeNumberTaken: async () => false,
    staffEmailTaken: async () => false,
    inviteUser: async (email) => {
      calls.invited.push(email);
      return { userId: "new-auth-user" };
    },
    deleteAuthUser: async (userId) => {
      calls.deleted.push(userId);
    },
    createStaffWithAccount: async (input) => {
      calls.created.push(input);
      return {
        data: {
          staff_id: "staff-id",
          account_id: "account-id",
          employee_number: input.employee_number,
          email: input.email,
          role_name: CLERK_ROLE.role_name,
          account_status: "active",
        } satisfies CreatedStaff,
      };
    },
    ...overrides,
  };

  return ports;
}

const dbFails = (error: PortError) => ({
  createStaffWithAccount: async () => ({ error }),
});

test("an active Council Administrator can create a Registry Clerk", async () => {
  const ports = makePorts();
  const result = await handleCreateStaffAccount({ ...VALID_FORM }, ports);

  assert.equal(result.status, 201);
  assert.equal(result.body.staff?.employee_number, "2026022");
  assert.equal(result.body.staff?.account_status, "active");
  assert.deepEqual(ports.calls.invited, ["jane@ta.example"]);
  assert.equal(ports.calls.created.length, 1);
  assert.equal(ports.calls.created[0].auth_user_id, "new-auth-user");
  assert.equal(ports.calls.deleted.length, 0);
  assert.match(result.body.message ?? "", /invitation has been emailed/i);
});

test("a signed-out request is refused", async () => {
  const ports = makePorts({ getCaller: async () => null });
  const result = await handleCreateStaffAccount({ ...VALID_FORM }, ports);

  assert.equal(result.status, 401);
  assert.equal(ports.calls.invited.length, 0);
});

test("an ordinary staff member is refused, and nothing is created", async () => {
  const ports = makePorts({ callerIsActiveCouncilAdministrator: async () => false });
  const result = await handleCreateStaffAccount({ ...VALID_FORM }, ports);

  assert.equal(result.status, 403);
  assert.match(result.body.error?.message ?? "", /only the active council administrator/i);
  assert.equal(ports.calls.invited.length, 0);
  assert.equal(ports.calls.created.length, 0);
});

test("a hand-submitted Council Administrator role id is refused", async () => {
  const ports = makePorts();
  const result = await handleCreateStaffAccount({ ...VALID_FORM, role_id: ADMIN_ROLE.id }, ports);

  assert.equal(result.status, 403);
  assert.match(result.body.error?.message ?? "", /cannot be assigned/i);
  assert.equal(ports.calls.invited.length, 0, "no invitation may be sent");
  assert.equal(ports.calls.created.length, 0, "no record may be created");
});

test("an unknown role id is refused", async () => {
  const ports = makePorts();
  const result = await handleCreateStaffAccount(
    { ...VALID_FORM, role_id: "33333333-3333-3333-3333-333333333333" },
    ports,
  );

  assert.equal(result.status, 400);
  assert.equal(result.body.fields?.role_id, "The selected role does not exist.");
});

test("a missing role is refused", async () => {
  const result = await handleCreateStaffAccount({ ...VALID_FORM, role_id: "" }, makePorts());
  assert.equal(result.status, 400);
  assert.equal(result.body.fields?.role_id, "Choose a role.");
});

test("every required field is checked, and reported together", async () => {
  const ports = makePorts();
  const result = await handleCreateStaffAccount({ role_id: CLERK_ROLE.id }, ports);

  assert.equal(result.status, 400);
  assert.deepEqual(Object.keys(result.body.fields ?? {}).sort(), [
    "contact_number",
    "email",
    "employee_number",
    "first_name",
    "last_name",
  ]);
  assert.equal(ports.calls.invited.length, 0);
});

test("a malformed email address is refused", async () => {
  const result = await handleCreateStaffAccount({ ...VALID_FORM, email: "jane-at-ta" }, makePorts());
  assert.equal(result.status, 400);
  assert.match(result.body.fields?.email ?? "", /valid email/i);
});

test("a malformed contact number is refused", async () => {
  const result = await handleCreateStaffAccount({ ...VALID_FORM, contact_number: "12" }, makePorts());
  assert.equal(result.status, 400);
  assert.match(result.body.fields?.contact_number ?? "", /valid contact number/i);
});

test("details are trimmed and the email is lower-cased before anything is created", async () => {
  const ports = makePorts();
  const result = await handleCreateStaffAccount({
    ...VALID_FORM,
    employee_number: "  2026022  ",
    first_name: "  Jane ",
    email: "  Jane@TA.Example  ",
  }, ports);

  assert.equal(result.status, 201);
  assert.deepEqual(ports.calls.invited, ["jane@ta.example"]);
  assert.equal(ports.calls.created[0].employee_number, "2026022");
  assert.equal(ports.calls.created[0].first_name, "Jane");
  assert.equal(ports.calls.created[0].email, "jane@ta.example");
});

test("a duplicate employee number is refused before an auth user is created", async () => {
  const ports = makePorts({ employeeNumberTaken: async () => true });
  const result = await handleCreateStaffAccount({ ...VALID_FORM }, ports);

  assert.equal(result.status, 409);
  assert.match(result.body.fields?.employee_number ?? "", /already in use/i);
  assert.equal(ports.calls.invited.length, 0);
});

test("a duplicate email address is refused before an auth user is created", async () => {
  const ports = makePorts({ staffEmailTaken: async () => true });
  const result = await handleCreateStaffAccount({ ...VALID_FORM }, ports);

  assert.equal(result.status, 409);
  assert.match(result.body.fields?.email ?? "", /already in use/i);
  assert.equal(ports.calls.invited.length, 0);
});

test("an email that already has a sign-in account is reported clearly", async () => {
  const ports = makePorts({
    inviteUser: async () => ({ error: { message: "A user with this email address has already been registered" } }),
  });
  const result = await handleCreateStaffAccount({ ...VALID_FORM }, ports);

  assert.equal(result.status, 409);
  assert.match(result.body.fields?.email ?? "", /already has a sign-in account/i);
  assert.equal(ports.calls.created.length, 0);
});

test("a failed invitation stops the process", async () => {
  const ports = makePorts({ inviteUser: async () => ({ error: { message: "SMTP unavailable" } }) });
  const result = await handleCreateStaffAccount({ ...VALID_FORM }, ports);

  assert.equal(result.status, 502);
  assert.equal(ports.calls.created.length, 0);
  assert.equal(ports.calls.deleted.length, 0);
});

test("the invited auth user is removed when the records cannot be written", async () => {
  const ports = makePorts(dbFails({ code: "XX000", message: "connection lost" }));
  const result = await handleCreateStaffAccount({ ...VALID_FORM }, ports);

  assert.equal(result.status, 500);
  assert.deepEqual(ports.calls.deleted, ["new-auth-user"], "no auth user may survive without its records");
});

test("a duplicate detected by the database also rolls the auth user back", async () => {
  const ports = makePorts(
    dbFails({ code: "23505", message: 'duplicate key value violates unique constraint "staff_employee_number_key"' }),
  );
  const result = await handleCreateStaffAccount({ ...VALID_FORM }, ports);

  assert.equal(result.status, 409);
  assert.match(result.body.fields?.employee_number ?? "", /already in use/i);
  assert.deepEqual(ports.calls.deleted, ["new-auth-user"]);
});

test("the database's own refusal of the administrator role is honoured", async () => {
  const ports = makePorts(
    dbFails({ code: "TA002", message: "The Council Administrator role cannot be assigned through staff creation." }),
  );
  const result = await handleCreateStaffAccount({ ...VALID_FORM }, ports);

  assert.equal(result.status, 403);
  assert.deepEqual(ports.calls.deleted, ["new-auth-user"]);
});

test("a rollback that itself fails still reports the failure rather than success", async () => {
  const ports = makePorts({
    ...dbFails({ code: "XX000", message: "connection lost" }),
    deleteAuthUser: async () => {
      throw new Error("auth service unreachable");
    },
  });
  const result = await handleCreateStaffAccount({ ...VALID_FORM }, ports);

  assert.equal(result.status, 500);
  assert.equal(result.body.staff, undefined);
});
