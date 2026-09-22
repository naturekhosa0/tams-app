import { useEffect, useState } from "react";
import type { ReactNode } from "react";
import { Link, NavLink, useLocation } from "react-router-dom";
import { useSession } from "../auth/SessionProvider";
import { initialsOf } from "../lib/format";
import { unreadCount } from "../registry/adminApi";
import { homeFor, navigationFor } from "./navigation";

/** How often the bell re-counts while a window is left open. */
const UNREAD_REFRESH_MS = 60_000;

/**
 * The workspace frame: the TAMS name (which is always the way home),
 * the navigation for this user's role, their unread notifications, and
 * sign out. Nothing in here is ever the only way to leave a page — but
 * it is always there.
 */
export function AppShell({ children }: { children: ReactNode }) {
  const { profile, session, signOut } = useSession();
  const location = useLocation();
  const [menuOpen, setMenuOpen] = useState(false);
  const [unread, setUnread] = useState(0);

  const items = navigationFor(profile);
  const home = homeFor(profile, Boolean(session));

  // The bell is a courtesy, so a failure to count is simply no badge.
  useEffect(() => {
    let cancelled = false;
    const count = async () => {
      const result = await unreadCount();
      if (!cancelled && result.ok) setUnread(Number(result.data ?? 0));
    };
    void count();
    const timer = window.setInterval(count, UNREAD_REFRESH_MS);
    return () => { cancelled = true; window.clearInterval(timer); };
  }, [location.pathname]);

  // Choosing something closes the menu again.
  useEffect(() => { setMenuOpen(false); }, [location.pathname]);

  const notificationsPath = profile?.account_type === "resident"
    ? "/resident/notifications"
    : "/notifications";

  return (
    <div className="page">
      <header className="topbar">
        <Link to={home} className="brand brand-link" aria-label="TAMS home">
          <div className="brand-mark" aria-hidden="true">T</div>
          <div>
            <div className="brand-name">TAMS</div>
            <div className="brand-sub">Traditional Authority</div>
          </div>
        </Link>

        <button
          type="button"
          className="menu-toggle"
          aria-expanded={menuOpen}
          aria-controls="main-navigation"
          onClick={() => setMenuOpen((open) => !open)}
        >
          {menuOpen ? "Close menu" : "Menu"}
        </button>

        <nav id="main-navigation" className={`topnav${menuOpen ? " open" : ""}`} aria-label="Main">
          {items.map((item) => (
            <NavLink key={item.to} to={item.to} end={item.end}
                     className={({ isActive }) => isActive ? "active" : ""}>
              {item.label}
              {item.label === "Notifications" && unread > 0
                ? <span className="nav-count" aria-hidden="true">{unread}</span>
                : null}
            </NavLink>
          ))}
        </nav>

        <div className={`who${menuOpen ? " open" : ""}`}>
          <Link to={notificationsPath} className="bell"
                aria-label={unread > 0 ? `Notifications, ${unread} unread` : "Notifications"}>
            <span aria-hidden="true">🔔</span>
            {unread > 0 ? <span className="bell-count">{unread > 99 ? "99+" : unread}</span> : null}
          </Link>
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
