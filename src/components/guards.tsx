import type { ReactNode } from "react";
import { Navigate, useLocation } from "react-router-dom";
import { homePathFor, useSession } from "../auth/SessionProvider";
import { Loading } from "./ui";

/**
 * Requires an active staff account. The checks that matter are made in
 * the database (Row Level Security and the edge functions); this only
 * keeps the browser from showing a page it has no data for.
 */
export function RequireStaff({ children }: { children: ReactNode }) {
  const { loading, session, profile } = useSession();
  const location = useLocation();

  if (loading) return <Loading what="Checking your account" />;
  if (!session) return <Navigate to="/auth" replace state={{ from: location.pathname }} />;
  if (!profile || !profile.access_granted) return <Navigate to="/no-access" replace />;
  return <>{children}</>;
}

/** Requires the active Council Administrator. */
export function RequireAdministrator({ children }: { children: ReactNode }) {
  const { loading, session, profile } = useSession();
  const location = useLocation();

  if (loading) return <Loading what="Checking your account" />;
  if (!session) return <Navigate to="/auth" replace state={{ from: location.pathname }} />;
  if (!profile || !profile.access_granted) return <Navigate to="/no-access" replace />;
  if (!profile.is_council_administrator) return <Navigate to={homePathFor(profile)} replace />;
  return <>{children}</>;
}

/** Requires an active Registry Clerk. */
export function RequireRegistryClerk({ children }: { children: ReactNode }) {
  const { loading, session, profile } = useSession();
  const location = useLocation();

  if (loading) return <Loading what="Checking your account" />;
  if (!session) return <Navigate to="/auth" replace state={{ from: location.pathname }} />;
  if (!profile || !profile.access_granted) return <Navigate to="/no-access" replace />;
  if (profile.role_name !== "Registry Clerk") return <Navigate to={homePathFor(profile)} replace />;
  return <>{children}</>;
}

/** Requires an active Land Officer. */
export function RequireLandOfficer({ children }: { children: ReactNode }) {
  const { loading, session, profile } = useSession();
  const location = useLocation();

  if (loading) return <Loading what="Checking your account" />;
  if (!session) return <Navigate to="/auth" replace state={{ from: location.pathname }} />;
  if (!profile || !profile.access_granted) return <Navigate to="/no-access" replace />;
  if (profile.role_name !== "Land Officer") return <Navigate to={homePathFor(profile)} replace />;
  return <>{children}</>;
}

/** Requires an active Council Secretary. */
export function RequireCouncilSecretary({ children }: { children: ReactNode }) {
  const { loading, session, profile } = useSession();
  const location = useLocation();

  if (loading) return <Loading what="Checking your account" />;
  if (!session) return <Navigate to="/auth" replace state={{ from: location.pathname }} />;
  if (!profile || !profile.access_granted) return <Navigate to="/no-access" replace />;
  if (profile.role_name !== "Council Secretary") return <Navigate to={homePathFor(profile)} replace />;
  return <>{children}</>;
}

/** Requires a signed-in resident account, whatever its verification. */
export function RequireResident({ children }: { children: ReactNode }) {
  const { loading, session, profile } = useSession();
  const location = useLocation();

  if (loading) return <Loading what="Checking your account" />;
  if (!session) return <Navigate to="/auth" replace state={{ from: location.pathname }} />;
  // A staff member who wanders in is sent to their own area.
  if (profile && profile.account_type !== "resident") return <Navigate to={homePathFor(profile)} replace />;
  return <>{children}</>;
}

/**
 * Requires nothing more than a signed-in account — staff or resident.
 * Used for the permission-to-occupy document, where the database
 * decides which one the caller may actually see.
 */
export function RequireStaffOrResident({ children }: { children: ReactNode }) {
  const { loading, session } = useSession();
  const location = useLocation();

  if (loading) return <Loading what="Checking your account" />;
  if (!session) return <Navigate to="/auth" replace state={{ from: location.pathname }} />;
  return <>{children}</>;
}
