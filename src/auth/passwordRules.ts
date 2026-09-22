// The password rules TAMS uses, in one place.
//
// The invitation page and the reset page apply exactly the same ones, so
// a password chosen from a reset link is never held to a different
// standard from one chosen from an invitation.
//
// Nothing here ever touches a password store. Supabase Auth holds
// passwords; this only decides whether what somebody typed is worth
// sending to it.

export const MINIMUM_PASSWORD_LENGTH = 8;

/**
 * Returns the problem with a new password, or null when there is none.
 * The message is what the person reads, so it says what to do rather
 * than what went wrong.
 */
export function validateNewPassword(password: string, confirmation: string): string | null {
  if (!password) return "Choose a new password.";
  if (password.length < MINIMUM_PASSWORD_LENGTH) {
    return `Your password must be at least ${MINIMUM_PASSWORD_LENGTH} characters.`;
  }
  if (!confirmation) return "Type your new password a second time to confirm it.";
  if (password !== confirmation) return "The two passwords do not match.";
  return null;
}

/** A rough check that an address is worth sending a reset link to. */
export function looksLikeEmail(value: string): boolean {
  const trimmed = value.trim();
  return /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(trimmed);
}

/**
 * What Supabase says went wrong with a link, read out of the address.
 *
 * Supabase puts its failures in the URL fragment (and sometimes the
 * query) when a recovery or invitation link is stale: `error`,
 * `error_code` and a human `error_description`. Reading them here means
 * the page can say something useful instead of sitting blank.
 *
 * Returns null when the address carries no complaint.
 */
export function recoveryLinkProblem(hash: string, search: string): string | null {
  const fromHash = new URLSearchParams(hash.replace(/^#/, ""));
  const fromQuery = new URLSearchParams(search.replace(/^\?/, ""));

  const description = fromHash.get("error_description") ?? fromQuery.get("error_description");
  const code = fromHash.get("error_code") ?? fromQuery.get("error_code");
  const error = fromHash.get("error") ?? fromQuery.get("error");

  if (description) return description.replace(/\+/g, " ");
  if (code === "otp_expired") return "That reset link has expired.";
  if (error) return `That reset link cannot be used (${error}).`;
  return null;
}

/**
 * Where a recovery email should send somebody back to.
 *
 * The configured address is used when there is one, so a deployed TAMS
 * does not send people to localhost; otherwise the address the browser
 * is already on, which is right in development and never hard-coded.
 */
export function resetRedirectUrl(configuredBaseUrl: string | undefined, origin: string): string {
  const base = (configuredBaseUrl ?? "").trim() || origin;
  return `${base.replace(/\/+$/, "")}/reset-password`;
}

/**
 * The one answer a request for a reset link ever gets.
 *
 * It is deliberately the same whether the address belongs to an account
 * or not: telling somebody which addresses are registered is telling
 * them who has an account here.
 */
export const RESET_REQUESTED_MESSAGE =
  "If an account exists for that email address, a password reset link has been sent. " +
  "Check your inbox, and your spam folder.";
