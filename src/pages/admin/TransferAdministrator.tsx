import { useEffect, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { useSession } from "../../auth/SessionProvider";
import { AppShell } from "../../components/AppShell";
import { PageHead } from "../../components/PageHead";
import { Field, Loading, Notice } from "../../components/ui";
import { supabase } from "../../lib/supabaseClient";
import { transferAdministrator, transferCandidates } from "../../registry/adminApi";
import type { TransferCandidate } from "../../registry/adminApi";

const CONFIRMATION = "TRANSFER";

/**
 * Handing over control of TAMS. It happens in one transaction: either
 * the whole handover took place or none of it did, and at no committed
 * moment are there two active administrators or none.
 */
export function TransferAdministrator() {
  const { profile, refresh } = useSession();
  const navigate = useNavigate();
  const [candidates, setCandidates] = useState<TransferCandidate[] | null>(null);
  const [roles, setRoles] = useState<{ id: string; role_name: string }[]>([]);
  const [incoming, setIncoming] = useState("");
  const [outcome, setOutcome] = useState<"remain_staff" | "deactivate">("remain_staff");
  const [outgoingRole, setOutgoingRole] = useState("");
  const [reason, setReason] = useState("");
  const [typed, setTyped] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [confirming, setConfirming] = useState(false);

  useEffect(() => {
    let cancelled = false;
    transferCandidates().then((result) => {
      if (cancelled) return;
      if (result.ok) setCandidates(result.data);
      else setError(result.message);
    });
    // The three ordinary roles. The administrator role is never among
    // them: it is what is being handed over, not something to choose.
    supabase.rpc("assignable_staff_roles").then(({ data }) => {
      if (cancelled || !data) return;
      setRoles((data as { id: string; role_name: string }[])
        .filter((role) => role.role_name !== "Council Administrator"));
    });
    return () => { cancelled = true; };
  }, []);

  const chosen = (candidates ?? []).find((person) => person.staff_id === incoming) ?? null;
  const ready = incoming && reason.trim()
    && (outcome === "deactivate" || outgoingRole);

  return (
    <AppShell>
      <PageHead
        title="Transfer administrator"
        description="Pass the Council Administrator role to another member of staff. This is the only way it ever moves."
        crumbs={[{ label: "Dashboard", to: "/dashboard" }, { label: "Transfer administrator" }]}
        back={{ to: "/dashboard", label: "Back to dashboard" }}
      />

      <div className="card">
        <Notice kind="error">
          <strong>This transfers control of TAMS to another staff member.</strong> Once it is done
          you will no longer be the Council Administrator, and you will not be able to undo it
          yourself.
        </Notice>
      </div>

      {error ? <Notice kind="error">{error}</Notice> : null}
      {candidates === null && !error ? <Loading what="Loading eligible staff" /> : null}

      {candidates
        ? candidates.length === 0
          ? (
            <div className="card">
              <Notice kind="info">
                There is nobody to transfer to. The incoming administrator has to be an existing,
                active staff member who currently holds one of the three ordinary roles.
              </Notice>
              <div className="row" style={{ marginTop: 18 }}>
                <Link to="/staff/new" className="btn btn-primary">Create a staff account</Link>
                <Link to="/dashboard" className="btn btn-ghost">Back to dashboard</Link>
              </div>
            </div>
          )
          : (
            <form
              className="card"
              style={{ maxWidth: 780 }}
              onSubmit={(event) => { event.preventDefault(); setConfirming(true); }}
            >
              <h2 className="card-title">The incoming administrator</h2>
              <div className="picker">
                {candidates.map((person) => (
                  <button type="button" key={person.staff_id}
                          className={`picker-row${incoming === person.staff_id ? " chosen" : ""}`}
                          onClick={() => setIncoming(person.staff_id)}>
                    <span className="name">{person.full_name}</span>
                    <span className="status-note">
                      {person.role_name} · employee no. {person.employee_number} · {person.email}
                    </span>
                  </button>
                ))}
              </div>
              <p className="muted-note" style={{ marginTop: 12 }}>
                Only existing, active staff holding an ordinary role appear here. No new account is
                created by a transfer.
              </p>

              <h2 className="card-title" style={{ marginTop: 26 }}>What becomes of you</h2>
              <Field label="After the transfer (required)" htmlFor="outcome">
                <select id="outcome" value={outcome}
                        onChange={(event) => setOutcome(event.target.value as typeof outcome)}>
                  <option value="remain_staff">I stay on as staff, in an ordinary role</option>
                  <option value="deactivate">My account is deactivated</option>
                </select>
              </Field>

              {outcome === "remain_staff"
                ? (
                  <div style={{ marginTop: 16 }}>
                    <Field label="The role I will hold (required)" htmlFor="outgoingRole">
                      <select id="outgoingRole" value={outgoingRole}
                              onChange={(event) => setOutgoingRole(event.target.value)}>
                        <option value="">Choose…</option>
                        {roles.map((role) => (
                          <option key={role.id} value={role.id}>{role.role_name}</option>
                        ))}
                      </select>
                    </Field>
                  </div>
                )
                : (
                  <p className="muted-note" style={{ marginTop: 12 }}>
                    Your account is deactivated and your record keeps saying you were the Council
                    Administrator. You will be signed out of TAMS at your next request.
                  </p>
                )}

              <div style={{ marginTop: 16 }}>
                <Field label="Reason for the transfer (required)" htmlFor="reason"
                       hint="For example: end of term, resignation, staff restructuring.">
                  <textarea id="reason" value={reason} maxLength={500}
                            onChange={(event) => setReason(event.target.value)} />
                </Field>
              </div>

              <div className="form-actions" style={{ marginTop: 22 }}>
                <button type="submit" className="btn btn-danger" disabled={!ready}>
                  Continue
                </button>
                <Link to="/dashboard" className="btn btn-ghost">Cancel</Link>
              </div>
            </form>
          )
        : null}

      {confirming && chosen
        ? (
          <div className="backdrop" role="dialog" aria-modal="true" aria-label="Confirm the transfer">
            <div className="dialog">
              <h2>Transfer control of TAMS</h2>
              <p className="dialog-intro">
                <strong>{chosen.full_name}</strong> becomes the Council Administrator, in place of{" "}
                {profile?.full_name ?? "you"}.
                {outcome === "remain_staff"
                  ? ` You become a ${roles.find((r) => r.id === outgoingRole)?.role_name ?? "staff member"}.`
                  : " Your account is deactivated."}
                {" "}This cannot be undone by you afterwards.
              </p>

              {error ? <Notice kind="error">{error}</Notice> : null}

              <div style={{ marginTop: 18 }}>
                <Field label={`Type ${CONFIRMATION} to confirm`} htmlFor="typed">
                  <input id="typed" value={typed} autoComplete="off"
                         onChange={(event) => setTyped(event.target.value)} />
                </Field>
              </div>

              <div className="dialog-actions">
                <button type="button" className="btn btn-ghost"
                        onClick={() => { setConfirming(false); setTyped(""); }}>
                  Cancel
                </button>
                <button type="button" className="btn btn-danger"
                        disabled={busy || typed.trim().toUpperCase() !== CONFIRMATION}
                        onClick={async () => {
                          setBusy(true);
                          setError(null);
                          const result = await transferAdministrator(
                            incoming, outcome, reason.trim(),
                            outcome === "remain_staff" ? outgoingRole : null);
                          setBusy(false);
                          if (!result.ok) { setError(result.message); return; }
                          // Their own authorisation has just changed, so
                          // re-read it and send them where they now belong.
                          await refresh();
                          navigate(outcome === "deactivate" ? "/no-access" : "/home", { replace: true });
                        }}>
                  {busy ? "Transferring…" : "Transfer administrator"}
                </button>
              </div>
            </div>
          </div>
        )
        : null}
    </AppShell>
  );
}
