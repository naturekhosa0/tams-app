import { useCallback, useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { AppShell } from "../../components/AppShell";
import { Field, Loading, Notice } from "../../components/ui";
import { formatDate } from "../../lib/format";
import { issuePto, officerAllocations, releaseAllocation } from "../../registry/landApi";
import { LAND_TYPES, LAND_TYPE_LABELS } from "../../registry/landTypes";
import type { OfficerAllocationRow } from "../../registry/landTypes";
import { PageHead } from "../../components/PageHead";

const STATUSES = [
  { value: "active", label: "Active" },
  { value: "succession_pending", label: "Waiting for succession" },
  { value: "ended", label: "Ended" },
  { value: "superseded", label: "Superseded" },
  { value: "", label: "All" },
];

/** Land that is held, and land that once was. */
export function LandAllocations() {
  const [rows, setRows] = useState<OfficerAllocationRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [status, setStatus] = useState("active");
  const [landType, setLandType] = useState("");
  const [search, setSearch] = useState("");
  const [applied, setApplied] = useState("");
  const [releasing, setReleasing] = useState<OfficerAllocationRow | null>(null);
  const [busyId, setBusyId] = useState<string | null>(null);

  const load = useCallback(async () => {
    const result = await officerAllocations(status || null, landType, applied);
    if (result.ok) { setRows(result.data); setError(null); }
    else { setRows([]); setError(result.message); }
  }, [status, landType, applied]);

  useEffect(() => { void load(); }, [load]);

  return (
    <AppShell>
      <PageHead
        title="Allocations"
        description="Every allocation TAMS has made. An allocation is never edited into a different one: when it ends, it is kept and a new one is recorded."
        crumbs={[{ label: "Dashboard", to: "/land" }, { label: "Allocations" }]}
        actions={<Link to="/land" className="btn btn-ghost">Back to dashboard</Link>}
      />

      {error ? <Notice kind="error">{error}</Notice> : null}
      {success ? <div style={{ marginBottom: 18 }}><Notice kind="success">{success}</Notice></div> : null}

      <div className="card">
        <form className="filters" onSubmit={(event) => { event.preventDefault(); setApplied(search.trim()); }}>
          <Field label="Search" htmlFor="q" hint="Reference, site code, household code or name.">
            <input id="q" value={search} onChange={(event) => setSearch(event.target.value)} />
          </Field>
          <Field label="Status" htmlFor="status">
            <select id="status" value={status} onChange={(event) => setStatus(event.target.value)}>
              {STATUSES.map((option) => (
                <option key={option.value} value={option.value}>{option.label}</option>
              ))}
            </select>
          </Field>
          <Field label="Land type" htmlFor="type">
            <select id="type" value={landType} onChange={(event) => setLandType(event.target.value)}>
              <option value="">All</option>
              {LAND_TYPES.map((type) => (
                <option key={type} value={type}>{LAND_TYPE_LABELS[type]}</option>
              ))}
            </select>
          </Field>
        </form>
      </div>

      {rows === null && !error ? <Loading what="Loading allocations" /> : null}

      {rows !== null
        ? (
          <div className="card">
            <h2 className="card-title">{rows.length} allocation{rows.length === 1 ? "" : "s"}</h2>
            <div className="table-wrap">
              <table>
                <thead>
                  <tr>
                    <th>Reference</th><th>Type</th><th>Site</th><th>Held by</th>
                    <th>Allocated</th><th>Status</th><th>Permission</th><th>Actions</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.length === 0
                    ? <tr><td className="empty-row" colSpan={8}>Nothing here.</td></tr>
                    : rows.map((row) => (
                      <tr key={row.allocation_id}>
                        <td className="no-wrap">{row.allocation_reference}</td>
                        <td className="no-wrap">{LAND_TYPE_LABELS[row.land_type] ?? row.land_type}</td>
                        <td className="no-wrap">
                          <Link to={`/land/sites/${row.site_id}`}>{row.site_code}</Link>
                          <div className="status-note">{row.street_address}</div>
                        </td>
                        <td>
                          <span className="name">{row.holder_name ?? row.household_code ?? "—"}</span>
                          {row.holder_name && row.household_code
                            ? <div className="status-note">{row.household_code}</div>
                            : null}
                        </td>
                        <td className="no-wrap">{formatDate(row.allocation_date)}</td>
                        <td>
                          <span className={`badge ${row.allocation_status === "active" ? "badge-active" : "badge-deactivated"}`}>
                            {row.allocation_status.replace("_", " ")}
                          </span>
                          {row.end_reason ? <div className="status-note">{row.end_reason}</div> : null}
                        </td>
                        <td className="no-wrap">
                          {row.pto_id
                            ? (
                              <>
                                <Link to={`/pto/${row.pto_id}`}>{row.pto_number}</Link>
                                <div className="status-note">
                                  {row.pto_expiry_date ? `expires ${formatDate(row.pto_expiry_date)}` : "perpetual"}
                                  {row.pto_effective_status && row.pto_effective_status !== "active"
                                    ? ` · ${row.pto_effective_status}`
                                    : ""}
                                </div>
                              </>
                            )
                            : <span className="muted-note">None issued</span>}
                        </td>
                        <td>
                          <div className="row-actions">
                            {!row.pto_id && row.allocation_status === "active"
                              ? (
                                <button type="button" className="btn btn-ghost btn-small"
                                        disabled={busyId === row.allocation_id}
                                        onClick={async () => {
                                          setBusyId(row.allocation_id);
                                          setError(null);
                                          const result = await issuePto(row.allocation_id);
                                          setBusyId(null);
                                          if (!result.ok) { setError(result.message); return; }
                                          setSuccess(`${result.data.pto_number} has been issued.`);
                                          await load();
                                        }}>
                                  Issue PTO
                                </button>
                              )
                              : null}
                            {row.allocation_status === "active"
                              ? (
                                <button type="button" className="btn btn-danger btn-small"
                                        onClick={() => setReleasing(row)}>
                                  Release
                                </button>
                              )
                              : null}
                            {row.allocation_status === "succession_pending"
                              ? <Link to="/land/succession" className="btn btn-ghost btn-small">Succession</Link>
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

      {releasing
        ? (
          <ReleaseDialog
            allocation={releasing}
            onClose={() => setReleasing(null)}
            onDone={async (message) => {
              setReleasing(null);
              setSuccess(message);
              await load();
            }}
          />
        )
        : null}
    </AppShell>
  );
}

function ReleaseDialog({
  allocation, onClose, onDone,
}: {
  allocation: OfficerAllocationRow;
  onClose: () => void;
  onDone: (message: string) => void | Promise<void>;
}) {
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  return (
    <div className="backdrop" role="dialog" aria-modal="true" aria-label="Release an allocation">
      <div className="dialog">
        <h2>Release {allocation.allocation_reference}</h2>
        <p className="dialog-intro">
          The allocation is closed and site {allocation.site_code} becomes available again. Any
          current permission to occupy is revoked. Nothing is deleted: the allocation and the
          permission stay on record.
        </p>

        {error ? <Notice kind="error">{error}</Notice> : null}

        <div style={{ marginTop: 18 }}>
          <Field label="Why is this allocation being released?" htmlFor="release-reason">
            <textarea id="release-reason" value={reason} maxLength={1000}
                      onChange={(event) => setReason(event.target.value)} />
          </Field>
        </div>

        <div className="dialog-actions">
          <button type="button" className="btn btn-ghost" onClick={onClose}>Cancel</button>
          <button type="button" className="btn btn-danger" disabled={busy || !reason.trim()}
                  onClick={async () => {
                    setBusy(true);
                    setError(null);
                    const result = await releaseAllocation(allocation.allocation_id, reason.trim());
                    setBusy(false);
                    if (!result.ok) { setError(result.message); return; }
                    await onDone(
                      `${allocation.allocation_reference} has been released and site ` +
                        `${result.data.site_code} is ${result.data.site_status}.`,
                    );
                  }}>
            {busy ? "Releasing…" : "Release the allocation"}
          </button>
        </div>
      </div>
    </div>
  );
}
