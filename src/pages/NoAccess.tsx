import { Link } from "react-router-dom";
import { useSession } from "../auth/SessionProvider";
import { Notice } from "../components/ui";

/**
 * Shown when someone is signed in to Supabase Auth but the database says
 * they may not use the system: a deactivated account, or an auth user
 * with no staff record behind it.
 */
export function NoAccess() {
  const { profile, accountMissing, signOut } = useSession();

  const deactivated = profile?.account_status === "deactivated";
  const incomplete = profile !== null && !accountMissing && !deactivated;

  return (
    <div className="centre">
      <div className="centre-card narrow">
        <Link to="/" className="brand brand-link" aria-label="TAMS home">
          <div className="brand-mark" aria-hidden="true">T</div>
          <div>
            <div className="brand-name">TAMS</div>
            <div className="brand-sub">Traditional Authority</div>
          </div>
        </Link>

        <h1 style={{ fontSize: 24, marginTop: 22 }}>You cannot access the system</h1>

        <div style={{ margin: "16px 0 22px" }}>
          {deactivated
            ? (
              <Notice kind="error">
                Your staff account has been deactivated. Contact the Council Administrator if you
                believe this is a mistake.
              </Notice>
            )
            : incomplete
            ? (
              <Notice kind="error">
                Your account is not fully set up. Contact the Council Administrator.
              </Notice>
            )
            : (
              <Notice kind="error">
                This sign-in is not linked to a staff account. Contact the Council Administrator.
              </Notice>
            )}
        </div>

        <div className="row" style={{ justifyContent: "center" }}>
          <button type="button" className="btn btn-primary" onClick={() => void signOut()}>
            Sign out
          </button>
          <Link to="/" className="btn btn-ghost">Back to home</Link>
        </div>

        <div className="auth-footer">
          <p>
            If you believe your account should work, ask the Council Administrator to check it,
            then <Link to="/auth">sign in again</Link>.
          </p>
        </div>
      </div>
    </div>
  );
}
