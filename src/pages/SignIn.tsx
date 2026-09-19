import { useState } from "react";
import { Navigate, useNavigate } from "react-router-dom";
import { homePathFor, useSession } from "../auth/SessionProvider";
import { supabase } from "../lib/supabaseClient";
import { Field, Loading, Notice } from "../components/ui";

/**
 * The single sign-in page for every staff role.
 *
 * Signing in only proves the password was right. Whether the person may
 * use the system is decided afterwards by the database record:
 * account_type, account_status, the staff record and the current role.
 */
export function SignIn() {
  const { loading, session, profile, refresh } = useSession();
  const navigate = useNavigate();

  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [showPassword, setShowPassword] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  if (loading) return <Loading />;
  if (session) return <Navigate to={homePathFor(profile)} replace />;

  async function handleSubmit(event: React.FormEvent) {
    event.preventDefault();
    setError(null);

    if (!email.trim() || !password) {
      setError("Enter your email address and password.");
      return;
    }

    setSubmitting(true);
    const { error: signInError } = await supabase.auth.signInWithPassword({
      email: email.trim().toLowerCase(),
      password,
    });

    if (signInError) {
      setSubmitting(false);
      setError("Those sign-in details were not recognised.");
      return;
    }

    // Read the account from the database, then send the person to the
    // area their current role allows.
    const { data: context } = await supabase.rpc("current_staff_context");
    await supabase.rpc("record_login");
    await refresh();
    setSubmitting(false);
    navigate(homePathFor(context ?? null), { replace: true });
  }

  return (
    <div className="centre">
      <div className="centre-card narrow">
        <div className="brand">
          <div className="brand-mark" aria-hidden="true">T</div>
          <div>
            <div className="brand-name">TAMS</div>
            <div className="brand-sub">Traditional Authority</div>
          </div>
        </div>

        <h1 style={{ fontSize: 26, marginTop: 26 }}>Sign in</h1>
        <p style={{ color: "var(--muted)", margin: "8px 0 22px", fontSize: 14.5 }}>
          Use your email address and password.
        </p>

        <form onSubmit={handleSubmit} className="stack" noValidate>
          {error ? <Notice kind="error">{error}</Notice> : null}

          <Field label="Email" htmlFor="email">
            <input
              id="email"
              type="email"
              autoComplete="username"
              value={email}
              onChange={(event) => setEmail(event.target.value)}
            />
          </Field>

          <Field label="Password" htmlFor="password">
            <div className="input-with-button">
              <input
                id="password"
                type={showPassword ? "text" : "password"}
                autoComplete="current-password"
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

          <button type="submit" className="btn btn-primary btn-block" disabled={submitting}>
            {submitting ? "Signing in…" : "Sign in"}
          </button>
        </form>

        <p style={{ marginTop: 18, fontSize: 14, color: "var(--muted)" }}>
          Staff accounts are created by the Council Administrator. There is no public sign-up.
        </p>
      </div>
    </div>
  );
}
