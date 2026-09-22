import { useEffect, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { AppShell } from "../../components/AppShell";
import { Loading, Notice } from "../../components/ui";
import { formatDate } from "../../lib/format";
import { pendingResidentRequests } from "../../registry/api";
import type { PendingRequestRow } from "../../registry/types";
import { PageHead } from "../../components/PageHead";

/** People waiting to be matched to a record on the village register. */
export function ResidentRequests() {
  const navigate = useNavigate();
  const [rows, setRows] = useState<PendingRequestRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    pendingResidentRequests().then((result) => {
      if (cancelled) return;
      if (result.ok) setRows(result.data);
      else setError(result.message);
    });
    return () => { cancelled = true; };
  }, []);

  return (
    <AppShell>
      <PageHead
        title="Resident requests"
        description="Residents who have applied for an online account."
        crumbs={[{ label: "Dashboard", to: "/registry" }, { label: "Resident requests" }]}
        actions={<Link to="/registry" className="btn btn-ghost">Back to dashboard</Link>}
      />

      {error ? <Notice kind="error">{error}</Notice> : null}
      {rows === null && !error ? <Loading what="Loading applications" /> : null}

      {rows !== null
        ? (
          <div className="card">
            <h2 className="card-title">Waiting for review</h2>
            <div className="table-wrap">
              <table>
                <thead>
                  <tr>
                    <th>Applicant</th>
                    <th>ID number</th>
                    <th>Date of birth</th>
                    <th>Email</th>
                    <th>Cellphone</th>
                    <th>Address given</th>
                    <th>Household head claimed</th>
                    <th>Submitted</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.length === 0
                    ? <tr><td className="empty-row" colSpan={8}>Nothing is waiting to be reviewed.</td></tr>
                    : rows.map((row) => (
                      <tr key={row.request_id} style={{ cursor: "pointer" }}
                          onClick={() => navigate(`/registry/resident-accounts/${row.request_id}`)}>
                        <td>
                          <span className="name">{row.full_name}</span>
                          {row.previous_attempts > 0
                            ? (
                              <div className="status-note">
                                {row.previous_attempts} earlier attempt{row.previous_attempts === 1 ? "" : "s"}
                              </div>
                            )
                            : null}
                        </td>
                        <td className="no-wrap">{row.id_number}</td>
                        <td className="no-wrap">{formatDate(row.date_of_birth)}</td>
                        <td>{row.email}</td>
                        <td className="no-wrap">{row.cellphone_number}</td>
                        <td>
                          {row.house_number} {row.street_address}
                        </td>
                        <td>
                          {row.household_head_name}
                          <div className="status-note">{row.relationship_to_household_head}</div>
                        </td>
                        <td className="no-wrap">{formatDate(row.submitted_at)}</td>
                      </tr>
                    ))}
                </tbody>
              </table>
            </div>
          </div>
        )
        : null}
    </AppShell>
  );
}
