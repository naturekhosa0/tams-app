import type { StaffContext } from "../lib/types";

export type NavItem = { to: string; label: string; end?: boolean };

/** Where the TAMS name takes this user: their own home, never somebody else's. */
export function homeFor(profile: StaffContext | null, signedIn: boolean): string {
  if (!signedIn) return "/";
  if (profile?.account_type === "resident") return "/resident";
  if (!profile || !profile.access_granted) return "/no-access";
  if (profile.is_council_administrator) return "/dashboard";
  if (profile.role_name === "Registry Clerk") return "/registry";
  if (profile.role_name === "Land Officer") return "/land";
  if (profile.role_name === "Council Secretary") return "/secretary";
  return "/home";
}

/**
 * The navigation for whoever is signed in. Every item is something they
 * are actually allowed to open: a link is never an invitation to a page
 * that will turn them away.
 */
export function navigationFor(profile: StaffContext | null): NavItem[] {
  if (!profile) return [];

  if (profile.account_type === "resident") {
    return [
      { to: "/resident", label: "Home", end: true },
      { to: "/resident/notifications", label: "Notifications" },
    ];
  }

  if (!profile.access_granted) return [];

  const messages: NavItem[] = [
    { to: "/messages", label: "Messages" },
    { to: "/notifications", label: "Notifications" },
    { to: "/home", label: "My account" },
  ];

  if (profile.is_council_administrator) {
    return [
      { to: "/dashboard", label: "Dashboard", end: true },
      { to: "/staff", label: "Staff accounts", end: true },
      { to: "/staff/new", label: "Create staff account" },
      { to: "/admin/audit", label: "Audit trail" },
      { to: "/admin/transfer", label: "Transfer administrator" },
      ...messages,
    ];
  }

  if (profile.role_name === "Registry Clerk") {
    return [
      { to: "/registry", label: "Dashboard", end: true },
      { to: "/registry/residents", label: "Residents" },
      { to: "/registry/households", label: "Households" },
      { to: "/registry/lineage", label: "Family lineage" },
      { to: "/registry/resident-accounts", label: "Resident requests" },
      ...messages,
    ];
  }

  if (profile.role_name === "Land Officer") {
    return [
      { to: "/land", label: "Dashboard", end: true },
      { to: "/land/applications", label: "Applications" },
      { to: "/land/sites", label: "Land sites" },
      { to: "/land/allocations", label: "Allocations" },
      { to: "/land/ptos", label: "PTOs" },
      { to: "/land/renewals", label: "Renewals" },
      { to: "/land/succession", label: "Succession" },
      ...messages,
    ];
  }

  if (profile.role_name === "Council Secretary") {
    return [
      { to: "/secretary", label: "Dashboard", end: true },
      { to: "/secretary/meetings", label: "Meetings" },
      { to: "/secretary/resolutions", label: "Resolutions" },
      { to: "/secretary/projects", label: "Projects" },
      { to: "/secretary/communications", label: "Communications" },
      ...messages,
    ];
  }

  // An active staff member whose role has no area of its own yet.
  return messages;
}
