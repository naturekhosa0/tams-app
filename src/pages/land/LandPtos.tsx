import { useCallback, useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { AppShell } from "../../components/AppShell";
import { Field, Loading, Notice } from "../../components/ui";
import { formatDate } from "../../lib/format";
import { officerPtos, revokePto } from "../../registry/landApi";
import { LAND_TYPE_LABELS } from "../../registry/landTypes";
import type { OfficerPtoRow } from "../../registry/landTypes";
import { PageHead } from "../../components/PageHead";

const STATUSES = [
  { value: "", label: "All" },
  { value: "active", label: "Active" },
  { value: "expired", label: "Lapsed" },
  { value: "renewed", label: "Renewed" },
  { value: "revoked", label: "Revoked" },
  { value: "superseded", label: "Superseded" },
];

const BADGE: Record<string, string> = { active: "badge-active" };

/** Every permission to occupy that has ever been issued. */
export function LandPtos() {
  const [rows, setRows] = useState<OfficerPtoRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [search, setSearch] = useState("");
  const [applied, setApplied] = useState("");
  const [status, setStatus] = useState("");
  const [revoking, setRevoking] = useState<OfficerPtoRow | null>(null);

  const load = useCallback(async () => {
    const result = await officerPtos(applied, status);
    if (result.ok) { setRows(result.data); setError(null); }
    else { setRows([]); setError(result.message); }
  }, [applied, status]);

  useEffect(() => { void load(); }, [load]);

  return (
    <AppShell>
      <PageHead
        title="Permissions to occupy"
        description="Residential and burial permissions are perpetual and carry no expiry date at all. Farming runs for five years and business for two — a lapsed permission is one whose expiry date has passed, worked out from the date, not from a nightly job."
        crumbs={[{ label: "Dashboard", to: "/land" }, { label: "PTOs" }]}
        actions={<Link to="/land" className="btn btn-ghost">Back to dashboard</Link>}
      />

      {error ? <Notice kind="error">{error}</Notice> : null}
      {success ? <div style={{ marginBottom: 18 }}><Notice kind="success">{success}</Notice></div> : null}

      <div className="card">
        <form className="filters" onSubmit={(event) => { event.preventDefault(); setApplied(search.trim()); }}>
          <Field label="Search" htmlFor="q" hint="PTO number, site code, household code or holder.">
            <input id="q" value={search} onChange={(event) => setSearch(event.target.value)} />
          </Field>
          <Field label="Status" htmlFor="status">
            <select id="status" value={status} onChange={(event) => setStatus(event.target.value)}>
              {STATUSES.map((option) => (
                <option key={option.value} value={option.value}>{option.label}</option>
              ))}
            </select>
          </Field>
          <div className="form-actions">
            <button type="submit" className="btn btn-ghost">Search</button>
          </div>
        </form>
      </div>

      {rows === null && !error ? <Loading what="Loading permissions" /> : null}

      {rows !== null
        ? (
          <div className="card">
            <h2 className="card-title">{rows.length} permission{rows.length === 1 ? "" : "s"}</h2>
            <div className="table-wrap">
              <table>
                <thead>
                  <tr>
                    <th>PTO number</th><th>Type</th><th>Site</th><th>Held by</th>
                    <th>Issued</th><th>Expires</th><th>Status</th><th>Actions</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.length === 0
                    ? <tr><td className="empty-row" colSpan={8}>Nothing here.</td></tr>
                    : rows.map((row) => (
                      <tr key={row.pto_id}>
                        <td className="no-wrap">{row.pto_number}</td>
                        <td className="no-wrap">{LAND_TYPE_LABELS[row.land_type] ?? row.land_type}</td>
                        <td className="no-wrap">{row.site_code}</td>
                        <td>
                          <span className="name">{row.holder_name ?? row.household_code ?? "—"}</span>
                          {row.holder_name && row.household_code
                            ? <div className="status-note">{row.household_code}</div>
                            : null}
                        </td>
                        <td className="no-wrap">{formatDate(row.issue_date)}</td>
                        <td className="no-wrap">
                          {row.expiry_date ? formatDate(row.expiry_date) : <span className="muted-note">Perpetual</span>}
                        </td>
                        <td>
                          <span className={`badge ${BADGE[row.effective_status] ?? "badge-deactivated"}`}>
                            {row.effective_status}
                          </span>
                          {row.effective_status !== row.stored_status
                            ? <div className="status-note">recorded as {row.stored_status}</div>
                            : null}
                        </td>
                        <td>
                          <div className="row-actions">
                            <Link to={`/pto/${row.pto_id}`} className="btn btn-ghost btn-small">View</Link>
                            {row.stored_status === "active"
                              ? (
                                <button type="button" className="btn btn-danger btn-small"
                                        onClick={() => setRevoking(row)}>
                                  Revoke
                                </button>
                              )
                              : null}
                          </div>
                        </td>
                      </tr>
                    ))}
                </tbody>
              </table>
            </div>
          </div>
        )
        : null}

      {revoking
        ? (
          <RevokeDialog
            pto={revoking}
            onClose={() => setRevoking(null)}
            onDone={async (message) => {
              setRevoking(null);
              setSuccess(message);
              await load();
            }}
          />
        )
        : null}
    </AppShell>
  );
}

function RevokeDialog({
  pto, onClose, onDone,
}: { pto: OfficerPtoRow; onClose: () => void; onDone: (message: string) => void | Promise<void> }) {
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  return (
    <div className="backdrop" role="dialog" aria-modal="true" aria-label="Revoke a permission">
      <div className="dialog">
        <h2>Revoke {pto.pto_number}</h2>
        <p className="dialog-intro">
          The permission stops being valid and anyone who checks the document will be told so.
          It is kept on record with the reason — it is never deleted. Revoking a permission does
          not by itself release the allocation.
        </p>

        {error ? <Notice kind="error">{error}</Notice> : null}

        <div style={{ marginTop: 18 }}>
          <Field label="Why is this permission being revoked?" htmlFor="revoke-reason">
            <textarea id="revoke-reason" value={reason} maxLength={1000}
                      onChange={(event) => setReason(event.target.value)} />
          </Field>
        </div>

        <div className="dialog-actions">
          <button type="button" className="btn btn-ghost" onClick={onClose}>Cancel</button>
          <button type="button" className="btn btn-danger" disabled={busy || !reason.trim()}
                  onClick={async () => {
                    setBusy(true);
                    setError(null);
                    const result = await revokePto(pto.pto_id, reason.trim());
                    setBusy(false);
                    if (!result.ok) { setError(result.message); return; }
                    await onDone(`${result.data.pto_number} has been revoked.`);
                  }}>
            {busy ? "Revoking…" : "Revoke the permission"}
          </button>
        </div>
      </div>
    </div>
  );
}
