// =====================================================================
// The decision logic for the one-time first Council Administrator
// bootstrap. Kept free of Deno and Supabase so the rules can be tested.
// =====================================================================

import { validateStaffDetails } from "../_shared/validation.ts";

export type PortError = { code?: string; message: string };

export type BootstrapPorts = {
  /** The bootstrap secret configured on the server, or null when unset. */
  configuredSecret(): string | null;
  /** Constant-time comparison. */
  secretsMatch(a: string, b: string): boolean;
  /** The auth user the administrator will sign in as — created by hand beforehand. */
  findAuthUserByEmail(email: string): Promise<{ id: string } | null>;
  /** Refuses, in the database, if a Council Administrator already exists. */
  bootstrapAdministrator(input: {
    auth_user_id: string;
    employee_number: string;
    first_name: string;
    last_name: string;
    email: string;
    contact_number: string;
  }): Promise<{ data: unknown } | { error: PortError }>;
};

export type HandlerResult = {
  status: number;
  body: {
    administrator?: unknown;
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

export async function handleBootstrap(
  suppliedSecret: string | null,
  payload: Record<string, unknown>,
  ports: BootstrapPorts,
): Promise<HandlerResult> {
  // ---- 1. The shared secret ----------------------------------------
  const expected = ports.configuredSecret();
  if (!expected) {
    return fail(
      503,
      "The bootstrap process is not enabled. Set TAMS_BOOTSTRAP_SECRET on the server first.",
    );
  }
  if (!suppliedSecret || !ports.secretsMatch(suppliedSecret, expected)) {
    return fail(403, "The bootstrap secret is missing or incorrect.");
  }

  // ---- 2. The administrator's details -------------------------------
  const { values, errors } = validateStaffDetails(payload);
  if (!values) {
    return fail(400, "Please correct the highlighted fields.", errors);
  }

  // ---- 3. The auth user must already exist --------------------------
  //         The first administrator's sign-in user is created by hand in
  //         Supabase Auth; this process never creates one, so there is
  //         no public administrator registration path anywhere.
  const authUser = await ports.findAuthUserByEmail(values.email);
  if (!authUser) {
    return fail(
      404,
      `No Supabase Auth user exists for ${values.email}. Create that user first, then run the bootstrap again.`,
      { email: "No authentication user exists for this email address." },
    );
  }

  // ---- 4. One transaction; refuses a second administrator -----------
  const result = await ports.bootstrapAdministrator({
    auth_user_id: authUser.id,
    employee_number: values.employee_number,
    first_name: values.first_name,
    last_name: values.last_name,
    email: values.email,
    contact_number: values.contact_number,
  });

  if ("error" in result) {
    const { code = "", message } = result.error;
    if (code === "TA001") {
      return fail(
        409,
        "A Council Administrator already exists. The bootstrap process may only be used once.",
        undefined,
        code,
      );
    }
    if (code === "23505") {
      return fail(409, "That employee number or email address is already in use.", undefined, code);
    }
    return fail(500, `The Council Administrator could not be created: ${message}`, undefined, code);
  }

  return {
    status: 201,
    body: {
      administrator: result.data,
      message:
        `${values.first_name} ${values.last_name} is now the Council Administrator and can sign in with the password set on their Supabase Auth user.`,
    },
  };
}
