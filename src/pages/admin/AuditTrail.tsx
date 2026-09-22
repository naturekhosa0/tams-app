import { useCallback, useEffect, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { AppShell } from "../../components/AppShell";
import { PageHead } from "../../components/PageHead";
import { Field, Loading, Notice } from "../../components/ui";
import { formatDateTime } from "../../lib/format";
import { auditFilterValues, auditLogs } from "../../registry/adminApi";
import type { AuditFilters, AuditRow } from "../../registry/adminApi";

/** Words TAMS spells out rather than sentence-cases. */
const ACRONYMS: Record<string, string> = { pto: "PTO", ptos: "PTOs", tams: "TAMS", id: "ID" };

function spell(word: string): string {
  return ACRONYMS[word] ?? word;
}

/** A phrase an administrator reads, rather than a database action name. */
export function readableAction(action: string): string {
  const words = action.toLowerCase().split("_").map(spell);
  const first = words[0];
  return [ACRONYMS[first.toLowerCase()] ?? first.charAt(0).toUpperCase() + first.slice(1),
          ...words.slice(1)].join(" ");
}

export function readableEntity(entity: string): string {
  return entity.split("_").map(spell).join(" ");
}

const emptyFilters = {
  from: "", to: "", actor: "", actorRole: "", action: "", entityType: "", reference: "",
};

/** The whole trail, for the Council Administrator and nobody else. */
export function AuditTrail() {
  const navigate = useNavigate();
  const [filters, setFilters] = useState(emptyFilters);
  const [applied, setApplied] = useState(emptyFilters);
  const [rows, setRows] = useState<AuditRow[] | null>(null);
  const [options, setOptions] = useState<AuditFilters | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    const result = await auditLogs({ ...applied, limit: 500 });
    if (result.ok) { setRows(result.data); setError(null); }
    else { setRows([]); setError(result.message); }
  }, [applied]);

  useEffect(() => { void load(); }, [load]);

  useEffect(() => {
    let cancelled = false;
    auditFilterValues().then((result) => {
      if (!cancelled && result.ok) setOptions(result.data);
    });
    return () => { cancelled = true; };
  }, []);

  const update = (key: keyof typeof emptyFilters, value: string) =>
    setFilters((current) => ({ ...current, [key]: value }));

  // The export is exactly what is on screen, which is exactly what the
  // database was willing to hand over.
  const exportCsv = () => {
    if (!rows || rows.length === 0) return;
    const header = ["When", "Actor", "Role", "Action", "Entity", "Reference", "Changed fields", "Reason"];
    const escape = (value: string) => `"${value.replace(/"/g, '""')}"`;
    const lines = [header.map(escape).join(",")];
    for (const row of rows) {
      lines.push([
        new Date(row.created_at).toISOString(),
        row.actor_label ?? "",
        row.actor_role ?? "",
        row.action,
        row.entity_type,
        row.entity_reference ?? "",
        (row.changed_fields ?? []).join(" "),
        row.reason ?? "",
      ].map(escape).join(","));
    }
    const blob = new Blob([lines.join("\r\n")], { type: "text/csv;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement("a");
    anchor.href = url;
    anchor.download = `tams-audit-${new Date().toISOString().slice(0, 10)}.csv`;
    anchor.click();
    URL.revokeObjectURL(url);
  };

  return (
    <AppShell>
      <PageHead
        title="Audit trail"
        description="Who changed what, when, from what, to what, and why."
        crumbs={[{ label: "Dashboard", to: "/dashboard" }, { label: "Audit trail" }]}
        actions={
          <>
            <Link to="/dashboard" className="btn btn-ghost">Back to dashboard</Link>
            <button type="button" className="btn btn-primary"
                    disabled={!rows || rows.length === 0} onClick={exportCsv}>
              Export this view as CSV
            </button>
          </>
        }
      />

      {error ? <Notice kind="error">{error}</Notice> : null}

      <div className="card">
        <form
          onSubmit={(event) => { event.preventDefault(); setApplied(filters); }}
        >
          <div className="filters">
            <Field label="From" htmlFor="from">
              <input id="from" type="date" value={filters.from}
                     onChange={(event) => update("from", event.target.value)} />
            </Field>
            <Field label="To" htmlFor="to">
              <input id="to" type="date" value={filters.to}
                     onChange={(event) => update("to", event.target.value)} />
            </Field>
            <Field label="Actor" htmlFor="actor" hint="Name, employee number or email.">
              <input id="actor" value={filters.actor}
                     onChange={(event) => update("actor", event.target.value)} />
            </Field>
          </div>

          <div className="filters" style={{ marginTop: 16 }}>
            <Field label="Role at the time" htmlFor="actorRole">
              <select id="actorRole" value={filters.actorRole}
                      onChange={(event) => update("actorRole", event.target.value)}>
                <option value="">Any</option>
                {(options?.actor_roles ?? []).map((role) => (
                  <option key={role} value={role}>{role}</option>
                ))}
              </select>
            </Field>
            <Field label="Action" htmlFor="action">
              <select id="action" value={filters.action}
                      onChange={(event) => update("action", event.target.value)}>
                <option value="">Any</option>
                {(options?.actions ?? []).map((action) => (
                  <option key={action} value={action}>{readableAction(action)}</option>
                ))}
              </select>
            </Field>
            <Field label="Kind of record" htmlFor="entityType">
              <select id="entityType" value={filters.entityType}
                      onChange={(event) => update("entityType", event.target.value)}>
                <option value="">Any</option>
                {(options?.entity_types ?? []).map((entity) => (
                  <option key={entity} value={entity}>{readableEntity(entity)}</option>
                ))}
              </select>
            </Field>
          </div>

          <div className="filters" style={{ marginTop: 16 }}>
            <Field label="Reference" htmlFor="reference"
                   hint="A site code, an application reference, an identity number.">
              <input id="reference" value={filters.reference}
                     onChange={(event) => update("reference", event.target.value)} />
            </Field>
            <div className="form-actions">
              <button type="submit" className="btn btn-primary">Apply filters</button>
            </div>
            <div className="form-actions">
              <button type="button" className="btn btn-ghost"
                      onClick={() => { setFilters(emptyFilters); setApplied(emptyFilters); }}>
                Clear
              </button>
            </div>
          </div>
        </form>
      </div>

      {rows === null && !error ? <Loading what="Loading the audit trail" /> : null}

      {rows !== null
        ? (
          <div className="card">
            <h2 className="card-title">
              {rows.length} event{rows.length === 1 ? "" : "s"}
              {options ? ` of ${options.total} on record` : ""}
            </h2>
            {rows.length === 0
              ? <p className="muted-note">Nothing matches those filters.</p>
              : (
                <div className="table-wrap">
                  <table>
                    <thead>
                      <tr>
                        <th>When</th><th>Actor</th><th>Role</th>
                        <th>Action</th><th>Record</th><th>Changed</th>
                      </tr>
                    </thead>
                    <tbody>
                      {rows.map((row) => (
                        <tr key={row.audit_id} style={{ cursor: "pointer" }}
                            onClick={() => navigate(`/admin/audit/${row.audit_id}`)}>
                          <td className="no-wrap">{formatDateTime(row.created_at)}</td>
                          <td><span className="name">{row.actor_label ?? "TAMS"}</span></td>
                          <td className="no-wrap">{row.actor_role ?? "—"}</td>
                          <td>
                            <span className="name">{readableAction(row.action)}</span>
                            {row.reason ? <div className="status-note">{row.reason}</div> : null}
                          </td>
                          <td className="no-wrap">
                            {readableEntity(row.entity_type)}
                            {row.entity_reference
                              ? <div className="status-note">{row.entity_reference}</div>
                              : null}
                          </td>
                          <td>
                            {(row.changed_fields ?? []).length > 0
                              ? (row.changed_fields ?? []).slice(0, 4).join(", ")
                                + ((row.changed_fields ?? []).length > 4 ? "…" : "")
                              : <span className="muted-note">—</span>}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
          </div>
        )
        : null}
    </AppShell>
  );
}
