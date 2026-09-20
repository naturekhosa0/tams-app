// =====================================================================
// The decision logic for the Council Administrator's three staff
// management actions:
//
//   change_role   US-CA02  Change Staff Role
//   deactivate    US-CA03  Deactivate Staff Account
//   reactivate             Reactivate Staff Account
//
// This layer checks the shape of the request and turns the database's
// refusals into something an administrator can read. It is not the only
// guard: each database function re-establishes the caller from
// auth.uid() and enforces every rule again for itself.
// =====================================================================

import { isUuid } from "../_shared/validation.ts";

export const ACTIONS = ["change_role", "deactivate", "reactivate"] as const;
export type Action = typeof ACTIONS[number];

export const MAXIMUM_REASON_LENGTH = 500;

export type PortError = { code?: string; message: string };
export type PortResult = { data: unknown } | { error: PortError };

export type StaffManagementPorts = {
  getCaller(): Promise<{ id: string } | null>;
  /** Asked of the database, against the live record. */
  callerIsActiveCouncilAdministrator(): Promise<boolean>;
  changeStaffRole(input: { staff_id: string; role_id: string }): Promise<PortResult>;
  deactivateStaffAccount(input: { staff_id: string; reason: string }): Promise<PortResult>;
  reactivateStaffAccount(input: { staff_id: string; reason: string }): Promise<PortResult>;
};

export type HandlerResult = {
  status: number;
  body: {
    result?: unknown;
    message?: string;
    error?: { message: string; code?: string | null };
    fields?: Record<string, string>;
  };
};

const fail = (
  status: number,
  message: string,
  fields?: Record<string, string>,
  code?: string,
): HandlerResult => ({
  status,
  body: { error: { message, code: code ?? null }, ...(fields ? { fields } : {}) },
});

/**
 * What each refusal from the database means. The database raises these,
 * whichever way it was called, so this table is the single place they
 * are turned into wording and an HTTP status.
 */
const DATABASE_REFUSALS: Record<string, { status: number; message: string; field?: string }> = {
  "42501": {
    status: 403,
    message: "Only the active Council Administrator may manage staff accounts.",
  },
  TA010: { status: 404, message: "That staff member could not be found." },
  TA011: {
    status: 403,
    message: "The Council Administrator account is managed separately and cannot be changed here.",
  },
  TA012: {
    status: 409,
    message: "That staff member's account is not active, so their role cannot be changed.",
  },
  TA013: { status: 400, message: "The selected role does not exist.", field: "role_id" },
  TA014: {
    status: 403,
    message: "The Council Administrator role cannot be assigned to a staff member.",
    field: "role_id",
  },
  TA015: {
    status: 409,
    message: "That staff member already holds the role you chose. Choose a different role.",
    field: "role_id",
  },
  TA016: { status: 409, message: "That account is already deactivated." },
  TA017: { status: 409, message: "That account is already active." },
  TA018: { status: 400, message: "A reason is required.", field: "reason" },
};

function refusal(error: PortError): HandlerResult {
  const known = DATABASE_REFUSALS[error.code ?? ""];
  if (!known) {
    return fail(500, `The change could not be saved: ${error.message}`, undefined, error.code);
  }
  return fail(
    known.status,
    known.message,
    known.field ? { [known.field]: known.message } : undefined,
    error.code,
  );
}

function readReason(payload: Record<string, unknown>): { reason?: string; failure?: HandlerResult } {
  const reason = typeof payload.reason === "string" ? payload.reason.trim() : "";
  if (!reason) {
    return { failure: fail(400, "A reason is required.", { reason: "A reason is required." }) };
  }
  if (reason.length > MAXIMUM_REASON_LENGTH) {
    const message = `The reason is too long (${MAXIMUM_REASON_LENGTH} characters at most).`;
    return { failure: fail(400, message, { reason: message }) };
  }
  return { reason };
}

export async function handleManageStaffAccount(
  payload: Record<string, unknown>,
  ports: StaffManagementPorts,
): Promise<HandlerResult> {
  // ---- 1. Who is asking? --------------------------------------------
  const caller = await ports.getCaller();
  if (!caller) {
    return fail(401, "Your session is no longer valid. Please sign in again.");
  }
  if (!(await ports.callerIsActiveCouncilAdministrator())) {
    return fail(403, "Only the active Council Administrator may manage staff accounts.");
  }

  // ---- 2. What are they asking for? ---------------------------------
  const action = payload.action;
  if (typeof action !== "string" || !ACTIONS.includes(action as Action)) {
    return fail(400, "That is not something this function can do.");
  }

  const staffId = payload.staff_id;
  if (!isUuid(staffId)) {
    return fail(400, "No staff member was chosen.", { staff_id: "Choose a staff member." });
  }

  // ---- 3. Do it -----------------------------------------------------
  switch (action as Action) {
    case "change_role": {
      const roleId = payload.role_id;
      if (!isUuid(roleId)) {
        return fail(400, "No new role was chosen.", { role_id: "Choose a new role." });
      }
      const result = await ports.changeStaffRole({ staff_id: staffId, role_id: roleId });
      if ("error" in result) return refusal(result.error);
      return {
        status: 200,
        body: { result: result.data, message: "The staff member's role has been changed." },
      };
    }

    case "deactivate": {
      const { reason, failure } = readReason(payload);
      if (failure) return failure;
      const result = await ports.deactivateStaffAccount({ staff_id: staffId, reason: reason! });
      if ("error" in result) return refusal(result.error);
      return {
        status: 200,
        body: {
          result: result.data,
          message: "The account has been deactivated. They can no longer use the system.",
        },
      };
    }

    case "reactivate": {
      const { reason, failure } = readReason(payload);
      if (failure) return failure;
      const result = await ports.reactivateStaffAccount({ staff_id: staffId, reason: reason! });
      if ("error" in result) return refusal(result.error);
      return {
        status: 200,
        body: {
          result: result.data,
          message: "The account has been reactivated. They can sign in again with their existing password.",
        },
      };
    }
  }
}
