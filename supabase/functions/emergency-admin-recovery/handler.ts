// =====================================================================
// Emergency Council Administrator recovery — the decision logic.
//
// This exists for one situation: TAMS has no Council Administrator
// anybody can sign in as. It is not a way round a forgotten password,
// and there is no page in the application that reaches it.
//
// Three things must all be true before anything happens:
//   1. the caller knows TAMS_ADMIN_RECOVERY_SECRET;
//   2. the database agrees there is no valid active administrator;
//   3. the person being promoted is existing, active, ordinary staff.
// =====================================================================

export type PortError = { code?: string; message: string };

export type RecoveryCandidate = {
  staff_id: string;
  employee_number: string;
  full_name: string;
  email: string;
  role_name: string;
};

export type RecoveryPorts = {
  configuredSecret(): string | null;
  secretsMatch(a: string, b: string): boolean;
  /** What the database says about the administrator situation right now. */
  administratorHealth(): Promise<{ active_administrators: number; valid_administrators: number }>;
  listCandidates(): Promise<RecoveryCandidate[]>;
  promote(input: { staff_id: string; reason: string }): Promise<{ data: unknown } | { error: PortError }>;
};

export type RecoveryResult = {
  status: number;
  body: {
    administrator?: unknown;
    candidates?: RecoveryCandidate[];
    health?: { active_administrators: number; valid_administrators: number };
    message?: string;
    error?: { message: string };
  };
};

const fail = (status: number, message: string): RecoveryResult => ({
  status,
  body: { error: { message } },
});

export async function handleRecovery(
  suppliedSecret: string | null,
  payload: Record<string, unknown>,
  ports: RecoveryPorts,
): Promise<RecoveryResult> {
  // ---- 1. The secret ------------------------------------------------
  const expected = ports.configuredSecret();
  if (!expected) {
    return fail(
      503,
      "Emergency recovery is not enabled. Set TAMS_ADMIN_RECOVERY_SECRET on the server first.",
    );
  }
  if (!suppliedSecret || !ports.secretsMatch(suppliedSecret, expected)) {
    return fail(403, "The recovery secret is missing or incorrect.");
  }

  // ---- 2. Is this actually an emergency? ----------------------------
  const health = await ports.administratorHealth();
  if (health.valid_administrators > 0) {
    return fail(
      409,
      "TAMS already has a Council Administrator who can sign in. " +
        "Use Administrator Transfer, or ordinary password recovery.",
    );
  }

  // Asking who could be promoted is safe and changes nothing.
  const action = String(payload.action ?? "promote");
  if (action === "candidates") {
    return { status: 200, body: { candidates: await ports.listCandidates(), health } };
  }
  if (action !== "promote") {
    return fail(400, "The action must be 'candidates' or 'promote'.");
  }

  // ---- 3. Who, and why ----------------------------------------------
  const staffId = typeof payload.staff_id === "string" ? payload.staff_id.trim() : "";
  const reason = typeof payload.reason === "string" ? payload.reason.trim() : "";
  if (!staffId) {
    return fail(400, "Choose the staff member to promote. Ask for 'candidates' to see who is eligible.");
  }
  if (!reason) {
    return fail(400, "A reason for the emergency recovery is required.");
  }
  if (reason.length > 500) {
    return fail(400, "The reason is too long (500 characters at most).");
  }

  // The database checks all of this again for itself, and refuses again
  // if an administrator appeared in the meantime.
  const result = await ports.promote({ staff_id: staffId, reason });
  if ("error" in result) {
    return fail(400, result.error.message);
  }

  return {
    status: 200,
    body: {
      administrator: result.data,
      message: "The Council Administrator role has been recovered. Normal rules apply again.",
    },
  };
}
