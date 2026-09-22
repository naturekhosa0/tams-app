import { useEffect, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { AppShell } from "../../components/AppShell";
import { PageHead } from "../../components/PageHead";
import { Loading, Notice } from "../../components/ui";
import { formatDateTime } from "../../lib/format";
import { auditLog } from "../../registry/adminApi";
import type { AuditDetail as Detail } from "../../registry/adminApi";
import { readableAction, readableEntity } from "./AuditTrail";

/** A stored value as a person should read it, never as raw JSON. */
function readableValue(value: unknown): string {
  if (value === null || value === undefined) return "—";
  if (typeof value === "boolean") return value ? "Yes" : "No";
  if (typeof value === "string") {
    if (/^\d{4}-\d{2}-\d{2}T/.test(value)) return formatDateTime(value);
    return value === "" ? "(empty)" : value;
  }
  if (typeof value === "number") return String(value);
  return JSON.stringify(value);
}

function readableField(field: string): string {
  const words = field.replace(/_/g, " ");
  return words.charAt(0).toUpperCase() + words.slice(1);
}

export function AuditDetail() {
  const { auditId = "" } = useParams();
  const [detail, setDetail] = useState<Detail | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [showRaw, setShowRaw] = useState(false);

  useEffect(() => {
    let cancelled = false;
    auditLog(auditId).then((result) => {
      if (cancelled) return;
      if (result.ok) setDetail(result.data);
      else setError(result.message);
    });
    return () => { cancelled = true; };
  }, [auditId]);

  if (error) {
    return (
      <AppShell>
        <PageHead
          title="That audit record is not available"
          crumbs={[
            { label: "Dashboard", to: "/dashboard" },
            { label: "Audit trail", to: "/admin/audit" },
            { label: "Event" },
          ]}
          back={{ to: "/admin/audit", label: "Back to the audit trail" }}
        />
        <div className="card">
          <Notice kind="error">{error}</Notice>
          <div className="row" style={{ marginTop: 18 }}>
            <Link to="/admin/audit" className="btn btn-primary">Back to the audit trail</Link>
            <Link to="/dashboard" className="btn btn-ghost">Go to my dashboard</Link>
          </div>
        </div>
      </AppShell>
    );
  }
  if (!detail) return <AppShell><Loading what="Loading the event" /></AppShell>;

  // Everything that moved, old beside new — the whole point of the page.
  const fields = detail.changed_fields && detail.changed_fields.length > 0
    ? detail.changed_fields
    : Object.keys(detail.new_values ?? detail.old_values ?? {});

  return (
    <AppShell>
      <PageHead
        title={readableAction(detail.action)}
        description={
          <>
            {formatDateTime(detail.created_at)} · {readableEntity(detail.entity_type)}
            {detail.entity_reference ? ` ${detail.entity_reference}` : ""}
          </>
        }
        crumbs={[
          { label: "Dashboard", to: "/dashboard" },
          { label: "Audit trail", to: "/admin/audit" },
          { label: readableAction(detail.action) },
        ]}
        back={{ to: "/admin/audit", label: "Back to the audit trail" }}
      />

      <div className="grid-2">
        <div className="card">
          <h2 className="card-title">The event</h2>
          <div className="detail-list">
            <div className="detail-item">
              <span className="label">When</span>
              <span className="value">{formatDateTime(detail.created_at)}</span>
            </div>
            <div className="detail-item">
              <span className="label">Who</span>
              <span className="value">{detail.actor_label ?? "TAMS"}</span>
            </div>
            <div className="detail-item">
              <span className="label">Role at the time</span>
              <span className="value">{detail.actor_role ?? "—"}</span>
            </div>
            {detail.actor_employee_number
              ? (
                <div className="detail-item">
                  <span className="label">Employee number</span>
                  <span className="value">{detail.actor_employee_number}</span>
                </div>
              )
              : null}
            <div className="detail-item">
              <span className="label">Action</span>
              <span className="value">{readableAction(detail.action)}</span>
            </div>
            <div className="detail-item">
              <span className="label">Record</span>
              <span className="value">
                {readableEntity(detail.entity_type)}
                {detail.entity_reference ? ` · ${detail.entity_reference}` : ""}
              </span>
            </div>
            {detail.reason
              ? (
                <div className="detail-item stacked">
                  <span className="label">Reason given</span>
                  <span className="value">{detail.reason}</span>
                </div>
              )
              : null}
          </div>
        </div>

        <div className="card">
          <h2 className="card-title">Part of the same action</h2>
          {detail.related.length === 0
            ? <p className="muted-note">Nothing else was written alongside this.</p>
            : (
              <div className="stack">
                {detail.related.map((row) => (
                  <div className="lineage-row" key={row.audit_id}>
                    <div>
                      <Link to={`/admin/audit/${row.audit_id}`} className="name">
                        {readableAction(row.action)}
                      </Link>
                      <div className="status-note">
                        {readableEntity(row.entity_type)}
                        {row.entity_reference ? ` · ${row.entity_reference}` : ""}
                      </div>
                    </div>
                  </div>
                ))}
              </div>
            )}
        </div>
      </div>

      <div className="card">
        <h2 className="card-title">What changed</h2>
        {fields.length === 0
          ? <p className="muted-note">This event recorded no field values.</p>
          : (
            <div className="table-wrap">
              <table>
                <thead><tr><th>Field</th><th>Old</th><th>New</th></tr></thead>
                <tbody>
                  {fields.map((field) => (
                    <tr key={field}>
                      <td><span className="name">{readableField(field)}</span></td>
                      <td className="old-value">
                        {detail.old_values
                          ? readableValue(detail.old_values[field])
                          : <span className="muted-note">—</span>}
                      </td>
                      <td className="new-value">
                        {detail.new_values
                          ? readableValue(detail.new_values[field])
                          : <span className="muted-note">—</span>}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}

        <p className="muted-note" style={{ marginTop: 16 }}>
          Passwords, tokens, keys and the contents of uploaded documents are never recorded here,
          whatever the record they came from holds.
        </p>

        <div className="row" style={{ marginTop: 18 }}>
          <Link to="/admin/audit" className="btn btn-ghost">Back to the audit trail</Link>
          <button type="button" className="btn btn-ghost" onClick={() => setShowRaw(!showRaw)}>
            {showRaw ? "Hide the stored form" : "Show the stored form"}
          </button>
        </div>

        {showRaw
          ? (
            <pre className="raw-values">
{JSON.stringify({ old_values: detail.old_values, new_values: detail.new_values }, null, 2)}
            </pre>
          )
          : null}
      </div>
    </AppShell>
  );
}
