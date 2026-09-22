import { useCallback, useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { AppShell } from "../../components/AppShell";
import { Field, Loading, Notice } from "../../components/ui";
import { formatDate, formatDateTime } from "../../lib/format";
import { approveRenewal, declineRenewal, renewalRequests } from "../../registry/landApi";
import { LAND_TYPE_LABELS } from "../../registry/landTypes";
import type { RenewalRow } from "../../registry/landTypes";
import { PageHead } from "../../components/PageHead";

const STATUSES = [
  { value: "pending", label: "Waiting for review" },
  { value: "approved", label: "Approved" },
  { value: "declined", label: "Declined" },
  { value: "", label: "All" },
];

/** Renewals, which exist only for farming and business land. */
export function LandRenewals() {
  const [rows, setRows] = useState<RenewalRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [status, setStatus] = useState("pending");
  const [declining, setDeclining] = useState<RenewalRow | null>(null);
  const [busyId, setBusyId] = useState<string | null>(null);

  const load = useCallback(async () => {
    const result = await renewalRequests(status || null);
    if (result.ok) { setRows(result.data); setError(null); }
    else { setRows([]); setError(result.message); }
  }, [status]);

  useEffect(() => { void load(); }, [load]);

  return (
    <AppShell>
      <PageHead
        title="Renewal requests"
        description="Approving a renewal issues a brand new permission and keeps the old one on record as renewed. Nothing is overwritten, and the site does not change."
        crumbs={[{ label: "Dashboard", to: "/land" }, { label: "Renewals" }]}
        actions={<Link to="/land" className="btn btn-ghost">Back to dashboard</Link>}
      />

      {error ? <Notice kind="error">{error}</Notice> : null}
      {success ? <div style={{ marginBottom: 18 }}><Notice kind="success">{success}</Notice></div> : null}

      <div className="card">
        <div className="filters">
          <Field label="Status" htmlFor="status">
            <select id="status" value={status} onChange={(event) => setStatus(event.target.value)}>
              {STATUSES.map((option) => (
                <option key={option.value} value={option.value}>{option.label}</option>
              ))}
            </select>
          </Field>
        </div>
      </div>

      {rows === null && !error ? <Loading what="Loading renewal requests" /> : null}

      {rows !== null
        ? (
          <div className="card">
            <h2 className="card-title">{rows.length} request{rows.length === 1 ? "" : "s"}</h2>
            <div className="table-wrap">
              <table>
                <thead>
                  <tr>
                    <th>PTO number</th><th>Type</th><th>Site</th><th>Held by</th>
                    <th>Expires</th><th>Requested</th><th>Status</th><th>Actions</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.length === 0
                    ? <tr><td className="empty-row" colSpan={8}>Nothing here.</td></tr>
                    : rows.map((row) => (
                      <tr key={row.renewal_request_id}>
                        <td className="no-wrap">{row.pto_number}</td>
                        <td className="no-wrap">{LAND_TYPE_LABELS[row.land_type] ?? row.land_type}</td>
                        <td className="no-wrap">{row.site_code}</td>
                        <td>
                          <span className="name">{row.holder_name ?? row.household_code ?? "—"}</span>
                          {row.reason ? <div className="status-note">{row.reason}</div> : null}
                        </td>
                        <td className="no-wrap">
                          {formatDate(row.expiry_date)}
                          <div className="status-note">{row.effective_status}</div>
                        </td>
                        <td className="no-wrap">{formatDateTime(row.requested_at)}</td>
                        <td>
                          <span className={`badge ${row.request_status === "approved" ? "badge-active" : "badge-deactivated"}`}>
                            {row.request_status}
                          </span>
                          {row.decline_reason
                            ? <div className="status-note">{row.decline_reason}</div>
                            : null}
                        </td>
                        <td>
                          {row.request_status === "pending"
                            ? (
                              <div className="row-actions">
                                <button type="button" className="btn btn-primary btn-small"
                                        disabled={busyId === row.renewal_request_id}
                                        onClick={async () => {
                                          setBusyId(row.renewal_request_id);
                                          setError(null);
                                          const result = await approveRenewal(row.renewal_request_id);
                                          setBusyId(null);
                                          if (!result.ok) { setError(result.message); return; }
                                          setSuccess(
                                            `${result.data.pto_number} has been issued, running to ` +
                                              `${formatDate(result.data.expiry_date)}.`,
                                          );
                                          await load();
                                        }}>
                                  Approve
                                </button>
                                <button type="button" className="btn btn-danger btn-small"
                                        onClick={() => setDeclining(row)}>
                                  Decline
                                </button>
                              </div>
                            )
                            : <span className="muted-note">—</span>}
                        </td>
                      </tr>
                    ))}
                </tbody>
              </table>
            </div>
          </div>
        )
        : null}

      {declining
        ? (
          <DeclineDialog
            request={declining}
            onClose={() => setDeclining(null)}
            onDone={async (message) => {
              setDeclining(null);
              setSuccess(message);
              await load();
            }}
          />
        )
        : null}
    </AppShell>
  );
}

function DeclineDialog({
  request, onClose, onDone,
}: { request: RenewalRow; onClose: () => void; onDone: (message: string) => void | Promise<void> }) {
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  return (
    <div className="backdrop" role="dialog" aria-modal="true" aria-label="Decline a renewal">
      <div className="dialog">
        <h2>Decline the renewal of {request.pto_number}</h2>
        <p className="dialog-intro">
          The holder sees the reason you give. The existing permission is left exactly as it is —
          declining a renewal does not revoke anything.
        </p>

        {error ? <Notice kind="error">{error}</Notice> : null}

        <div style={{ marginTop: 18 }}>
          <Field label="Why is the renewal declined?" htmlFor="renewal-decline-reason">
            <textarea id="renewal-decline-reason" value={reason} maxLength={1000}
                      onChange={(event) => setReason(event.target.value)} />
          </Field>
        </div>

        <div className="dialog-actions">
          <button type="button" className="btn btn-ghost" onClick={onClose}>Cancel</button>
          <button type="button" className="btn btn-danger" disabled={busy || !reason.trim()}
                  onClick={async () => {
                    setBusy(true);
                    setError(null);
                    const result = await declineRenewal(request.renewal_request_id, reason.trim());
                    setBusy(false);
                    if (!result.ok) { setError(result.message); return; }
                    await onDone(`The renewal of ${request.pto_number} has been declined.`);
                  }}>
            {busy ? "Declining…" : "Decline the renewal"}
          </button>
        </div>
      </div>
    </div>
  );
}
