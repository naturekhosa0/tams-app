import { useCallback, useEffect, useState } from "react";
import { Link, useNavigate, useSearchParams } from "react-router-dom";
import { useSession } from "../../auth/SessionProvider";
import { AppShell } from "../../components/AppShell";
import { PageHead } from "../../components/PageHead";
import { homeFor } from "../../components/navigation";
import { Loading, Notice } from "../../components/ui";
import { formatDateTime } from "../../lib/format";
import { messageList } from "../../registry/adminApi";
import type { MessageRow } from "../../registry/adminApi";

const BOXES = [
  { value: "inbox", label: "Inbox" },
  { value: "sent", label: "Sent" },
  { value: "archived", label: "Archived" },
] as const;

const KIND_LABELS: Record<string, string> = {
  normal: "Message",
  action_required: "Action required",
  announcement: "Announcement",
};

/** Internal messages between the roles. Not a chat: a record. */
export function Messages() {
  const { session, profile } = useSession();
  const navigate = useNavigate();
  const [params, setParams] = useSearchParams();
  const box = (params.get("box") ?? "inbox") as "inbox" | "sent" | "archived";
  const [rows, setRows] = useState<MessageRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    const result = await messageList(box);
    if (result.ok) { setRows(result.data); setError(null); }
    else { setRows([]); setError(result.message); }
  }, [box]);

  useEffect(() => { void load(); }, [load]);

  const home = homeFor(profile, Boolean(session));

  return (
    <AppShell>
      <PageHead
        title="Messages"
        description="Internal messages and work requests between staff."
        crumbs={[{ label: "Home", to: home }, { label: "Messages" }]}
        actions={
          <>
            <Link to={home} className="btn btn-ghost">Back to dashboard</Link>
            <Link to="/messages/new" className="btn btn-primary">Compose</Link>
          </>
        }
      />

      {error ? <Notice kind="error">{error}</Notice> : null}

      <div className="card">
        <div className="tabs">
          {BOXES.map((option) => (
            <button type="button" key={option.value}
                    className={`tab${box === option.value ? " active" : ""}`}
                    onClick={() => setParams({ box: option.value }, { replace: true })}>
              {option.label}
            </button>
          ))}
        </div>

        {rows === null && !error ? <Loading what="Loading messages" /> : null}

        {rows !== null
          ? rows.length === 0
            ? <p className="muted-note" style={{ marginTop: 18 }}>Nothing in this box.</p>
            : (
              <div className="table-wrap" style={{ marginTop: 18 }}>
                <table>
                  <thead>
                    <tr>
                      <th>{box === "sent" ? "To" : "From"}</th>
                      <th>Subject</th><th>Kind</th><th>About</th>
                      <th>Status</th><th>Sent</th>
                    </tr>
                  </thead>
                  <tbody>
                    {rows.map((row) => (
                      <tr key={row.message_id}
                          className={box !== "sent" && !row.read_at ? "unread-row" : ""}
                          style={{ cursor: "pointer" }}
                          onClick={() => navigate(`/messages/${row.message_id}`)}>
                        <td>
                          {box === "sent"
                            ? (
                              <>
                                <span className="name">
                                  {row.target_type === "all_staff"
                                    ? "All staff"
                                    : `${row.recipient_count} recipient${row.recipient_count === 1 ? "" : "s"}`}
                                </span>
                                <div className="status-note">{row.message_reference}</div>
                              </>
                            )
                            : (
                              <>
                                <span className="name">{row.sender_name}</span>
                                <div className="status-note">{row.sender_role}</div>
                              </>
                            )}
                        </td>
                        <td><span className="name">{row.subject}</span></td>
                        <td className="no-wrap">
                          <span className={`badge ${row.message_kind === "action_required" ? "badge-overdue" : "badge-deactivated"}`}>
                            {KIND_LABELS[row.message_kind] ?? row.message_kind}
                          </span>
                        </td>
                        <td className="no-wrap">
                          {row.related_reference ?? <span className="muted-note">—</span>}
                        </td>
                        <td className="no-wrap">
                          {row.action_status
                            ? (
                              <>
                                <span className={`badge ${row.action_status === "resolved" ? "badge-active" : "badge-deactivated"}`}>
                                  {row.action_status}
                                </span>
                                {row.acknowledged_by
                                  ? <div className="status-note">{row.acknowledged_by}</div>
                                  : null}
                              </>
                            )
                            : box !== "sent" && !row.read_at
                            ? <span className="badge badge-deactivated">unread</span>
                            : <span className="muted-note">—</span>}
                        </td>
                        <td className="no-wrap">{formatDateTime(row.created_at)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )
          : null}
      </div>
    </AppShell>
  );
}
