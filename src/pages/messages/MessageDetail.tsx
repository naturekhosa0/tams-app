import { useCallback, useEffect, useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { useSession } from "../../auth/SessionProvider";
import { AppShell } from "../../components/AppShell";
import { PageHead } from "../../components/PageHead";
import { homeFor } from "../../components/navigation";
import { Loading, Notice } from "../../components/ui";
import { formatDateTime } from "../../lib/format";
import {
  acknowledgeRequest, archiveMessage, markMessageRead, messageDetail, resolveRequest,
} from "../../registry/adminApi";
import type { MessageDetail as Detail } from "../../registry/adminApi";

/**
 * Where a linked record lives, when the reader is allowed to open it.
 * The link is a convenience and nothing more: whether they may see it
 * is decided where that record lives, and always was.
 */
function linkFor(detail: Detail, roleName: string | null | undefined): string | null {
  const id = detail.related_entity_id;
  if (!id) return null;
  switch (detail.related_entity_type) {
    case "resident":
      return roleName === "Registry Clerk" ? `/registry/residents/${id}` : null;
    case "household":
      return roleName === "Registry Clerk" ? `/registry/households/${id}` : null;
    case "resident_account_request":
      return roleName === "Registry Clerk" ? `/registry/resident-accounts/${id}` : null;
    case "land_application":
      return roleName === "Land Officer" ? `/land/applications/${id}` : null;
    case "meeting":
      return roleName === "Council Secretary" ? `/secretary/meetings/${id}` : null;
    case "project":
      return roleName === "Council Secretary" ? `/secretary/projects/${id}` : null;
    default:
      return null;
  }
}

export function MessageDetail() {
  const { messageId = "" } = useParams();
  const { session, profile } = useSession();
  const navigate = useNavigate();
  const [detail, setDetail] = useState<Detail | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    const result = await messageDetail(messageId);
    if (result.ok) { setDetail(result.data); setError(null); }
    else setError(result.message);
  }, [messageId]);

  useEffect(() => { void load(); }, [load]);

  // Opening a message marks the reader's own copy as read.
  useEffect(() => {
    if (detail && detail.am_recipient && !detail.read_at) void markMessageRead(messageId);
  }, [detail, messageId]);

  const home = homeFor(profile, Boolean(session));

  if (error && !detail) {
    return (
      <AppShell>
        <PageHead
          title="That message is not available"
          crumbs={[{ label: "Home", to: home }, { label: "Messages", to: "/messages" }, { label: "Message" }]}
          back={{ to: "/messages", label: "Back to inbox" }}
        />
        <div className="card">
          <Notice kind="error">{error}</Notice>
          <div className="row" style={{ marginTop: 18 }}>
            <Link to="/messages" className="btn btn-primary">Back to inbox</Link>
            <Link to={home} className="btn btn-ghost">Go to my dashboard</Link>
          </div>
        </div>
      </AppShell>
    );
  }
  if (!detail) return <AppShell><Loading what="Loading the message" /></AppShell>;

  const target = linkFor(detail, profile?.role_name);
  const isWorkRequest = detail.message_kind === "action_required";

  return (
    <AppShell>
      <PageHead
        title={detail.subject}
        description={
          <>
            {detail.message_reference} · from {detail.sender_name}
            {detail.sender_role ? ` (${detail.sender_role})` : ""} ·{" "}
            {formatDateTime(detail.created_at)}
          </>
        }
        crumbs={[
          { label: "Home", to: home },
          { label: "Messages", to: "/messages" },
          { label: detail.message_reference },
        ]}
        back={{ to: detail.is_sender ? "/messages?box=sent" : "/messages", label: detail.is_sender ? "Back to sent" : "Back to inbox" }}
      />

      {error ? <Notice kind="error">{error}</Notice> : null}
      {success ? <div style={{ marginBottom: 18 }}><Notice kind="success">{success}</Notice></div> : null}

      {isWorkRequest
        ? (
          <div className="card">
            <h2 className="card-title">Work request</h2>
            <div className="work-status">
              <span className={`badge ${detail.action_status === "resolved" ? "badge-active" : "badge-overdue"}`}>
                {detail.action_status}
              </span>
              <div className="status-note" style={{ marginTop: 8 }}>
                {detail.acknowledged_by
                  ? <>Acknowledged by {detail.acknowledged_by} on {formatDateTime(detail.acknowledged_at)}</>
                  : "Nobody has taken this on yet."}
                {detail.resolved_by
                  ? <><br />Resolved by {detail.resolved_by} on {formatDateTime(detail.resolved_at)}</>
                  : null}
              </div>
            </div>

            {detail.am_recipient
              ? (
                <div className="row" style={{ marginTop: 18 }}>
                  {detail.action_status === "open"
                    ? (
                      <button type="button" className="btn btn-primary" disabled={busy}
                              onClick={async () => {
                                setBusy(true);
                                const result = await acknowledgeRequest(messageId);
                                setBusy(false);
                                if (!result.ok) { setError(result.message); return; }
                                setSuccess("You have taken this on.");
                                await load();
                              }}>
                        Acknowledge and take it on
                      </button>
                    )
                    : null}
                  {detail.action_status === "acknowledged" && detail.acknowledged_by_me
                    ? (
                      <button type="button" className="btn btn-primary" disabled={busy}
                              onClick={async () => {
                                setBusy(true);
                                const result = await resolveRequest(messageId);
                                setBusy(false);
                                if (!result.ok) { setError(result.message); return; }
                                setSuccess("Recorded as resolved.");
                                await load();
                              }}>
                        Mark resolved
                      </button>
                    )
                    : null}
                  {detail.action_status === "acknowledged" && !detail.acknowledged_by_me
                    ? (
                      <p className="muted-note">
                        {detail.acknowledged_by} has taken this on. Only they can mark it resolved.
                      </p>
                    )
                    : null}
                </div>
              )
              : null}
          </div>
        )
        : null}

      <div className="card">
        <h2 className="card-title">The message</h2>
        <div className="minutes-body">{detail.body}</div>

        {detail.related_reference
          ? (
            <div style={{ marginTop: 18 }}>
              <div className="section-heading">About</div>
              {target
                ? (
                  <Link to={target} className="btn btn-ghost btn-small">
                    Open {detail.related_reference}
                  </Link>
                )
                : (
                  <Notice kind="info">
                    This message refers to {detail.related_reference}. You do not have permission to
                    open that record — a message never grants access to anything.
                  </Notice>
                )}
            </div>
          )
          : null}

        <div className="row" style={{ marginTop: 22 }}>
          <Link to={detail.is_sender ? "/messages?box=sent" : "/messages"} className="btn btn-ghost">
            {detail.is_sender ? "Back to sent" : "Back to inbox"}
          </Link>
          {detail.am_recipient && !detail.archived_at
            ? (
              <button type="button" className="btn btn-ghost" disabled={busy}
                      onClick={async () => {
                        setBusy(true);
                        const result = await archiveMessage(messageId, true);
                        setBusy(false);
                        if (!result.ok) { setError(result.message); return; }
                        navigate("/messages?box=archived");
                      }}>
                Archive my copy
              </button>
            )
            : null}
          {detail.am_recipient && detail.archived_at
            ? (
              <button type="button" className="btn btn-ghost" disabled={busy}
                      onClick={async () => {
                        setBusy(true);
                        await archiveMessage(messageId, false);
                        setBusy(false);
                        await load();
                      }}>
                Move back to inbox
              </button>
            )
            : null}
          <Link to="/messages/new" className="btn btn-ghost">Write a new message</Link>
        </div>

        <p className="muted-note" style={{ marginTop: 16 }}>
          A sent message is a record: it cannot be edited or deleted. If something needs
          correcting, send a new one.
        </p>
      </div>

      {detail.is_sender || detail.target_type !== "direct"
        ? (
          <div className="card">
            <h2 className="card-title">Recipients ({detail.recipients.length})</h2>
            <div className="table-wrap">
              <table>
                <thead><tr><th>Name</th><th>Role</th><th>Read</th></tr></thead>
                <tbody>
                  {detail.recipients.map((person) => (
                    <tr key={person.name}>
                      <td><span className="name">{person.name}</span></td>
                      <td>{person.role ?? "—"}</td>
                      <td className="no-wrap">
                        {person.read_at
                          ? formatDateTime(person.read_at)
                          : <span className="muted-note">Not yet</span>}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        )
        : null}
    </AppShell>
  );
}
