import { useEffect, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { AppShell } from "../../components/AppShell";
import { Loading, Notice } from "../../components/ui";
import { formatDate } from "../../lib/format";
import { siteHistory } from "../../registry/landApi";
import { LAND_TYPE_LABELS } from "../../registry/landTypes";
import type { LandType, SiteHistory } from "../../registry/landTypes";

/** Everything that has ever happened to one site. Nothing is deleted. */
export function LandSiteHistory() {
  const { siteId = "" } = useParams();
  const [site, setSite] = useState<SiteHistory | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    siteHistory(siteId).then((result) => {
      if (cancelled) return;
      if (result.ok) setSite(result.data);
      else setError(result.message);
    });
    return () => { cancelled = true; };
  }, [siteId]);

  if (error) return <AppShell><Notice kind="error">{error}</Notice></AppShell>;
  if (!site) return <AppShell><Loading what="Loading the site" /></AppShell>;

  return (
    <AppShell>
      <div className="page-head row-between">
        <div>
          <h1>{site.site_code}</h1>
          <p>
            {LAND_TYPE_LABELS[site.site_type] ?? site.site_type} land · {site.street_address}
            {site.village_section ? ` · ${site.village_section}` : ""}
          </p>
        </div>
        <Link to="/land/sites" className="btn btn-ghost">Back to sites</Link>
      </div>

      <div className="card">
        <h2 className="card-title">The site</h2>
        <div className="detail-list">
          <div className="detail-item">
            <span className="label">Status</span>
            <span className="value">
              <span className={`badge ${site.site_status === "available" ? "badge-active" : "badge-deactivated"}`}>
                {site.site_status}
              </span>
            </span>
          </div>
          {site.burial_status
            ? (
              <div className="detail-item">
                <span className="label">Burial plot</span>
                <span className="value">{site.burial_status}</span>
              </div>
            )
            : null}
          <div className="detail-item">
            <span className="label">Stand number</span>
            <span className="value">{site.stand_number ?? "—"}</span>
          </div>
          <div className="detail-item">
            <span className="label">Village</span>
            <span className="value">{site.village_name ?? "—"}</span>
          </div>
        </div>
      </div>

      <div className="card">
        <h2 className="card-title">Allocation history</h2>
        {site.allocations.length === 0
          ? <p className="muted-note">This site has never been allocated.</p>
          : (
            <div className="stack">
              {site.allocations.map((allocation) => (
                <div className="lineage-row" key={allocation.allocation_id}>
                  <div style={{ width: "100%" }}>
                    <div className="row-between">
                      <span className="name">
                        {allocation.allocation_reference} ·{" "}
                        {LAND_TYPE_LABELS[allocation.land_type as LandType] ?? allocation.land_type}
                      </span>
                      <span className={`badge ${allocation.allocation_status === "active" ? "badge-active" : "badge-deactivated"}`}>
                        {allocation.allocation_status.replace("_", " ")}
                      </span>
                    </div>
                    <div className="status-note">
                      Held by {allocation.holder}
                      {allocation.household_code ? ` · ${allocation.household_code}` : ""} ·
                      allocated {formatDate(allocation.allocation_date)}
                      {allocation.ended_at ? ` · ended ${formatDate(allocation.ended_at)}` : ""}
                      {allocation.end_reason ? ` · ${allocation.end_reason}` : ""}
                      {allocation.succeeds ? ` · succeeds ${allocation.succeeds}` : ""}
                      {allocation.application_reference ? ` · from ${allocation.application_reference}` : ""}
                    </div>

                    {allocation.ptos.length > 0
                      ? (
                        <div className="table-wrap" style={{ marginTop: 10 }}>
                          <table>
                            <thead>
                              <tr><th>PTO number</th><th>Issued</th><th>Expires</th><th>Status</th><th>Notes</th></tr>
                            </thead>
                            <tbody>
                              {allocation.ptos.map((pto) => (
                                <tr key={pto.pto_number}>
                                  <td className="no-wrap">{pto.pto_number}</td>
                                  <td className="no-wrap">{formatDate(pto.issue_date)}</td>
                                  <td className="no-wrap">
                                    {pto.expiry_date ? formatDate(pto.expiry_date) : "Perpetual"}
                                  </td>
                                  <td className="no-wrap">
                                    {pto.effective_status}
                                    {pto.effective_status !== pto.stored_status
                                      ? <div className="status-note">recorded as {pto.stored_status}</div>
                                      : null}
                                  </td>
                                  <td>{pto.revocation_reason ?? "—"}</td>
                                </tr>
                              ))}
                            </tbody>
                          </table>
                        </div>
                      )
                      : null}
                  </div>
                </div>
              ))}
            </div>
          )}
      </div>
    </AppShell>
  );
}
