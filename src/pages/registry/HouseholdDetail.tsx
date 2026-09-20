import { useCallback, useEffect, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { AppShell } from "../../components/AppShell";
import { Loading, Notice, StatusBadge } from "../../components/ui";
import { ResidentStatusBadge } from "./bits";
import { DesignateHeadDialog } from "./dialogs";
import { formatDate } from "../../lib/format";
import { householdRecord } from "../../registry/api";
import type { HouseholdRecord } from "../../registry/types";

/** A household in full: its site, its head, its members, and context. */
export function HouseholdDetail() {
  const { householdId = "" } = useParams();
  const [record, setRecord] = useState<HouseholdRecord | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [designating, setDesignating] = useState(false);

  const load = useCallback(async () => {
    const result = await householdRecord(householdId);
    if (result.ok) { setRecord(result.data); setError(null); }
    else setError(result.message);
  }, [householdId]);

  useEffect(() => { void load(); }, [load]);

  if (error) return <AppShell><Notice kind="error">{error}</Notice></AppShell>;
  if (!record) return <AppShell><Loading what="Loading the household" /></AppShell>;

  return (
    <AppShell>
      <div className="page-head row-between">
        <div>
          <h1>{record.household_code}</h1>
          <p>{record.site_code} · {record.street_address} · {record.members.length} member(s)</p>
        </div>
        <div className="row">
          <Link to="/registry/households" className="btn btn-ghost">Back to households</Link>
          <button type="button" className="btn btn-primary" onClick={() => setDesignating(true)}>
            Designate head
          </button>
        </div>
      </div>

      {success ? <div style={{ marginBottom: 18 }}><Notice kind="success">{success}</Notice></div> : null}

      <div className="grid-2">
        <div className="card">
          <h2 className="card-title">Household</h2>
          <div className="detail-list">
            <div className="detail-item"><span className="label">Household code</span><span className="value">{record.household_code}</span></div>
            <div className="detail-item">
              <span className="label">Household status</span>
              <span className="value">
                <StatusBadge status={record.household_status === "active" ? "active" : "deactivated"} />
              </span>
            </div>
            <div className="detail-item"><span className="label">Head of household</span>
              <span className="value">{record.head_full_name ?? "Not designated"}</span></div>
            <div className="detail-item"><span className="label">Residential site</span><span className="value">{record.site_code}</span></div>
            <div className="detail-item"><span className="label">Stand number</span><span className="value">{record.stand_number ?? "—"}</span></div>
            <div className="detail-item"><span className="label">Street address</span><span className="value">{record.street_address}</span></div>
            <div className="detail-item"><span className="label">Village section</span><span className="value">{record.village_section ?? "—"}</span></div>
            <div className="detail-item"><span className="label">Village</span><span className="value">{record.village_name ?? "—"}</span></div>
          </div>
        </div>

        <div className="card">
          <h2 className="card-title">Land allocation for this site</h2>
          {record.allocation
            ? (
              <>
                <div className="detail-list">
                  <div className="detail-item"><span className="label">Allocation reference</span>
                    <span className="value">{record.allocation.allocation_reference}</span></div>
                  <div className="detail-item"><span className="label">Allocated to</span>
                    <span className="value">{record.allocation.holder_full_name}</span></div>
                  <div className="detail-item"><span className="label">Allocation date</span>
                    <span className="value">{formatDate(record.allocation.allocation_date)}</span></div>
                </div>
                <div style={{ marginTop: 18 }}>
                  {record.allocation.holder_is_household_head
                    ? (
                      <Notice kind="info">
                        The head of this household is also the person the land is allocated to.
                      </Notice>
                    )
                    : (
                      <Notice kind="info">
                        The land is allocated to <strong>{record.allocation.holder_full_name}</strong>,
                        who is not the head of this household. The two are separate records and
                        often differ.
                      </Notice>
                    )}
                </div>
              </>
            )
            : <Notice kind="info">There is no active land allocation recorded for this site.</Notice>}

          <p className="muted-note" style={{ marginTop: 18 }}>
            Shown for context. Land allocations are the Land Officer's to record and change.
          </p>
        </div>
      </div>

      <div className="card" style={{ marginTop: 22 }}>
        <h2 className="card-title">Members</h2>
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>Name</th>
                <th>ID number</th>
                <th>Date of birth</th>
                <th>Gender</th>
                <th>Resident status</th>
                <th>In this household</th>
              </tr>
            </thead>
            <tbody>
              {record.members.length === 0
                ? (
                  <tr>
                    <td className="empty-row" colSpan={6}>
                      Nobody is linked to this household yet. Link residents from their own record.
                    </td>
                  </tr>
                )
                : record.members.map((member) => (
                  <tr key={member.resident_id}>
                    <td>
                      <Link to={`/registry/residents/${member.resident_id}`} className="name">
                        {member.full_name}
                      </Link>
                    </td>
                    <td className="no-wrap">{member.id_number}</td>
                    <td className="no-wrap">{formatDate(member.date_of_birth)}</td>
                    <td>{member.gender}</td>
                    <td><ResidentStatusBadge status={member.resident_status} /></td>
                    <td>{member.is_head ? <span className="badge badge-active">Head</span> : "Member"}</td>
                  </tr>
                ))}
            </tbody>
          </table>
        </div>
        <p className="muted-note" style={{ marginTop: 16 }}>
          Members may have different surnames, and households with the same surname are still
          different households.
        </p>
      </div>

      {designating
        ? (
          <DesignateHeadDialog
            household={{ household_id: record.household_id, household_code: record.household_code }}
            members={record.members}
            currentHead={record.head_full_name}
            onClose={() => setDesignating(false)}
            onDone={async (message: string) => {
              setDesignating(false);
              setSuccess(message);
              await load();
            }}
          />
        )
        : null}
    </AppShell>
  );
}
