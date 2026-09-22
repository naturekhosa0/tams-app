import { useEffect, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { homePathFor, useSession } from "../auth/SessionProvider";
import { supabase } from "../lib/supabaseClient";
import { Field, Notice } from "../components/ui";
import { MINIMUM_PASSWORD_LENGTH, recoveryLinkProblem, validateNewPassword } from "../auth/passwordRules";

/**
 * Where an invitation email lands.
 *
 * The invitation link signs the person in for this one purpose. All this
 * page does is set a password on the account that already exists — it
 * creates no staff record, no user account, and cannot change anyone's
 * role or employee number.
 */
export function SetPassword() {
  const { session, profile, loading, refresh } = useSession();
  const navigate = useNavigate();

  const [password, setPassword] = useState("");
  const [confirmation, setConfirmation] = useState("");
  const [showPassword, setShowPassword] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [done, setDone] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [linkError, setLinkError] = useState<string | null>(null);

  // Supabase sends its own failures back in the URL (expired link, link
  // already used). Read them before anything else is shown.
  useEffect(() => {
    setLinkError(recoveryLinkProblem(window.location.hash, window.location.search));
  }, []);

  async function handleSubmit(event: React.FormEvent) {
    event.preventDefault();
    setError(null);

    // The same rules the reset page applies, so a password chosen from
    // an invitation is held to exactly the standard one chosen from a
    // reset link is.
    const problem = validateNewPassword(password, confirmation);
    if (problem) { setError(problem); return; }

    setSubmitting(true);
    const { error: updateError } = await supabase.auth.updateUser({ password });
    setSubmitting(false);

    if (updateError) {
      setError(updateError.message);
      return;
    }

    await refresh();
    setDone(true);
  }

  if (loading) return <div className="loading">Checking your invitation…</div>;

  if (linkError || !session) {
    return (
      <div className="centre">
        <div className="centre-card narrow">
          <h1 style={{ fontSize: 24 }}>This invitation cannot be used</h1>
          <p style={{ color: "var(--muted)", margin: "12px 0 20px", fontSize: 14.5 }}>
            {linkError ??
              "The invitation link is missing, has already been used, or has expired. Ask the Council Administrator to send you a new invitation."}
          </p>
          <div className="row" style={{ justifyContent: "center" }}>
            <Link to="/auth" className="btn btn-primary">Go to sign in</Link>
            <Link to="/forgot-password" className="btn btn-ghost">Reset my password</Link>
            <Link to="/" className="btn btn-ghost">Back to home</Link>
          </div>
        </div>
      </div>
    );
  }

  if (done) {
    return (
      <div className="centre">
        <div className="centre-card narrow">
          <h1 style={{ fontSize: 24 }}>Your account is ready</h1>
          <p style={{ color: "var(--muted)", margin: "12px 0 20px", fontSize: 14.5 }}>
            Your password has been set. You can sign in with{" "}
            <strong>{profile?.email ?? session.user.email}</strong> from now on.
          </p>
          <div className="row" style={{ justifyContent: "center" }}>
            <button
              type="button"
              className="btn btn-primary"
              onClick={() => navigate(homePathFor(profile), { replace: true })}
            >
              Continue to my dashboard
            </button>
            <Link to="/" className="btn btn-ghost">Back to home</Link>
          </div>
        </div>
      </div>
    );
  }

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

        <h1 style={{ fontSize: 24, marginTop: 22 }}>Choose your password</h1>
        <p style={{ color: "var(--muted)", margin: "8px 0 22px", fontSize: 14.5 }}>
          Welcome{profile?.first_name ? `, ${profile.first_name}` : ""}. Your account was created
          for <strong>{session.user.email}</strong>. Choose a password to finish setting it up.
        </p>

        {profile?.role_name
          ? (
            <div className="detail-list" style={{ marginBottom: 22 }}>
              <div className="detail-item">
                <span className="label">Employee number</span>
                <span className="value">{profile.employee_number}</span>
              </div>
              <div className="detail-item">
                <span className="label">Role</span>
                <span className="value">{profile.role_name}</span>
              </div>
            </div>
          )
          : null}

        <form onSubmit={handleSubmit} className="stack" noValidate>
          {error ? <Notice kind="error">{error}</Notice> : null}

          <Field
            label="New password"
            htmlFor="new-password"
            hint={`At least ${MINIMUM_PASSWORD_LENGTH} characters.`}
          >
            <div className="input-with-button">
              <input
                id="new-password"
                type={showPassword ? "text" : "password"}
                autoComplete="new-password"
                value={password}
                onChange={(event) => setPassword(event.target.value)}
              />
              <button
                type="button"
                className="reveal"
                onClick={() => setShowPassword((visible) => !visible)}
                aria-label={showPassword ? "Hide password" : "Show password"}
              >
                {showPassword ? "Hide" : "Show"}
              </button>
            </div>
          </Field>

          <Field label="Confirm password" htmlFor="confirm-password">
            <input
              id="confirm-password"
              type={showPassword ? "text" : "password"}
              autoComplete="new-password"
              value={confirmation}
              onChange={(event) => setConfirmation(event.target.value)}
            />
          </Field>

          <button type="submit" className="btn btn-primary btn-block" disabled={submitting}>
            {submitting ? "Saving…" : "Save password"}
          </button>
        </form>

        <div className="auth-footer">
          <p>
            Already set a password? <Link to="/auth">Sign in</Link> ·{" "}
            <Link to="/">Back to home</Link>
          </p>
        </div>
      </div>
    </div>
  );
}
