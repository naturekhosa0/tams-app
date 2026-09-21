import { useCallback, useEffect, useState } from "react";
import { useSession } from "../../auth/SessionProvider";
import { Loading, Notice } from "../../components/ui";
import { VerificationForm } from "./VerificationForm";
import { ResidentLand } from "../land/ResidentLand";
import { formatDate, formatDateTime, initialsOf } from "../../lib/format";
import { ensureResidentAccount, residentPortal } from "../../registry/residentApi";
import type { ResidentPortal as Portal } from "../../registry/residentApi";
import { supabase } from "../../lib/supabaseClient";

/**
 * Where a resident lands. What they see depends entirely on where their
 * verification stands — and until it is approved, there is nothing else
 * here for them to reach.
 */
export function ResidentPortalPage() {
  const { session, profile, refresh } = useSession();
  const [portal, setPortal] = useState<Portal | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [applying, setApplying] = useState(false);
  const [success, setSuccess] = useState<string | null>(null);

  const load = useCallback(async () => {
    // A brand new sign-in has no account row until it asks for one.
    const ensured = await ensureResidentAccount();
    if (!ensured.ok) { setError(ensured.message); return; }

    const result = await residentPortal();
    if (!result.ok) { setError(result.message); return; }
    setPortal(result.data);
    setError(null);
  }, []);

  useEffect(() => { void load(); }, [load]);

  if (error) {
    return (
      <div className="centre">
        <div className="centre-card narrow">
          <h1 style={{ fontSize: 22 }}>Your account</h1>
          <div style={{ marginTop: 16 }}><Notice kind="error">{error}</Notice></div>
          <button type="button" className="btn btn-ghost" style={{ marginTop: 18 }}
                  onClick={() => void supabase.auth.signOut()}>
            Sign out
          </button>
        </div>
      </div>
    );
  }

  if (!portal) return <Loading what="Loading your account" />;

  if (applying) {
    return (
      <VerificationForm
        authUserId={session?.user.id ?? ""}
        email={portal.email}
        previous={portal.latest_request}
        onCancel={() => setApplying(false)}
        onDone={async (message: string) => {
          setApplying(false);
          setSuccess(message);
          await load();
          await refresh();
        }}
      />
    );
  }

  const status = portal.account_status;

  return (
    <div className="page">
      <header className="topbar">
        <div className="brand">
          <div className="brand-mark" aria-hidden="true">T</div>
          <div>
            <div className="brand-name">TAMS</div>
            <div className="brand-sub">Traditional Authority</div>
          </div>
        </div>
        <div className="who">
          <div className="avatar" aria-hidden="true">
            {initialsOf(portal.resident?.full_name ?? null, portal.email)}
          </div>
          <span className="who-email">{portal.email}</span>
          <button type="button" className="btn btn-ghost" onClick={() => void supabase.auth.signOut()}>
            Sign out
          </button>
        </div>
      </header>

      <div className="page-head">
        <h1>
          {status === "active" && portal.resident
            ? `Welcome, ${portal.resident.full_name.split(" ")[0]}`
            : "Your resident account"}
        </h1>
        <p>{portal.email}</p>
      </div>

      {success ? <div style={{ marginBottom: 18 }}><Notice kind="success">{success}</Notice></div> : null}

      <div className="grid-2">
        <div className="card">
          <h2 className="card-title">Account status</h2>

          {status === "pending"
            ? (
              <>
                <Notice kind="info">
                  {portal.latest_request
                    ? "Your account is awaiting verification by the Registry Clerk."
                    : "Your sign-in is ready. Send us your details and documents to be verified."}
                </Notice>
                <div className="detail-list" style={{ marginTop: 18 }}>
                  <div className="detail-item">
                    <span className="label">Status</span>
                    <span className="value"><span className="badge badge-deactivated">Pending</span></span>
                  </div>
                  {portal.latest_request
                    ? (
                      <div className="detail-item">
                        <span className="label">Submitted</span>
                        <span className="value">{formatDateTime(portal.latest_request.submitted_at)}</span>
                      </div>
                    )
                    : null}
                </div>
              </>
            )
            : null}

          {status === "declined"
            ? (
              <>
                <Notice kind="error">
                  Your verification was declined. You can correct your details and apply again with
                  this same account.
                </Notice>
                <div className="detail-list" style={{ marginTop: 18 }}>
                  <div className="detail-item">
                    <span className="label">Status</span>
                    <span className="value"><span className="badge badge-deactivated">Declined</span></span>
                  </div>
                  <div className="detail-item">
                    <span className="label">Reviewed</span>
                    <span className="value">{formatDate(portal.latest_request?.reviewed_at ?? null)}</span>
                  </div>
                  <div className="detail-item">
                    <span className="label">Reason</span>
                    <span className="value">{portal.latest_request?.decline_reason ?? "—"}</span>
                  </div>
                </div>
              </>
            )
            : null}

          {status === "active"
            ? (
              <>
                <Notice kind="success">Your resident account is active.</Notice>
                <div className="detail-list" style={{ marginTop: 18 }}>
                  <div className="detail-item">
                    <span className="label">Status</span>
                    <span className="value"><span className="badge badge-active">Active</span></span>
                  </div>
                  {portal.resident
                    ? (
                      <>
                        <div className="detail-item">
                          <span className="label">Registered name</span>
                          <span className="value">{portal.resident.full_name}</span>
                        </div>
                        <div className="detail-item">
                          <span className="label">Household</span>
                          <span className="value">{portal.resident.household_code ?? "—"}</span>
                        </div>
                        <div className="detail-item">
                          <span className="label">Address</span>
                          <span className="value">{portal.resident.street_address ?? "—"}</span>
                        </div>
                      </>
                    )
                    : null}
                </div>
              </>
            )
            : null}

          {status === "deactivated"
            ? (
              <Notice kind="error">
                This account has been deactivated. Contact the traditional authority office.
              </Notice>
            )
            : null}

          {portal.may_submit
            ? (
              <div style={{ marginTop: 22 }}>
                <button type="button" className="btn btn-primary" onClick={() => setApplying(true)}>
                  {portal.latest_request ? "Apply again" : "Start verification"}
                </button>
              </div>
            )
            : null}
        </div>

        <div className="card">
          <h2 className="card-title">
            {status === "active" ? "What happens next" : "Your applications"}
          </h2>

          {status === "active"
            ? (
              <div className="bullet-list">
                <p>Your account is verified and linked to your record on the village register.</p>
                <p>
                  You can apply for land below. TAMS allocates residential, farming, business and
                  burial land; you apply for a kind of land and the Land Officer chooses the site.
                </p>
                <p style={{ color: "var(--muted)" }}>
                  You never need to send your identity document or proof of address again — they
                  are already on your verified account.
                </p>
              </div>
            )
            : portal.attempts.length === 0
            ? <p className="muted-note">You have not sent anything for verification yet.</p>
            : (
              <div className="stack">
                {portal.attempts.map((attempt, index) => (
                  <div className="lineage-row" key={`${attempt.submitted_at}-${index}`}>
                    <div>
                      <span className="name">
                        {attempt.request_status === "pending" ? "Awaiting review"
                          : attempt.request_status === "approved" ? "Approved"
                          : "Declined"}
                      </span>
                      <div className="status-note">
                        Sent {formatDate(attempt.submitted_at)}
                        {attempt.decline_reason ? ` · ${attempt.decline_reason}` : ""}
                      </div>
                    </div>
                  </div>
                ))}
              </div>
            )}

          <p className="muted-note" style={{ marginTop: 18 }}>
            Having an account here does not by itself make you a registered resident. The
            Registry Clerk checks your details against the village register.
          </p>
        </div>
      </div>

      {status === "active"
        ? <div style={{ marginTop: 22 }}><ResidentLand /></div>
        : null}

      {profile?.account_type === "staff"
        ? <div style={{ marginTop: 18 }}><Notice kind="info">You are signed in as staff.</Notice></div>
        : null}
    </div>
  );
}
