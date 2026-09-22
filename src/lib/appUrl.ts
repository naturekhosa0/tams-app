import { resetRedirectUrl } from "../auth/passwordRules";

/**
 * Where TAMS lives, as far as the outside world is concerned.
 *
 * Almost everything in TAMS is a relative link and needs none of this.
 * Two things are not: the address a password-reset email sends somebody
 * back to, and the address printed as a QR code on a permission to
 * occupy. Both leave the browser and have to work from anywhere.
 *
 * VITE_APP_URL is what a deployed site sets. Left unset, the address
 * the browser is already on is used, which is right in development —
 * but it is also why a permission printed from a development machine
 * would carry a localhost code, and why the deployed site must set it.
 */
export function appBaseUrl(): string {
  const configured = (import.meta.env.VITE_APP_URL as string | undefined)?.trim();
  return (configured || window.location.origin).replace(/\/+$/, "");
}

/** The address shown to somebody reading it off a printed document. */
export function appDisplayHost(): string {
  try {
    return new URL(appBaseUrl()).host;
  } catch {
    return window.location.host;
  }
}

/** Where Supabase should send somebody after they follow a reset link. */
export function passwordResetRedirect(): string {
  return resetRedirectUrl(
    import.meta.env.VITE_APP_URL as string | undefined,
    window.location.origin,
  );
}

/** The address a permission's QR code points at. */
export function ptoVerificationUrl(verificationToken: string): string {
  return `${appBaseUrl()}/verify/pto/${verificationToken}`;
}
