import type { ReactNode } from "react";
import { NavLink } from "react-router-dom";
import { useSession } from "../auth/SessionProvider";
import { initialsOf } from "../lib/format";

/** The workspace frame: brand, the navigation for this user's role, sign out. */
export function AppShell({ children }: { children: ReactNode }) {
  const { profile, signOut } = useSession();
  const isAdministrator = profile?.is_council_administrator ?? false;
  const isRegistryClerk = profile?.role_name === "Registry Clerk";
  const isLandOfficer = profile?.role_name === "Land Officer";
  const isCouncilSecretary = profile?.role_name === "Council Secretary";

  return (
    <div className="page">
      <header className="topbar">
        <div className="brand">
          <div className="brand-mark" aria-hidden="true">T</div>
          <div>
            <div className="brand-name">TAMS</div>
            <div className="brand-sub">Traditional Authority</div>
          </div>
        </div>

        <nav className="topnav">
          {isAdministrator
            ? (
              <>
                <NavLink to="/dashboard" className={({ isActive }) => isActive ? "active" : ""}>Dashboard</NavLink>
                <NavLink to="/staff" end className={({ isActive }) => isActive ? "active" : ""}>Staff accounts</NavLink>
                <NavLink to="/staff/new" className={({ isActive }) => isActive ? "active" : ""}>Create staff account</NavLink>
              </>
            )
            : isRegistryClerk
            ? (
              <>
                <NavLink to="/registry" end className={({ isActive }) => isActive ? "active" : ""}>Dashboard</NavLink>
                <NavLink to="/registry/residents" className={({ isActive }) => isActive ? "active" : ""}>Residents</NavLink>
                <NavLink to="/registry/households" className={({ isActive }) => isActive ? "active" : ""}>Households</NavLink>
                <NavLink to="/registry/lineage" className={({ isActive }) => isActive ? "active" : ""}>Family lineage</NavLink>
                <NavLink to="/registry/resident-accounts" className={({ isActive }) => isActive ? "active" : ""}>Resident accounts</NavLink>
                <NavLink to="/home" className={({ isActive }) => isActive ? "active" : ""}>My account</NavLink>
              </>
            )
            : isLandOfficer
            ? (
              <>
                <NavLink to="/land" end className={({ isActive }) => isActive ? "active" : ""}>Dashboard</NavLink>
                <NavLink to="/land/applications" className={({ isActive }) => isActive ? "active" : ""}>Applications</NavLink>
                <NavLink to="/land/sites" className={({ isActive }) => isActive ? "active" : ""}>Land sites</NavLink>
                <NavLink to="/land/allocations" className={({ isActive }) => isActive ? "active" : ""}>Allocations</NavLink>
                <NavLink to="/land/ptos" className={({ isActive }) => isActive ? "active" : ""}>PTOs</NavLink>
                <NavLink to="/land/renewals" className={({ isActive }) => isActive ? "active" : ""}>Renewals</NavLink>
                <NavLink to="/land/succession" className={({ isActive }) => isActive ? "active" : ""}>Succession</NavLink>
                <NavLink to="/home" className={({ isActive }) => isActive ? "active" : ""}>My account</NavLink>
              </>
            )
            : isCouncilSecretary
            ? (
              <>
                <NavLink to="/secretary" end className={({ isActive }) => isActive ? "active" : ""}>Dashboard</NavLink>
                <NavLink to="/secretary/meetings" className={({ isActive }) => isActive ? "active" : ""}>Meetings</NavLink>
                <NavLink to="/secretary/resolutions" className={({ isActive }) => isActive ? "active" : ""}>Resolutions</NavLink>
                <NavLink to="/secretary/projects" className={({ isActive }) => isActive ? "active" : ""}>Projects</NavLink>
                <NavLink to="/home" className={({ isActive }) => isActive ? "active" : ""}>My account</NavLink>
              </>
            )
            : <NavLink to="/home" className={({ isActive }) => isActive ? "active" : ""}>My account</NavLink>}
        </nav>

        <div className="who">
          <div className="avatar" aria-hidden="true">
            {initialsOf(profile?.full_name ?? null, profile?.email ?? "")}
          </div>
          <span className="who-email">{profile?.email}</span>
          <button type="button" className="btn btn-ghost" onClick={() => void signOut()}>
            Sign out
          </button>
        </div>
      </header>

      {children}
    </div>
  );
}
