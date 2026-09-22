import { useCallback, useEffect, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { useSession } from "../auth/SessionProvider";
import { AppShell } from "../components/AppShell";
import { PageHead } from "../components/PageHead";
import { homeFor } from "../components/navigation";
import { Loading, Notice } from "../components/ui";
import { formatDateTime } from "../lib/format";
import {
  archiveNotification, markAllRead, markRead, myNotifications,
  NOTIFICATION_LABELS,
} from "../registry/adminApi";
import type { NotificationRow } from "../registry/adminApi";

const SCOPES = [
  { value: "inbox", label: "Inbox" },
  { value: "archived", label: "Archived" },
  { value: "all", label: "Everything" },
] as const;

/**
 * Everybody's notifications, whatever their role. The database hands a
 * caller only their own, so there is nothing here to filter.
 */
export function Notifications() {
  const { session, profile } = useSession();
  const navigate = useNavigate();
  const [scope, setScope] = useState<"inbox" | "archived" | "all">("inbox");
  const [rows, setRows] = useState<NotificationRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    const result = await myNotifications(scope);
    if (result.ok) { setRows(result.data); setError(null); }
    else { setRows([]); setError(result.message); }
  }, [scope]);

  useEffect(() => { void load(); }, [load]);

  const open = async (row: NotificationRow) => {
    if (!row.read_at) await markRead(row.notification_id);
    if (row.link_path) navigate(row.link_path);
    else await load();
  };

  const unread = (rows ?? []).filter((row) => !row.read_at && !row.archived_at).length;
  const home = homeFor(profile, Boolean(session));

  return (
    <AppShell>
      <PageHead
        title="Notifications"
        description="Everything TAMS has told you."
        crumbs={[{ label: "Home", to: home }, { label: "Notifications" }]}
        actions={
          <>
            <Link to={home} className="btn btn-ghost">Back to dashboard</Link>
            <button type="button" className="btn btn-primary" disabled={busy || unread === 0}
                    onClick={async () => {
                      setBusy(true);
                      const result = await markAllRead();
                      setBusy(false);
                      if (!result.ok) { setError(result.message); return; }
                      await load();
                    }}>
              Mark all as read
            </button>
          </>
        }
      />

      {error ? <Notice kind="error">{error}</Notice> : null}

      <div className="card">
        <div className="tabs">
          {SCOPES.map((option) => (
            <button type="button" key={option.value}
                    className={`tab${scope === option.value ? " active" : ""}`}
                    onClick={() => setScope(option.value)}>
              {option.label}
            </button>
          ))}
        </div>

        {rows === null && !error ? <Loading what="Loading notifications" /> : null}

        {rows !== null
          ? rows.length === 0
            ? (
              <p className="muted-note" style={{ marginTop: 18 }}>
                {scope === "archived"
                  ? "You have not archived anything."
                  : "You have no notifications. TAMS will tell you when something happens."}
              </p>
            )
            : (
              <div className="stack" style={{ marginTop: 18 }}>
                {rows.map((row) => (
                  <div className={`notification${row.read_at ? "" : " unread"}`} key={row.notification_id}>
                    <div className="row-between">
                      <div style={{ minWidth: 0 }}>
                        <span className="name">{row.title}</span>
                        <div className="status-note">
                          {NOTIFICATION_LABELS[row.notification_category] ?? row.notification_category}
                          {" · "}{formatDateTime(row.created_at)}
                          {row.source_reference ? ` · ${row.source_reference}` : ""}
                          {row.read_at ? "" : " · unread"}
                        </div>
                      </div>
                      <div className="row-actions">
                        {row.link_path
                          ? (
                            <button type="button" className="btn btn-ghost btn-small"
                                    onClick={() => void open(row)}>
                              Open
                            </button>
                          )
                          : !row.read_at
                          ? (
                            <button type="button" className="btn btn-ghost btn-small"
                                    onClick={async () => {
                                      await markRead(row.notification_id);
                                      await load();
                                    }}>
                              Mark read
                            </button>
                          )
                          : null}
                        {!row.archived_at
                          ? (
                            <button type="button" className="btn btn-ghost btn-small"
                                    onClick={async () => {
                                      const result = await archiveNotification(row.notification_id);
                                      if (!result.ok) { setError(result.message); return; }
                                      await load();
                                    }}>
                              Archive
                            </button>
                          )
                          : <span className="muted-note">Archived</span>}
                      </div>
                    </div>
                    <p style={{ marginTop: 8, whiteSpace: "pre-wrap" }}>{row.message}</p>
                  </div>
                ))}
              </div>
            )
          : null}
      </div>
    </AppShell>
  );
}
