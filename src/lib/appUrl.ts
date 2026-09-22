import { resetRedirectUrl } from "../auth/passwordRules";

/** Where Supabase should send somebody after they follow a reset link. */
export function passwordResetRedirect(): string {
  return resetRedirectUrl(
    import.meta.env.VITE_APP_URL as string | undefined,
    window.location.origin,
  );
}
