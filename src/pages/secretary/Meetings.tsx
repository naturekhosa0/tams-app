import { useCallback, useEffect, useState } from "react";
import { Link, useNavigate, useSearchParams } from "react-router-dom";
import { AppShell } from "../../components/AppShell";
import { Field, Loading, Notice } from "../../components/ui";
import { formatDate } from "../../lib/format";
import { meetings, scheduleMeeting } from "../../registry/secretaryApi";
import { MEETING_TYPES, MEETING_TYPE_LABELS } from "../../registry/secretaryTypes";
import type { MeetingRow } from "../../registry/secretaryTypes";
import { PageHead } from "../../components/PageHead";

const STATUSES = [
  { value: "", label: "All" },
  { value: "scheduled", label: "Scheduled" },
  { value: "held", label: "Held" },
  { value: "cancelled", label: "Cancelled" },
];

const WHEN = [
  { value: "", label: "Any date" },
  { value: "upcoming", label: "Upcoming" },
  { value: "past", label: "Past" },
];

const emptyForm = {
  title: "", meeting_type: "ordinary", meeting_date: "",
  start_time: "", venue: "", agenda: "",
};

/** Every council meeting, upcoming and past. */
export function Meetings() {
  const navigate = useNavigate();
  const [params, setParams] = useSearchParams();
  const status = params.get("status") ?? "";
  const type = params.get("type") ?? "";
  const when = params.get("when") ?? "";
  const [search, setSearch] = useState("");
  const [applied, setApplied] = useState("");
  const [rows, setRows] = useState<MeetingRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [scheduling, setScheduling] = useState(false);

  const load = useCallback(async () => {
    const result = await meetings(status, type, when, applied);
    if (result.ok) { setRows(result.data); setError(null); }
    else { setRows([]); setError(result.message); }
  }, [status, type, when, applied]);

  useEffect(() => { void load(); }, [load]);

  const setParam = (key: string, value: string) => {
    const next = new URLSearchParams(params);
    if (value) next.set(key, value);
    else next.delete(key);
    setParams(next, { replace: true });
  };

  return (
    <AppShell>
      <PageHead
        title="Meetings"
        description="Every council meeting, with who attended, the minutes and the resolutions it produced. Nothing here is ever deleted."
        crumbs={[{ label: "Dashboard", to: "/secretary" }, { label: "Meetings" }]}
        actions={
          <>
            <Link to="/secretary" className="btn btn-ghost">Back to dashboard</Link>
            <button type="button" className="btn btn-primary" onClick={() => setScheduling(true)}>
              Schedule a meeting
            </button>
          </>
        }
      />

      {error ? <Notice kind="error">{error}</Notice> : null}
      {success ? <div style={{ marginBottom: 18 }}><Notice kind="success">{success}</Notice></div> : null}

      <div className="card">
        <form className="filters" onSubmit={(event) => { event.preventDefault(); setApplied(search.trim()); }}>
          <Field label="Search" htmlFor="q" hint="Reference, title or venue.">
            <input id="q" value={search} onChange={(event) => setSearch(event.target.value)} />
          </Field>
          <Field label="Status" htmlFor="status">
            <select id="status" value={status} onChange={(event) => setParam("status", event.target.value)}>
              {STATUSES.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
            </select>
          </Field>
          <Field label="Kind" htmlFor="type">
            <select id="type" value={type} onChange={(event) => setParam("type", event.target.value)}>
              <option value="">All</option>
              {MEETING_TYPES.map((t) => (
                <option key={t} value={t}>{MEETING_TYPE_LABELS[t]}</option>
              ))}
            </select>
          </Field>
          <Field label="When" htmlFor="when">
            <select id="when" value={when} onChange={(event) => setParam("when", event.target.value)}>
              {WHEN.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
            </select>
          </Field>
        </form>
      </div>

      {rows === null && !error ? <Loading what="Loading meetings" /> : null}

      {rows !== null
        ? (
          <div className="card">
            <h2 className="card-title">{rows.length} meeting{rows.length === 1 ? "" : "s"}</h2>
            <div className="table-wrap">
              <table>
                <thead>
                  <tr>
                    <th>Reference</th><th>Title</th><th>Kind</th><th>Date</th>
                    <th>Venue</th><th>Status</th><th>Attendance</th><th>Minutes</th><th>Resolutions</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.length === 0
                    ? <tr><td className="empty-row" colSpan={9}>No meetings match.</td></tr>
                    : rows.map((row) => (
                      <tr key={row.meeting_id} style={{ cursor: "pointer" }}
                          onClick={() => navigate(`/secretary/meetings/${row.meeting_id}`)}>
                        <td className="no-wrap">{row.meeting_reference}</td>
                        <td><span className="name">{row.title}</span></td>
                        <td className="no-wrap">{MEETING_TYPE_LABELS[row.meeting_type]}</td>
                        <td className="no-wrap">
                          {formatDate(row.meeting_date)}
                          <div className="status-note">{row.start_time.slice(0, 5)}</div>
                        </td>
                        <td>{row.venue}</td>
                        <td>
                          <span className={`badge ${row.meeting_status === "held" ? "badge-active" : "badge-deactivated"}`}>
                            {row.meeting_status}
                          </span>
                          {row.cancellation_reason
                            ? <div className="status-note">{row.cancellation_reason}</div>
                            : null}
                        </td>
                        <td className="no-wrap">
                          {row.attendee_count === 0
                            ? <span className="muted-note">—</span>
                            : `${row.present_count} of ${row.attendee_count} present`}
                        </td>
                        <td className="no-wrap">
                          {row.minutes_status
                            ? (
                              <span className={`badge ${row.minutes_status === "final" ? "badge-active" : "badge-deactivated"}`}>
                                {row.minutes_status}
                              </span>
                            )
                            : <span className="muted-note">None</span>}
                        </td>
                        <td className="no-wrap">{row.resolution_count}</td>
                      </tr>
                    ))}
                </tbody>
              </table>
            </div>
          </div>
        )
        : null}

      {scheduling
        ? (
          <ScheduleDialog
            onClose={() => setScheduling(false)}
            onDone={async (message) => {
              setScheduling(false);
              setSuccess(message);
              await load();
            }}
          />
        )
        : null}
    </AppShell>
  );
}

function ScheduleDialog({
  onClose, onDone,
}: { onClose: () => void; onDone: (message: string) => void | Promise<void> }) {
  const [form, setForm] = useState(emptyForm);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const update = (key: keyof typeof emptyForm, value: string) =>
    setForm((current) => ({ ...current, [key]: value }));

  const ready = form.title.trim() && form.meeting_date && form.start_time
    && form.venue.trim() && form.agenda.trim();

  return (
    <div className="backdrop" role="dialog" aria-modal="true" aria-label="Schedule a meeting">
      <div className="dialog">
        <h2>Schedule a meeting</h2>
        <p className="dialog-intro">
          Every field below is required. The meeting reference is generated for you.
        </p>

        {error ? <Notice kind="error">{error}</Notice> : null}

        <div style={{ marginTop: 18 }}>
          <Field label="Title (required)" htmlFor="title">
            <input id="title" value={form.title}
                   onChange={(event) => update("title", event.target.value)} />
          </Field>
        </div>
        <div className="form-grid" style={{ marginTop: 16 }}>
          <Field label="Kind of meeting (required)" htmlFor="meeting_type">
            <select id="meeting_type" value={form.meeting_type}
                    onChange={(event) => update("meeting_type", event.target.value)}>
              {MEETING_TYPES.map((t) => (
                <option key={t} value={t}>{MEETING_TYPE_LABELS[t]}</option>
              ))}
            </select>
          </Field>
          <Field label="Venue (required)" htmlFor="venue">
            <input id="venue" value={form.venue}
                   onChange={(event) => update("venue", event.target.value)} />
          </Field>
        </div>
        <div className="form-grid" style={{ marginTop: 16 }}>
          <Field label="Date (required)" htmlFor="meeting_date">
            <input id="meeting_date" type="date" value={form.meeting_date}
                   onChange={(event) => update("meeting_date", event.target.value)} />
          </Field>
          <Field label="Starting time (required)" htmlFor="start_time">
            <input id="start_time" type="time" value={form.start_time}
                   onChange={(event) => update("start_time", event.target.value)} />
          </Field>
        </div>
        <div style={{ marginTop: 16 }}>
          <Field label="Agenda (required)" htmlFor="agenda"
                 hint="What the meeting will deal with, in the order it will be taken.">
            <textarea id="agenda" value={form.agenda}
                      onChange={(event) => update("agenda", event.target.value)} />
          </Field>
        </div>

        <div className="dialog-actions">
          <button type="button" className="btn btn-ghost" onClick={onClose}>Cancel</button>
          <button type="button" className="btn btn-primary" disabled={busy || !ready}
                  onClick={async () => {
                    setBusy(true);
                    setError(null);
                    const result = await scheduleMeeting(form);
                    setBusy(false);
                    if (!result.ok) { setError(result.message); return; }
                    await onDone(`Meeting ${result.data.meeting_reference} has been scheduled.`);
                  }}>
            {busy ? "Saving…" : "Schedule the meeting"}
          </button>
        </div>
      </div>
    </div>
  );
}
