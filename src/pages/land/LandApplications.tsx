import { useCallback, useEffect, useState } from "react";
import { Link, useNavigate, useSearchParams } from "react-router-dom";
import { AppShell } from "../../components/AppShell";
import { Field, Loading, Notice } from "../../components/ui";
import { formatDate } from "../../lib/format";
import { officerApplications } from "../../registry/landApi";
import { LAND_TYPES, LAND_TYPE_LABELS } from "../../registry/landTypes";
import type { OfficerApplicationRow } from "../../registry/landTypes";
import { PageHead } from "../../components/PageHead";

const STATUSES = [
  { value: "pending", label: "Waiting for review" },
  { value: "approved", label: "Approved, waiting for a site" },
  { value: "allocated", label: "Allocated" },
  { value: "declined", label: "Declined" },
  { value: "", label: "All" },
];

const BADGE: Record<string, string> = {
  approved: "badge-active", allocated: "badge-active",
  pending: "badge-deactivated", declined: "badge-deactivated",
};

/** The queue: who has asked for land, and where each application stands. */
export function LandApplications() {
  const navigate = useNavigate();
  const [params, setParams] = useSearchParams();
  const status = params.get("status") ?? "pending";
  const landType = params.get("type") ?? "";
  const [search, setSearch] = useState(params.get("q") ?? "");
  const [rows, setRows] = useState<OfficerApplicationRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    const result = await officerApplications(status, landType, params.get("q") ?? "");
    if (result.ok) { setRows(result.data); setError(null); }
    else { setRows([]); setError(result.message); }
  }, [status, landType, params]);

  useEffect(() => { void load(); }, [load]);

  const setParam = (key: string, value: string) => {
    const next = new URLSearchParams(params);
    if (value) next.set(key, value);
    else next.delete(key);
    setParams(next, { replace: true });
  };

  return (
    <AppShell>
      <PageHead
        title="Land applications"
        description="Residents apply for a kind of land, never for a particular site. You decide the application first, and only then choose the site."
        crumbs={[{ label: "Dashboard", to: "/land" }, { label: "Applications" }]}
        actions={<Link to="/land" className="btn btn-ghost">Back to dashboard</Link>}
      />

      <div className="card">
        <form
          className="filters"
          onSubmit={(event) => { event.preventDefault(); setParam("q", search.trim()); }}
        >
          <Field label="Search" htmlFor="q" hint="Reference, name, identity number or household code.">
            <input id="q" value={search} onChange={(event) => setSearch(event.target.value)} />
          </Field>
          <Field label="Status" htmlFor="status">
            <select id="status" value={status} onChange={(event) => setParam("status", event.target.value)}>
              {STATUSES.map((option) => (
                <option key={option.value} value={option.value}>{option.label}</option>
              ))}
            </select>
          </Field>
          <Field label="Land type" htmlFor="type">
            <select id="type" value={landType} onChange={(event) => setParam("type", event.target.value)}>
              <option value="">All</option>
              {LAND_TYPES.map((type) => (
                <option key={type} value={type}>{LAND_TYPE_LABELS[type]}</option>
              ))}
            </select>
          </Field>
        </form>
      </div>

      {error ? <Notice kind="error">{error}</Notice> : null}
      {rows === null && !error ? <Loading what="Loading applications" /> : null}

      {rows !== null
        ? (
          <div className="card">
            <h2 className="card-title">
              {rows.length} application{rows.length === 1 ? "" : "s"}
            </h2>
            <div className="table-wrap">
              <table>
                <thead>
                  <tr>
                    <th>Reference</th><th>Applicant</th><th>Age</th><th>Household</th>
                    <th>Land type</th><th>Submitted</th><th>Status</th><th>Site</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.length === 0
                    ? <tr><td className="empty-row" colSpan={8}>Nothing here.</td></tr>
                    : rows.map((row) => (
                      <tr key={row.application_id} style={{ cursor: "pointer" }}
                          onClick={() => navigate(`/land/applications/${row.application_id}`)}>
                        <td className="no-wrap">{row.application_reference}</td>
                        <td>
                          <span className="name">{row.applicant_name}</span>
                          <div className="status-note">{row.applicant_id_number}</div>
                        </td>
                        <td className="no-wrap">{row.applicant_age}</td>
                        <td className="no-wrap">{row.household_code}</td>
                        <td className="no-wrap">{LAND_TYPE_LABELS[row.land_type] ?? row.land_type}</td>
                        <td className="no-wrap">{formatDate(row.submitted_at)}</td>
                        <td>
                          <span className={`badge ${BADGE[row.application_status] ?? "badge-deactivated"}`}>
                            {row.application_status}
                          </span>
                          {row.decline_reason
                            ? <div className="status-note">{row.decline_reason}</div>
                            : null}
                        </td>
                        <td className="no-wrap">{row.allocated_site_code ?? "—"}</td>
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
