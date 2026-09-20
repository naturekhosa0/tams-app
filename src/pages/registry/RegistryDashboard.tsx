import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { useSession } from "../../auth/SessionProvider";
import { AppShell } from "../../components/AppShell";
import { Loading, Notice } from "../../components/ui";
import { dashboardStats } from "../../registry/api";
import type { RegistryStats } from "../../registry/types";

export function RegistryDashboard() {
  const { profile } = useSession();
  const [stats, setStats] = useState<RegistryStats | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    dashboardStats().then((result) => {
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
          <Link to="/registry/residents" className="btn btn-ghost">Residents</Link>
          <Link to="/registry/residents/new" className="btn btn-primary">Create resident</Link>
        </div>
      </div>

      {error ? <Notice kind="error">{error}</Notice> : null}
      {!stats && !error ? <Loading what="Loading the register" /> : null}

      {stats
        ? (
          <>
            <div className="grid-4">
              <div className="stat">
                <div className="stat-label">Residents</div>
                <div className="stat-value">{stats.residents}</div>
                <div className="stat-note">On the village register</div>
              </div>
              <div className="stat">
                <div className="stat-label">Active residents</div>
                <div className="stat-value">{stats.active_residents}</div>
                <div className="stat-note">Not inactive or deceased</div>
              </div>
              <div className="stat">
                <div className="stat-label">Households</div>
                <div className="stat-value">{stats.households}</div>
                <div className="stat-note">Each on its own site</div>
              </div>
              <div className="stat">
                <div className="stat-label">Without a household</div>
                <div className="stat-value">{stats.residents_without_household}</div>
                <div className="stat-note">Waiting to be linked</div>
              </div>
            </div>

            <div className="grid-2" style={{ marginTop: 22 }}>
              <div className="card">
                <h2 className="card-title">Needs attention</h2>
                <div className="role-row">
                  <span>Residents not linked to a household</span>
                  <span className="count">{stats.residents_without_household}</span>
                </div>
                <div className="role-row">
                  <span>Households with no head designated</span>
                  <span className="count">{stats.households_without_head}</span>
                </div>
                <div className="role-row">
                  <span>Current family relationships recorded</span>
                  <span className="count">{stats.family_relationships}</span>
                </div>
              </div>

              <div className="card">
                <h2 className="card-title">What you can do</h2>
                <div className="bullet-list">
                  <p>
                    <Link to="/registry/residents">Search the register</Link>{" "}
                    by identity number, name, household code, site code or address.
                  </p>
                  <p>
                    <Link to="/registry/households">View households</Link>{" "}
                    with their site, address, head and members — and create a new one.
                  </p>
                  <p>
                    <Link to="/registry/lineage">Look up family lineage</Link>{" "}
                    for any resident, and record new relationships.
                  </p>
                  <p style={{ color: "var(--muted)" }}>
                    Land sites and land allocations are shown for context but are the
                    Land Officer's to change, not yours.
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
