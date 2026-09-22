import { useCallback, useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { AppShell } from "../../components/AppShell";
import { PageHead } from "../../components/PageHead";
import { Field, Loading, Notice } from "../../components/ui";
import { formatDate, formatDateTime } from "../../lib/format";
import {
  communicationRecipients, COMMUNICATION_TYPES, sentCommunications,
} from "../../registry/adminApi";
import type { CommunicationRecipient, CommunicationRow } from "../../registry/adminApi";

const TYPE_LABELS: Record<string, string> = Object.fromEntries(
  COMMUNICATION_TYPES.map((t) => [t.value, t.label]),
);

const AUDIENCE_LABELS: Record<string, string> = {
  all_active_residents: "All active residents",
  one_resident: "One resident",
  selected_residents: "Selected residents",
};

/** What the Secretary has sent to residents, and who received it. */
export function Communications() {
  const [rows, setRows] = useState<CommunicationRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [type, setType] = useState("");
  const [search, setSearch] = useState("");
  const [applied, setApplied] = useState("");
  const [showing, setShowing] = useState<CommunicationRow | null>(null);

  const load = useCallback(async () => {
    const result = await sentCommunications(type, applied);
    if (result.ok) { setRows(result.data); setError(null); }
    else { setRows([]); setError(result.message); }
  }, [type, applied]);

  useEffect(() => { void load(); }, [load]);

  return (
    <AppShell>
      <PageHead
        title="Communications"
        description="Announcements and official notices sent to residents."
        crumbs={[{ label: "Dashboard", to: "/secretary" }, { label: "Communications" }]}
        actions={
          <>
            <Link to="/secretary" className="btn btn-ghost">Back to dashboard</Link>
            <Link to="/secretary/communications/new" className="btn btn-primary">Send a notice</Link>
          </>
        }
      />

      {error ? <Notice kind="error">{error}</Notice> : null}

      <div className="card">
        <form className="filters" onSubmit={(event) => { event.preventDefault(); setApplied(search.trim()); }}>
          <Field label="Search" htmlFor="q" hint="Reference or subject.">
            <input id="q" value={search} onChange={(event) => setSearch(event.target.value)} />
          </Field>
          <Field label="Kind" htmlFor="type">
            <select id="type" value={type} onChange={(event) => setType(event.target.value)}>
              <option value="">All</option>
              {COMMUNICATION_TYPES.map((option) => (
                <option key={option.value} value={option.value}>{option.label}</option>
              ))}
            </select>
          </Field>
          <div className="form-actions">
            <button type="submit" className="btn btn-ghost">Search</button>
          </div>
        </form>
      </div>

      {rows === null && !error ? <Loading what="Loading sent communications" /> : null}

      {rows !== null
        ? (
          <div className="card">
            <h2 className="card-title">{rows.length} communication{rows.length === 1 ? "" : "s"}</h2>
            {rows.length === 0
              ? <p className="muted-note">Nothing has been sent yet.</p>
              : (
                <div className="table-wrap">
                  <table>
                    <thead>
                      <tr>
                        <th>Reference</th><th>Subject</th><th>Kind</th><th>Audience</th>
                        <th>Recipients</th><th>Sent</th><th></th>
                      </tr>
                    </thead>
                    <tbody>
                      {rows.map((row) => (
                        <tr key={row.communication_id}>
                          <td className="no-wrap">{row.communication_reference}</td>
                          <td>
                            <span className="name">{row.subject}</span>
                            {row.event_date
                              ? (
                                <div className="status-note">
                                  {formatDate(row.event_date)}
                                  {row.event_time ? ` at ${row.event_time.slice(0, 5)}` : ""}
                                  {row.venue ? ` · ${row.venue}` : ""}
                                </div>
                              )
                              : null}
                          </td>
                          <td className="no-wrap">
                            {TYPE_LABELS[row.communication_type] ?? row.communication_type}
                            {row.issued_on_behalf_of
                              ? <div className="status-note">for the {row.issued_on_behalf_of}</div>
                              : null}
                          </td>
                          <td className="no-wrap">{AUDIENCE_LABELS[row.audience_type]}</td>
                          <td className="no-wrap">{row.recipient_count}</td>
                          <td className="no-wrap">{formatDateTime(row.created_at)}</td>
                          <td>
                            {row.audience_type !== "all_active_residents"
                              ? (
                                <button type="button" className="btn btn-ghost btn-small"
                                        onClick={() => setShowing(row)}>
                                  Recipients
                                </button>
                              )
                              : null}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
          </div>
        )
        : null}

      {showing
        ? <RecipientsDialog communication={showing} onClose={() => setShowing(null)} />
        : null}
    </AppShell>
  );
}

function RecipientsDialog({
  communication, onClose,
}: { communication: CommunicationRow; onClose: () => void }) {
  const [rows, setRows] = useState<CommunicationRecipient[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    communicationRecipients(communication.communication_id).then((result) => {
      if (cancelled) return;
      if (result.ok) setRows(result.data);
      else setError(result.message);
    });
    return () => { cancelled = true; };
  }, [communication.communication_id]);

  return (
    <div className="backdrop" role="dialog" aria-modal="true" aria-label="Recipients">
      <div className="dialog">
        <h2>{communication.communication_reference}</h2>
        <p className="dialog-intro">
          Who this was sent to, as they were at the moment it went out.
        </p>

        {error ? <Notice kind="error">{error}</Notice> : null}
        {rows === null && !error ? <Loading what="Loading recipients" /> : null}

        {rows
          ? (
            <div className="table-wrap" style={{ marginTop: 14 }}>
              <table>
                <thead><tr><th>Name</th><th>Identity number</th><th>Household</th><th>Read</th></tr></thead>
                <tbody>
                  {rows.map((row) => (
                    <tr key={row.id_number}>
                      <td><span className="name">{row.full_name}</span></td>
                      <td className="no-wrap">{row.id_number}</td>
                      <td className="no-wrap">{row.household_code ?? "—"}</td>
                      <td className="no-wrap">
                        {row.read_at
                          ? formatDateTime(row.read_at)
                          : <span className="muted-note">Not yet</span>}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )
          : null}

        <p className="muted-note" style={{ marginTop: 14 }}>
          Read means the notice was opened in TAMS. It is not attendance, acceptance or agreement.
        </p>

        <div className="dialog-actions">
          <button type="button" className="btn btn-ghost" onClick={onClose}>Close</button>
        </div>
      </div>
    </div>
  );
}
