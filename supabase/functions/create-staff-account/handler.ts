// =====================================================================
// The decision logic for "Create Staff Account".
//
// Everything this function needs from the outside world arrives through
// the ports below, so the rules — who may create staff, which roles may
// be assigned, what happens when a step fails — can be exercised
// directly by the test suite.
// =====================================================================

import { isUuid, validateStaffDetails } from "../_shared/validation.ts";

export type Role = { id: string; role_name: string };

export type CreatedStaff = {
  staff_id: string;
  account_id: string;
  employee_number: string;
  email: string;
  role_name: string;
  account_status: string;
};

export type PortError = { code?: string; message: string };

export type StaffCreationPorts = {
  /** The signed-in auth user, taken from the request's own token. */
  getCaller(): Promise<{ id: string } | null>;
  /** Asked of the database, against the live record. Never taken from the browser. */
  callerIsActiveCouncilAdministrator(): Promise<boolean>;
  findRoleById(roleId: string): Promise<Role | null>;
  employeeNumberTaken(employeeNumber: string): Promise<boolean>;
  staffEmailTaken(email: string): Promise<boolean>;
  /** Creates the Supabase Auth user and emails the invitation. */
  inviteUser(
    email: string,
    details: { employee_number: string; full_name: string },
  ): Promise<{ userId: string } | { error: PortError }>;
  /** Used to undo the invitation when a later step fails. */
  deleteAuthUser(userId: string): Promise<void>;
  /** Staff record + user account, inserted in one database transaction. */
  createStaffWithAccount(input: {
    auth_user_id: string;
    employee_number: string;
    first_name: string;
    last_name: string;
    email: string;
    contact_number: string;
    role_id: string;
  }): Promise<{ data: CreatedStaff } | { error: PortError }>;
};

export type HandlerResult = {
  status: number;
  body: {
    staff?: CreatedStaff;
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

export async function handleCreateStaffAccount(
  payload: Record<string, unknown>,
  ports: StaffCreationPorts,
): Promise<HandlerResult> {
  // ---- 1. Who is asking? --------------------------------------------
  const caller = await ports.getCaller();
  if (!caller) {
    return fail(401, "Your session is no longer valid. Please sign in again.");
  }

  if (!(await ports.callerIsActiveCouncilAdministrator())) {
    return fail(403, "Only the active Council Administrator may create staff accounts.");
  }

  // ---- 2. Are the details complete and well formed? -----------------
  const { values, errors } = validateStaffDetails(payload);
  if (!values) {
    return fail(400, "Please correct the highlighted fields.", errors);
  }

  const roleId = payload.role_id;
  if (!isUuid(roleId)) {
    return fail(400, "Please correct the highlighted fields.", { role_id: "Choose a role." });
  }

  // ---- 3. Is the role real, and is it one that may be handed out? ---
  const role = await ports.findRoleById(roleId);
  if (!role) {
    return fail(400, "Please correct the highlighted fields.", {
      role_id: "The selected role does not exist.",
    });
  }
  if (role.role_name === "Council Administrator") {
    // Enforced here as well as in the database, so a hand-built request
    // carrying the administrator role id gets nowhere.
    return fail(
      403,
      "The Council Administrator role cannot be assigned through staff creation.",
      { role_id: "This role cannot be assigned." },
    );
  }

  // ---- 4. Duplicate identities -------------------------------------
  if (await ports.employeeNumberTaken(values.employee_number)) {
    return fail(409, "That employee number is already in use.", {
      employee_number: "That employee number is already in use.",
    });
  }
  if (await ports.staffEmailTaken(values.email)) {
    return fail(409, "That email address is already in use.", {
      email: "That email address is already in use.",
    });
  }

  // ---- 5. Invite (creates the auth user) ----------------------------
  const invitation = await ports.inviteUser(values.email, {
    employee_number: values.employee_number,
    full_name: `${values.first_name} ${values.last_name}`,
  });

  if ("error" in invitation) {
    const reason = invitation.error.message;
    const lowered = reason.toLowerCase();

    if (lowered.includes("already")) {
      return fail(409, "That email address already has a sign-in account.", {
        email: "That email address already has a sign-in account.",
      });
    }

    // Supabase Auth could not hand the email to a mail server. Nothing has
    // been created at this point, so the administrator can simply try
    // again once email delivery works.
    if (/sending .*(email|invite)|smtp|rate limit|too many requests/.test(lowered)) {
      return fail(
        502,
        "The invitation email could not be sent, so no staff account was created. " +
          "This usually means the project has no SMTP server set up yet, or its email " +
          "limit has been reached. Set up email delivery and create the account again.",
      );
    }

    return fail(502, `The invitation could not be sent, so no staff account was created: ${reason}`);
  }

  // ---- 6. Staff record + user account, or undo the invitation -------
  const created = await ports.createStaffWithAccount({
    auth_user_id: invitation.userId,
    employee_number: values.employee_number,
    first_name: values.first_name,
    last_name: values.last_name,
    email: values.email,
    contact_number: values.contact_number,
    role_id: role.id,
  });

  if ("error" in created) {
    // No auth user may survive without its staff record and user account.
    try {
      await ports.deleteAuthUser(invitation.userId);
    } catch {
      // Reported below; the account is unusable either way because it has
      // no user_accounts row and therefore no access.
    }

    const { code = "", message } = created.error;
    if (code === "TA002") {
      return fail(403, "The Council Administrator role cannot be assigned through staff creation.", undefined, code);
    }
    if (code === "23505" && message.includes("employee_number")) {
      return fail(409, "That employee number is already in use.", {
        employee_number: "That employee number is already in use.",
      }, code);
    }
    if (code === "23505" && message.includes("email")) {
      return fail(409, "That email address is already in use.", {
        email: "That email address is already in use.",
      }, code);
    }
    if (code === "23514") {
      return fail(400, "Some of the details supplied are not valid.", undefined, code);
    }
    return fail(500, `The staff account could not be created: ${message}`, undefined, code);
  }

  return {
    status: 201,
    body: {
      staff: created.data,
      message:
        `An invitation has been emailed to ${values.email}. They choose their own password from that email.`,
    },
  };
}
