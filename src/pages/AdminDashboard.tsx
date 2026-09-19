import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { useSession } from "../auth/SessionProvider";
import { supabase } from "../lib/supabaseClient";
import { AppShell } from "../components/AppShell";
import { Loading, Notice } from "../components/ui";
import type { DashboardStats } from "../lib/types";

export function AdminDashboard() {
  const { profile } = useSession();
  const [stats, setStats] = useState<DashboardStats | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    // The counts come from a function that re-checks, in the database,
    // that the caller really is the active Council Administrator.
    supabase.rpc("admin_dashboard_stats").then(({ data, error: statsError }) => {
      if (cancelled) return;
      if (statsError) setError("The dashboard figures could not be loaded.");
      else setStats(data as DashboardStats);
    });
    return () => { cancelled = true; };
  }, []);

  return (
    <AppShell>
      <div className="page-head row-between">
        <div>
          <h1>Welcome, {profile?.full_name}</h1>
          <p>{profile?.role_name} · Employee no. {profile?.employee_number}</p>
        </div>
        <div className="row">
          <Link to="/staff" className="btn btn-ghost">Staff accounts</Link>
          <Link to="/staff/new" className="btn btn-primary">Create staff account</Link>
        </div>
      </div>

      {error ? <Notice kind="error">{error}</Notice> : null}
      {!stats && !error ? <Loading what="Loading your dashboard" /> : null}

      {stats
        ? (
          <>
            <div className="grid-4">
              <div className="stat">
                <div className="stat-label">Staff records</div>
                <div className="stat-value">{stats.staff_records}</div>
                <div className="stat-note">Everyone ever registered</div>
              </div>
              <div className="stat">
                <div className="stat-label">Active staff</div>
                <div className="stat-value">{stats.active_staff}</div>
                <div className="stat-note">Can sign in and work</div>
              </div>
              <div className="stat">
                <div className="stat-label">Deactivated</div>
                <div className="stat-value">{stats.deactivated}</div>
                <div className="stat-note">Kept for the record</div>
              </div>
              <div className="stat">
                <div className="stat-label">Awaiting sign-in setup</div>
                <div className="stat-value">{stats.awaiting_setup}</div>
                <div className="stat-note">Invitation not completed</div>
              </div>
            </div>

            <div className="grid-2" style={{ marginTop: 22 }}>
              <div className="card">
                <h2 className="card-title">Active staff by role</h2>
                {stats.active_by_role.length === 0
                  ? <p style={{ color: "var(--muted)", fontSize: 14.5 }}>No active staff yet.</p>
                  : stats.active_by_role.map((entry) => (
                    <div className="role-row" key={entry.role_name}>
                      <span>{entry.role_name}</span>
                      <span className="count">{entry.count}</span>
                    </div>
                  ))}
              </div>

              <div className="card">
                <h2 className="card-title">What you can do right now</h2>
                <div className="bullet-list">
                  <p>
                    <Link to="/staff/new">Create a staff account</Link>{" "}
                    and assign exactly one role. The person gets an email invitation and chooses
                    their own password.
                  </p>
                  <p>
                    <Link to="/staff">View all staff accounts</Link>{" "}
                    with their current role, search and filters.
                  </p>
                  <p style={{ color: "var(--muted)" }}>
                    The Council Administrator role itself is managed separately and cannot be given
                    out through normal staff creation.
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
