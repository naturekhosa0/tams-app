import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { useSession } from "../../auth/SessionProvider";
import { AppShell } from "../../components/AppShell";
import { Loading, Notice } from "../../components/ui";
import { officerDashboard } from "../../registry/landApi";
import type { OfficerDashboard } from "../../registry/landTypes";

/** What the Land Officer has waiting for them. */
export function LandDashboard() {
  const { profile } = useSession();
  const [stats, setStats] = useState<OfficerDashboard | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    officerDashboard().then((result) => {
      if (cancelled) return;
      if (result.ok) setStats(result.data);
      else setError(result.message);
    });
    return () => { cancelled = true; };
  }, []);

  return (
    <AppShell>
      <div className="page-head row-between">
        <div>
          <h1>Welcome, {profile?.first_name}</h1>
          <p>{profile?.role_name} · Employee no. {profile?.employee_number}</p>
        </div>
        <div className="row">
          <Link to="/land/sites" className="btn btn-ghost">Land sites</Link>
          <Link to="/land/applications" className="btn btn-primary">Applications</Link>
        </div>
      </div>

      {error ? <Notice kind="error">{error}</Notice> : null}
      {!stats && !error ? <Loading what="Loading the land register" /> : null}

      {stats
        ? (
          <>
            <div className="grid-4">
              <div className="stat">
                <div className="stat-label">Waiting for review</div>
                <div className="stat-value">{stats.pending_applications}</div>
                <div className="stat-note">Applications nobody has looked at</div>
              </div>
              <div className="stat">
                <div className="stat-label">Approved, not allocated</div>
                <div className="stat-value">{stats.awaiting_allocation}</div>
                <div className="stat-note">Approved and waiting for a site</div>
              </div>
              <div className="stat">
                <div className="stat-label">Available sites</div>
                <div className="stat-value">{stats.available_sites}</div>
                <div className="stat-note">Free to allocate</div>
              </div>
              <div className="stat">
                <div className="stat-label">Active allocations</div>
                <div className="stat-value">{stats.active_allocations}</div>
                <div className="stat-note">Land currently held</div>
              </div>
            </div>

            <div className="grid-4" style={{ marginTop: 18 }}>
              <div className="stat">
                <div className="stat-label">Active permissions</div>
                <div className="stat-value">{stats.active_ptos}</div>
                <div className="stat-note">PTOs that are current today</div>
              </div>
              <div className="stat">
                <div className="stat-label">Lapsed permissions</div>
                <div className="stat-value">{stats.expired_ptos}</div>
                <div className="stat-note">Past their expiry date</div>
              </div>
              <div className="stat">
                <div className="stat-label">Renewal requests</div>
                <div className="stat-value">{stats.pending_renewals}</div>
                <div className="stat-note">Farming and business only</div>
              </div>
              <div className="stat">
                <div className="stat-label">Waiting for succession</div>
                <div className="stat-value">{stats.succession_pending}</div>
                <div className="stat-note">Holder recorded as deceased</div>
              </div>
            </div>

            <div className="grid-2" style={{ marginTop: 22 }}>
              <div className="card">
                <h2 className="card-title">Needs attention</h2>
                <div className="role-row">
                  <span><Link to="/land/applications">Applications waiting for review</Link></span>
                  <span className="count">{stats.pending_applications}</span>
                </div>
                <div className="role-row">
                  <span><Link to="/land/applications?status=approved">Approved, waiting for a site</Link></span>
                  <span className="count">{stats.awaiting_allocation}</span>
                </div>
                <div className="role-row">
                  <span><Link to="/land/renewals">Renewal requests</Link></span>
                  <span className="count">{stats.pending_renewals}</span>
                </div>
                <div className="role-row">
                  <span><Link to="/land/succession">Residential succession</Link></span>
                  <span className="count">{stats.succession_pending}</span>
                </div>
                <div className="role-row">
                  <span>Burial plots still usable</span>
                  <span className="count">{stats.burial_plots_usable}</span>
                </div>
              </div>

              <div className="card">
                <h2 className="card-title">How land works here</h2>
                <div className="bullet-list">
                  <p>
                    Four kinds of land are allocated: residential, farming, business and burial.
                    Grazing land is not allocated and no permission is issued for it.
                  </p>
                  <p>
                    An applicant must be 21 or older, on the village register, and must not already
                    hold that kind of land. The rules are rechecked when you approve and again
                    when you allocate.
                  </p>
                  <p>
                    Residential and burial permissions are perpetual. Farming runs for five years
                    and business for two, and both can be renewed — a renewal issues a new
                    permission and keeps the old one on record.
                  </p>
                  <p style={{ color: "var(--muted)" }}>
                    Nobody countersigns your decision. What you record here is what the Traditional
                    Authority has decided.
                  </p>
                </div>
              </div>
            </div>
          </>
        )
        : null}
    </AppShell>
  );
}
