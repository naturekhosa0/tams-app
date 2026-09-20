import { useCallback, useEffect, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { AppShell } from "../../components/AppShell";
import { Loading, Notice } from "../../components/ui";
import { ResidentStatusBadge } from "./bits";
import { LineageList } from "./LineageList";
import { LinkHouseholdDialog } from "./dialogs";
import { formatDate } from "../../lib/format";
import { familyLineage, residentRecord } from "../../registry/api";
import type { LineageRow, ResidentRecord } from "../../registry/types";

/** One resident in full: who they are, where they live, who they are related to. */
export function ResidentDetail() {
  const { residentId = "" } = useParams();
  const [record, setRecord] = useState<ResidentRecord | null>(null);
  const [lineage, setLineage] = useState<LineageRow[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [linking, setLinking] = useState(false);

  const load = useCallback(async () => {
    const [detail, relationships] = await Promise.all([
      residentRecord(residentId),
      familyLineage(residentId),
    ]);
    if (!detail.ok) { setError(detail.message); return; }
    setRecord(detail.data);
    setError(null);
    if (relationships.ok) setLineage(relationships.data);
  }, [residentId]);

  useEffect(() => { void load(); }, [load]);

  if (error) return <AppShell><Notice kind="error">{error}</Notice></AppShell>;
  if (!record) return <AppShell><Loading what="Loading the resident record" /></AppShell>;

  return (
    <AppShell>
      <div className="page-head row-between">
        <div>
          <h1>{record.full_name}</h1>
          <p>
            {record.id_number} · {record.household_code ?? "No household"}
            {record.is_household_head ? " · Head of household" : ""}
          </p>
        </div>
        <div className="row">
          <Link to="/registry/residents" className="btn btn-ghost">Back to residents</Link>
          <Link to={`/registry/residents/${record.resident_id}/edit`} className="btn btn-primary">
            Update resident
          </Link>
        </div>
      </div>

      {success ? <div style={{ marginBottom: 18 }}><Notice kind="success">{success}</Notice></div> : null}

      <div className="grid-2">
        <div className="card">
          <h2 className="card-title">Resident record</h2>
          <div className="detail-list">
            <div className="detail-item"><span className="label">ID number</span><span className="value">{record.id_number}</span></div>
            <div className="detail-item"><span className="label">First name</span><span className="value">{record.first_name}</span></div>
            <div className="detail-item"><span className="label">Surname</span><span className="value">{record.last_name}</span></div>
            <div className="detail-item"><span className="label">Date of birth</span><span className="value">{formatDate(record.date_of_birth)}</span></div>
            <div className="detail-item"><span className="label">Gender</span><span className="value">{record.gender}</span></div>
            <div className="detail-item"><span className="label">Contact</span><span className="value">{record.contact_number ?? "—"}</span></div>
            <div className="detail-item"><span className="label">Email</span><span className="value">{record.email ?? "—"}</span></div>
            <div className="detail-item">
              <span className="label">Resident status</span>
              <span className="value"><ResidentStatusBadge status={record.resident_status} /></span>
            </div>
          </div>
        </div>

        <div className="card">
          <div className="row-between" style={{ marginBottom: 18 }}>
            <h2 className="card-title" style={{ marginBottom: 0 }}>Household and address</h2>
            <button type="button" className="btn btn-ghost btn-small" onClick={() => setLinking(true)}>
              {record.household_id ? "Move household" : "Link household"}
            </button>
          </div>

          {record.household_id
            ? (
              <div className="detail-list">
                <div className="detail-item">
                  <span className="label">Household</span>
                  <span className="value">
                    <Link to={`/registry/households/${record.household_id}`}>{record.household_code}</Link>
                  </span>
                </div>
                <div className="detail-item"><span className="label">Head of household</span><span className="value">{record.household_head ?? "Not designated"}</span></div>
                <div className="detail-item"><span className="label">Residential site</span><span className="value">{record.site_code}</span></div>
                <div className="detail-item"><span className="label">Stand number</span><span className="value">{record.stand_number ?? "—"}</span></div>
                <div className="detail-item"><span className="label">Street address</span><span className="value">{record.street_address}</span></div>
                <div className="detail-item"><span className="label">Village section</span><span className="value">{record.village_section ?? "—"}</span></div>
                <div className="detail-item"><span className="label">Village</span><span className="value">{record.village_name ?? "—"}</span></div>
              </div>
            )
            : (
              <Notice kind="info">
                This resident is not linked to a household yet.
              </Notice>
            )}
        </div>
      </div>

      <div className="card" style={{ marginTop: 22 }}>
        <div className="row-between" style={{ marginBottom: 18 }}>
          <h2 className="card-title" style={{ marginBottom: 0 }}>Family lineage</h2>
          <Link to={`/registry/lineage/${record.resident_id}`} className="btn btn-ghost btn-small">
            View full lineage
          </Link>
        </div>
        <LineageList residentName={record.full_name} rows={lineage} />
      </div>

      {linking
        ? (
          <LinkHouseholdDialog
            resident={{
              resident_id: record.resident_id,
              full_name: record.full_name,
              household_code: record.household_code,
            }}
            onClose={() => setLinking(false)}
            onDone={async (message: string) => {
              setLinking(false);
              setSuccess(message);
              await load();
            }}
          />
        )
        : null}
    </AppShell>
  );
}
