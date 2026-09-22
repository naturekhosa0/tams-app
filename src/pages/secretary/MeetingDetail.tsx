import { useCallback, useEffect, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { AppShell } from "../../components/AppShell";
import { Field, Loading, Notice } from "../../components/ui";
import { formatDate, formatDateTime } from "../../lib/format";
import {
  addAmendment, addAttendee, finalizeMinutes, meeting as loadMeeting, recordResolution,
  saveMinutes, setMeetingStatus, setResolutionStatus, setResolutionVisibility,
  updateAttendee, updateMeeting, updateResolution,
} from "../../registry/secretaryApi";
import {
  ATTENDANCE_STATUSES, MEETING_TYPES, MEETING_TYPE_LABELS,
} from "../../registry/secretaryTypes";
import type { AttendanceRow, MeetingDetail as Detail } from "../../registry/secretaryTypes";

/**
 * One meeting, whole: what it was, who was there, what was minuted,
 * what was corrected afterwards, and what it decided.
 */
export function MeetingDetail() {
  const { meetingId = "" } = useParams();
  const [detail, setDetail] = useState<Detail | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [dialog, setDialog] = useState<
    | { kind: "edit" }
    | { kind: "cancel" }
    | { kind: "attendee"; row?: AttendanceRow }
    | { kind: "finalize" }
    | { kind: "amend"; minutesId: string }
    | { kind: "resolution" }
    | { kind: "editResolution"; resolutionId: string; reference: string; text: string }
    | { kind: "withdraw"; resolutionId: string; reference: string }
    | { kind: "unpublish"; resolutionId: string; reference: string }
    | null
  >(null);

  const load = useCallback(async () => {
    const result = await loadMeeting(meetingId);
    if (result.ok) { setDetail(result.data); setError(null); }
    else setError(result.message);
  }, [meetingId]);

  useEffect(() => { void load(); }, [load]);

  const done = async (message: string) => {
    setDialog(null);
    setSuccess(message);
    setError(null);
    await load();
  };

  if (error && !detail) return <AppShell><Notice kind="error">{error}</Notice></AppShell>;
  if (!detail) return <AppShell><Loading what="Loading the meeting" /></AppShell>;

  const scheduled = detail.meeting_status === "scheduled";
  const held = detail.meeting_status === "held";
  const minutesFinal = detail.minutes?.minutes_status === "final";

  return (
    <AppShell>
      <div className="page-head row-between">
        <div>
          <h1>{detail.meeting_reference}</h1>
          <p>
            {detail.title} · {MEETING_TYPE_LABELS[detail.meeting_type]} meeting ·{" "}
            {formatDate(detail.meeting_date)} at {detail.start_time.slice(0, 5)} · {detail.venue}
          </p>
        </div>
        <Link to="/secretary/meetings" className="btn btn-ghost">Back to meetings</Link>
      </div>

      {error ? <Notice kind="error">{error}</Notice> : null}
      {success ? <div style={{ marginBottom: 18 }}><Notice kind="success">{success}</Notice></div> : null}

      {/* ---- the meeting itself ---- */}
      <div className="card">
        <div className="row-between">
          <h2 className="card-title" style={{ marginBottom: 0 }}>The meeting</h2>
          <span className={`badge ${held ? "badge-active" : "badge-deactivated"}`}>
            {detail.meeting_status}
          </span>
        </div>

        <div className="detail-list" style={{ marginTop: 16 }}>
          <div className="detail-item stacked">
            <span className="label">Agenda</span>
            <span className="value" style={{ whiteSpace: "pre-wrap" }}>{detail.agenda}</span>
          </div>
          <div className="detail-item">
            <span className="label">Recorded by</span>
            <span className="value">
              {detail.created_by ?? "—"} · {formatDateTime(detail.created_at)}
            </span>
          </div>
          {detail.cancellation_reason
            ? (
              <div className="detail-item">
                <span className="label">Cancelled because</span>
                <span className="value">{detail.cancellation_reason}</span>
              </div>
            )
            : null}
        </div>

        {scheduled
          ? (
            <div className="row" style={{ marginTop: 20 }}>
              <button type="button" className="btn btn-primary"
                      onClick={() => void setMeetingStatus(meetingId, "held").then(async (r) => {
                        if (r.ok) await done("The meeting is recorded as held.");
                        else setError(r.message);
                      })}>
                Record as held
              </button>
              <button type="button" className="btn btn-ghost" onClick={() => setDialog({ kind: "edit" })}>
                Edit details
              </button>
              <button type="button" className="btn btn-danger" onClick={() => setDialog({ kind: "cancel" })}>
                Cancel the meeting
              </button>
            </div>
          )
          : (
            <p className="muted-note" style={{ marginTop: 18 }}>
              A meeting that has been {detail.meeting_status} is part of the official record, and
              its details can no longer be changed.
            </p>
          )}
      </div>

      {/* ---- attendance ---- */}
      <div className="card">
        <div className="row-between">
          <h2 className="card-title" style={{ marginBottom: 0 }}>Attendance</h2>
          {!minutesFinal && detail.meeting_status !== "cancelled"
            ? (
              <button type="button" className="btn btn-ghost btn-small"
                      onClick={() => setDialog({ kind: "attendee" })}>
                Add an attendee
              </button>
            )
            : null}
        </div>

        <p className="muted-note" style={{ marginTop: 12 }}>
          Anybody may be recorded here — the Chief, a Headman or Headwoman, a council member or an
          invited guest. None of them needs a TAMS account. Residents never see this list.
        </p>

        {detail.attendance.length === 0
          ? <p className="muted-note" style={{ marginTop: 14 }}>Nobody has been recorded yet.</p>
          : (
            <div className="table-wrap" style={{ marginTop: 14 }}>
              <table>
                <thead>
                  <tr><th>Name</th><th>Capacity</th><th>Attendance</th><th></th></tr>
                </thead>
                <tbody>
                  {detail.attendance.map((row) => (
                    <tr key={row.attendance_id}>
                      <td><span className="name">{row.attendee_name}</span></td>
                      <td>{row.role_or_capacity}</td>
                      <td>
                        <span className={`badge ${row.attendance_status === "present" ? "badge-active" : "badge-deactivated"}`}>
                          {row.attendance_status}
                        </span>
                      </td>
                      <td>
                        {!minutesFinal
                          ? (
                            <button type="button" className="btn btn-ghost btn-small"
                                    onClick={() => setDialog({ kind: "attendee", row })}>
                              Correct
                            </button>
                          )
                          : <span className="muted-note">Closed</span>}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}

        {minutesFinal
          ? (
            <p className="muted-note" style={{ marginTop: 14 }}>
              The minutes are final, so the attendance list is closed. It is kept exactly as it is.
            </p>
          )
          : null}
      </div>

      {/* ---- minutes ---- */}
      <MinutesSection
        detail={detail}
        onError={setError}
        onDone={done}
        onFinalize={() => setDialog({ kind: "finalize" })}
        onAmend={(minutesId) => setDialog({ kind: "amend", minutesId })}
      />

      {/* ---- resolutions ---- */}
      <div className="card">
        <div className="row-between">
          <h2 className="card-title" style={{ marginBottom: 0 }}>Resolutions</h2>
          {detail.meeting_status !== "cancelled"
            ? (
              <button type="button" className="btn btn-ghost btn-small"
                      onClick={() => setDialog({ kind: "resolution" })}>
                Record a resolution
              </button>
            )
            : null}
        </div>

        <p className="muted-note" style={{ marginTop: 12 }}>
          A public resolution reaches residents only once these minutes are final. Until then it
          stays inside the council, whatever its visibility says.
        </p>

        {detail.resolutions.length === 0
          ? <p className="muted-note" style={{ marginTop: 14 }}>This meeting has decided nothing yet.</p>
          : (
            <div className="stack" style={{ marginTop: 14 }}>
              {detail.resolutions.map((resolution) => (
                <div className="lineage-row" key={resolution.resolution_id}>
                  <div style={{ width: "100%" }}>
                    <div className="row-between">
                      <span className="name">{resolution.resolution_reference}</span>
                      <div className="row-actions">
                        <span className={`badge ${resolution.visibility === "public" ? "badge-active" : "badge-deactivated"}`}>
                          {resolution.visibility}
                        </span>
                        <span className={`badge ${resolution.resolution_status === "implemented" ? "badge-active" : "badge-deactivated"}`}>
                          {resolution.resolution_status}
                        </span>
                      </div>
                    </div>
                    <p style={{ marginTop: 6, whiteSpace: "pre-wrap" }}>{resolution.resolution_text}</p>
                    <div className="status-note" style={{ marginTop: 6 }}>
                      Decided {formatDate(resolution.decision_date)}
                      {resolution.visibility === "public" && !minutesFinal
                        ? " · not yet shown to residents: these minutes are still a draft"
                        : ""}
                      {resolution.withdrawal_reason ? ` · ${resolution.withdrawal_reason}` : ""}
                    </div>

                    <div className="row-actions" style={{ marginTop: 10 }}>
                      {resolution.resolution_status === "active" && !minutesFinal
                        ? (
                          <button type="button" className="btn btn-ghost btn-small"
                                  onClick={() => setDialog({
                                    kind: "editResolution",
                                    resolutionId: resolution.resolution_id,
                                    reference: resolution.resolution_reference,
                                    text: resolution.resolution_text,
                                  })}>
                            Edit wording
                          </button>
                        )
                        : null}
                      {resolution.resolution_status === "active"
                        ? (
                          <>
                            <button type="button" className="btn btn-ghost btn-small"
                                    onClick={() => void setResolutionStatus(
                                      resolution.resolution_id, "implemented").then(async (r) => {
                                        if (r.ok) await done(`${resolution.resolution_reference} is recorded as implemented.`);
                                        else setError(r.message);
                                      })}>
                              Mark implemented
                            </button>
                            <button type="button" className="btn btn-danger btn-small"
                                    onClick={() => setDialog({
                                      kind: "withdraw",
                                      resolutionId: resolution.resolution_id,
                                      reference: resolution.resolution_reference,
                                    })}>
                              Withdraw
                            </button>
                          </>
                        )
                        : null}
                      {resolution.visibility === "internal"
                        ? (
                          <button type="button" className="btn btn-ghost btn-small"
                                  onClick={() => void setResolutionVisibility(
                                    resolution.resolution_id, "public").then(async (r) => {
                                      if (r.ok) await done(`${resolution.resolution_reference} is now public.`);
                                      else setError(r.message);
                                    })}>
                            Make public
                          </button>
                        )
                        : (
                          <button type="button" className="btn btn-danger btn-small"
                                  onClick={() => setDialog({
                                    kind: "unpublish",
                                    resolutionId: resolution.resolution_id,
                                    reference: resolution.resolution_reference,
                                  })}>
                            Take back off the public record
                          </button>
                        )}
                    </div>
                  </div>
                </div>
              ))}
            </div>
          )}
      </div>

      {/* ---- dialogs ---- */}
      {dialog?.kind === "edit"
        ? <EditMeetingDialog detail={detail} onClose={() => setDialog(null)} onDone={done} />
        : null}

      {dialog?.kind === "cancel"
        ? (
          <ReasonDialog
            title={`Cancel ${detail.meeting_reference}`}
            intro="The meeting stays on record as cancelled, with the reason you give here. It cannot be uncancelled."
            label="Why is the meeting cancelled?"
            confirmLabel="Cancel the meeting"
            onClose={() => setDialog(null)}
            onConfirm={async (reason) => {
              const result = await setMeetingStatus(meetingId, "cancelled", reason);
              if (!result.ok) return result.message;
              await done(`${detail.meeting_reference} has been cancelled.`);
              return null;
            }}
          />
        )
        : null}

      {dialog?.kind === "attendee"
        ? (
          <AttendeeDialog
            meetingId={meetingId}
            row={dialog.row}
            onClose={() => setDialog(null)}
            onDone={done}
          />
        )
        : null}

      {dialog?.kind === "finalize"
        ? (
          <ConfirmDialog
            title="Finalise these minutes"
            intro={
              "Finalising records that the council has confirmed these minutes. They are then locked: " +
              "they cannot be edited again, and any correction has to be recorded as an amendment shown " +
              "beside them. The attendance list closes at the same moment."
            }
            confirmLabel="Finalise the minutes"
            onClose={() => setDialog(null)}
            onConfirm={async () => {
              const result = await finalizeMinutes(meetingId);
              if (!result.ok) return result.message;
              await done("The minutes are final.");
              return null;
            }}
          />
        )
        : null}

      {dialog?.kind === "amend"
        ? (
          <AmendDialog
            minutesId={dialog.minutesId}
            onClose={() => setDialog(null)}
            onDone={done}
          />
        )
        : null}

      {dialog?.kind === "resolution"
        ? (
          <ResolutionDialog
            meetingId={meetingId}
            decisionDate={detail.meeting_date}
            onClose={() => setDialog(null)}
            onDone={done}
          />
        )
        : null}

      {dialog?.kind === "editResolution"
        ? (
          <EditResolutionDialog
            resolutionId={dialog.resolutionId}
            reference={dialog.reference}
            initialText={dialog.text}
            onClose={() => setDialog(null)}
            onDone={done}
          />
        )
        : null}

      {dialog?.kind === "withdraw"
        ? (
          <ReasonDialog
            title={`Withdraw ${dialog.reference}`}
            intro="The resolution is kept on record as withdrawn, with your reason. It cannot be made active again."
            label="Why is the resolution withdrawn?"
            confirmLabel="Withdraw the resolution"
            onClose={() => setDialog(null)}
            onConfirm={async (reason) => {
              const result = await setResolutionStatus(dialog.resolutionId, "withdrawn", reason);
              if (!result.ok) return result.message;
              await done(`${dialog.reference} has been withdrawn.`);
              return null;
            }}
          />
        )
        : null}

      {dialog?.kind === "unpublish"
        ? (
          <ReasonDialog
            title={`Take ${dialog.reference} off the public record`}
            intro={
              "Residents will no longer see this resolution. It does not disappear: the change, " +
              "your reason and your name are kept in its publication history."
            }
            label="Why is it being taken back?"
            confirmLabel="Make it internal"
            onClose={() => setDialog(null)}
            onConfirm={async (reason) => {
              const result = await setResolutionVisibility(dialog.resolutionId, "internal", reason);
              if (!result.ok) return result.message;
              await done(`${dialog.reference} is internal again.`);
              return null;
            }}
          />
        )
        : null}
    </AppShell>
  );
}

// ---------------------------------------------------------------------

function MinutesSection({
  detail, onError, onDone, onFinalize, onAmend,
}: {
  detail: Detail;
  onError: (message: string) => void;
  onDone: (message: string) => Promise<void>;
  onFinalize: () => void;
  onAmend: (minutesId: string) => void;
}) {
  const minutes = detail.minutes;
  const isFinal = minutes?.minutes_status === "final";
  const [draft, setDraft] = useState(minutes?.minutes_content ?? "");
  const [busy, setBusy] = useState(false);

  useEffect(() => { setDraft(detail.minutes?.minutes_content ?? ""); }, [detail.minutes]);

  if (detail.meeting_status === "cancelled") {
    return (
      <div className="card">
        <h2 className="card-title">Minutes</h2>
        <p className="muted-note">A cancelled meeting has no minutes.</p>
      </div>
    );
  }

  return (
    <div className="card">
      <div className="row-between">
        <h2 className="card-title" style={{ marginBottom: 0 }}>Minutes</h2>
        {minutes
          ? (
            <span className={`badge ${isFinal ? "badge-active" : "badge-deactivated"}`}>
              {minutes.minutes_status}
            </span>
          )
          : <span className="badge badge-deactivated">none yet</span>}
      </div>

      {isFinal && minutes
        ? (
          <>
            <div style={{ marginTop: 16 }}>
              <Notice kind="success">
                Confirmed by the council and finalised by {minutes.finalized_by ?? "the Secretary"}
                {minutes.finalized_at ? ` on ${formatDateTime(minutes.finalized_at)}` : ""}. These
                minutes are locked.
              </Notice>
            </div>
            <div className="minutes-body">{minutes.minutes_content}</div>

            <div className="row-between" style={{ marginTop: 22 }}>
              <div className="section-heading" style={{ marginBottom: 0, border: 0 }}>
                Amendments ({minutes.amendments.length})
              </div>
              <button type="button" className="btn btn-ghost btn-small"
                      onClick={() => onAmend(minutes.minutes_id)}>
                Record an amendment
              </button>
            </div>

            {minutes.amendments.length === 0
              ? (
                <p className="muted-note" style={{ marginTop: 12 }}>
                  Nothing has been corrected. If an error is found, record an amendment — the
                  minutes above are never rewritten.
                </p>
              )
              : (
                <div className="stack" style={{ marginTop: 12 }}>
                  {minutes.amendments.map((amendment) => (
                    <div className="amendment" key={amendment.amendment_id}>
                      <div className="row-between">
                        <span className="name">{amendment.amendment_reference}</span>
                        <span className="status-note">
                          {amendment.created_by ?? "—"} · {formatDateTime(amendment.created_at)}
                        </span>
                      </div>
                      <p style={{ marginTop: 6, whiteSpace: "pre-wrap" }}>{amendment.amendment_text}</p>
                      <div className="status-note" style={{ marginTop: 6 }}>
                        Reason: {amendment.reason}
                      </div>
                    </div>
                  ))}
                </div>
              )}
          </>
        )
        : (
          <>
            <p className="muted-note" style={{ marginTop: 12 }}>
              Save as often as you like and come back later. Finalise only once the council has
              confirmed the minutes in the ordinary way — TAMS adds no second approver.
            </p>
            <div style={{ marginTop: 16 }}>
              <Field label="Minutes" htmlFor="minutes">
                <textarea id="minutes" value={draft} rows={12}
                          onChange={(event) => setDraft(event.target.value)} />
              </Field>
            </div>
            <div className="row" style={{ marginTop: 18 }}>
              <button type="button" className="btn btn-ghost" disabled={busy}
                      onClick={async () => {
                        setBusy(true);
                        const result = await saveMinutes(detail.meeting_id, draft);
                        setBusy(false);
                        if (!result.ok) { onError(result.message); return; }
                        await onDone("The draft has been saved.");
                      }}>
                {busy ? "Saving…" : "Save draft"}
              </button>
              <button type="button" className="btn btn-primary"
                      disabled={busy || !minutes || !draft.trim() || detail.meeting_status !== "held"}
                      onClick={onFinalize}>
                Finalise minutes
              </button>
            </div>
            {detail.meeting_status !== "held"
              ? (
                <p className="muted-note" style={{ marginTop: 12 }}>
                  Minutes can only be finalised once the meeting is recorded as held.
                </p>
              )
              : null}
          </>
        )}
    </div>
  );
}

function EditMeetingDialog({
  detail, onClose, onDone,
}: { detail: Detail; onClose: () => void; onDone: (message: string) => Promise<void> }) {
  const [form, setForm] = useState({
    title: detail.title,
    meeting_type: detail.meeting_type as string,
    meeting_date: detail.meeting_date,
    start_time: detail.start_time.slice(0, 5),
    venue: detail.venue,
    agenda: detail.agenda,
  });
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const update = (key: keyof typeof form, value: string) =>
    setForm((current) => ({ ...current, [key]: value }));

  return (
    <div className="backdrop" role="dialog" aria-modal="true" aria-label="Edit the meeting">
      <div className="dialog">
        <h2>{detail.meeting_reference}</h2>
        <p className="dialog-intro">
          Only a meeting that is still scheduled can be corrected. Once it is held or cancelled,
          its details are part of the official record.
        </p>

        {error ? <Notice kind="error">{error}</Notice> : null}

        <div style={{ marginTop: 18 }}>
          <Field label="Title (required)" htmlFor="edit_title">
            <input id="edit_title" value={form.title}
                   onChange={(event) => update("title", event.target.value)} />
          </Field>
        </div>
        <div className="form-grid" style={{ marginTop: 16 }}>
          <Field label="Kind of meeting (required)" htmlFor="edit_type">
            <select id="edit_type" value={form.meeting_type}
                    onChange={(event) => update("meeting_type", event.target.value)}>
              {MEETING_TYPES.map((t) => (
                <option key={t} value={t}>{MEETING_TYPE_LABELS[t]}</option>
              ))}
            </select>
          </Field>
          <Field label="Venue (required)" htmlFor="edit_venue">
            <input id="edit_venue" value={form.venue}
                   onChange={(event) => update("venue", event.target.value)} />
          </Field>
        </div>
        <div className="form-grid" style={{ marginTop: 16 }}>
          <Field label="Date (required)" htmlFor="edit_date">
            <input id="edit_date" type="date" value={form.meeting_date}
                   onChange={(event) => update("meeting_date", event.target.value)} />
          </Field>
          <Field label="Starting time (required)" htmlFor="edit_time">
            <input id="edit_time" type="time" value={form.start_time}
                   onChange={(event) => update("start_time", event.target.value)} />
          </Field>
        </div>
        <div style={{ marginTop: 16 }}>
          <Field label="Agenda (required)" htmlFor="edit_agenda">
            <textarea id="edit_agenda" value={form.agenda}
                      onChange={(event) => update("agenda", event.target.value)} />
          </Field>
        </div>

        <div className="dialog-actions">
          <button type="button" className="btn btn-ghost" onClick={onClose}>Cancel</button>
          <button type="button" className="btn btn-primary" disabled={busy}
                  onClick={async () => {
                    setBusy(true);
                    setError(null);
                    const result = await updateMeeting(detail.meeting_id, form);
                    setBusy(false);
                    if (!result.ok) { setError(result.message); return; }
                    await onDone("The meeting has been updated.");
                  }}>
            {busy ? "Saving…" : "Save changes"}
          </button>
        </div>
      </div>
    </div>
  );
}

function AttendeeDialog({
  meetingId, row, onClose, onDone,
}: {
  meetingId: string;
  row?: AttendanceRow;
  onClose: () => void;
  onDone: (message: string) => Promise<void>;
}) {
  const [name, setName] = useState(row?.attendee_name ?? "");
  const [capacity, setCapacity] = useState(row?.role_or_capacity ?? "");
  const [status, setStatus] = useState<string>(row?.attendance_status ?? "present");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  return (
    <div className="backdrop" role="dialog" aria-modal="true"
         aria-label={row ? "Correct an attendance record" : "Add an attendee"}>
      <div className="dialog">
        <h2>{row ? "Correct an attendance record" : "Add an attendee"}</h2>
        <p className="dialog-intro">
          Write the person down as they were at the meeting. They do not need a TAMS account, and
          nothing here signs anybody in.
        </p>

        {error ? <Notice kind="error">{error}</Notice> : null}

        <div style={{ marginTop: 18 }}>
          <Field label="Name (required)" htmlFor="att_name">
            <input id="att_name" value={name} onChange={(event) => setName(event.target.value)} />
          </Field>
        </div>
        <div className="form-grid" style={{ marginTop: 16 }}>
          <Field label="Capacity (required)" htmlFor="att_capacity"
                 hint="For example: Chief, Headman, council member, community representative.">
            <input id="att_capacity" value={capacity}
                   onChange={(event) => setCapacity(event.target.value)} />
          </Field>
          <Field label="Attendance (required)" htmlFor="att_status">
            <select id="att_status" value={status} onChange={(event) => setStatus(event.target.value)}>
              {ATTENDANCE_STATUSES.map((o) => (
                <option key={o.value} value={o.value}>{o.label}</option>
              ))}
            </select>
          </Field>
        </div>

        <div className="dialog-actions">
          <button type="button" className="btn btn-ghost" onClick={onClose}>Cancel</button>
          <button type="button" className="btn btn-primary"
                  disabled={busy || !name.trim() || !capacity.trim()}
                  onClick={async () => {
                    setBusy(true);
                    setError(null);
                    const result = row
                      ? await updateAttendee(row.attendance_id, name, capacity, status)
                      : await addAttendee(meetingId, name, capacity, status);
                    setBusy(false);
                    if (!result.ok) { setError(result.message); return; }
                    await onDone(row ? "The attendance record has been corrected." : `${name} has been recorded.`);
                  }}>
            {busy ? "Saving…" : row ? "Save the correction" : "Add the attendee"}
          </button>
        </div>
      </div>
    </div>
  );
}

function AmendDialog({
  minutesId, onClose, onDone,
}: { minutesId: string; onClose: () => void; onDone: (message: string) => Promise<void> }) {
  const [text, setText] = useState("");
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  return (
    <div className="backdrop" role="dialog" aria-modal="true" aria-label="Record an amendment">
      <div className="dialog">
        <h2>Record an amendment</h2>
        <p className="dialog-intro">
          The final minutes are not reopened and not rewritten. This correction is stored beside
          them and shown with them from now on.
        </p>

        {error ? <Notice kind="error">{error}</Notice> : null}

        <div style={{ marginTop: 18 }}>
          <Field label="The correction (required)" htmlFor="amend_text"
                 hint="Say what the minutes should have recorded.">
            <textarea id="amend_text" value={text} rows={5}
                      onChange={(event) => setText(event.target.value)} />
          </Field>
        </div>
        <div style={{ marginTop: 16 }}>
          <Field label="Reason (required)" htmlFor="amend_reason"
                 hint="Why the correction is needed.">
            <textarea id="amend_reason" value={reason}
                      onChange={(event) => setReason(event.target.value)} />
          </Field>
        </div>

        <div className="dialog-actions">
          <button type="button" className="btn btn-ghost" onClick={onClose}>Cancel</button>
          <button type="button" className="btn btn-primary"
                  disabled={busy || !text.trim() || !reason.trim()}
                  onClick={async () => {
                    setBusy(true);
                    setError(null);
                    const result = await addAmendment(minutesId, text, reason);
                    setBusy(false);
                    if (!result.ok) { setError(result.message); return; }
                    await onDone(`Amendment ${result.data.amendment_reference} has been recorded.`);
                  }}>
            {busy ? "Saving…" : "Record the amendment"}
          </button>
        </div>
      </div>
    </div>
  );
}

function ResolutionDialog({
  meetingId, decisionDate, onClose, onDone,
}: {
  meetingId: string;
  decisionDate: string;
  onClose: () => void;
  onDone: (message: string) => Promise<void>;
}) {
  const [text, setText] = useState("");
  const [visibility, setVisibility] = useState("internal");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  return (
    <div className="backdrop" role="dialog" aria-modal="true" aria-label="Record a resolution">
      <div className="dialog">
        <h2>Record a resolution</h2>
        <p className="dialog-intro">
          The decision date is the meeting's own date, {formatDate(decisionDate)}, and is taken
          from the meeting rather than typed. Recording a resolution creates no project.
        </p>

        {error ? <Notice kind="error">{error}</Notice> : null}

        <div style={{ marginTop: 18 }}>
          <Field label="What was resolved (required)" htmlFor="res_text">
            <textarea id="res_text" value={text} rows={5}
                      onChange={(event) => setText(event.target.value)} />
          </Field>
        </div>
        <div style={{ marginTop: 16 }}>
          <Field label="Visibility (required)" htmlFor="res_visibility"
                 hint="A public resolution reaches residents only once these minutes are final.">
            <select id="res_visibility" value={visibility}
                    onChange={(event) => setVisibility(event.target.value)}>
              <option value="internal">Internal — council record only</option>
              <option value="public">Public — for Community Updates</option>
            </select>
          </Field>
        </div>

        <div className="dialog-actions">
          <button type="button" className="btn btn-ghost" onClick={onClose}>Cancel</button>
          <button type="button" className="btn btn-primary" disabled={busy || !text.trim()}
                  onClick={async () => {
                    setBusy(true);
                    setError(null);
                    const result = await recordResolution(meetingId, text, visibility);
                    setBusy(false);
                    if (!result.ok) { setError(result.message); return; }
                    await onDone(`Resolution ${result.data.resolution_reference} has been recorded.`);
                  }}>
            {busy ? "Saving…" : "Record the resolution"}
          </button>
        </div>
      </div>
    </div>
  );
}

function EditResolutionDialog({
  resolutionId, reference, initialText, onClose, onDone,
}: {
  resolutionId: string;
  reference: string;
  initialText: string;
  onClose: () => void;
  onDone: (message: string) => Promise<void>;
}) {
  const [text, setText] = useState(initialText);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  return (
    <div className="backdrop" role="dialog" aria-modal="true" aria-label={`Edit ${reference}`}>
      <div className="dialog">
        <h2>{reference}</h2>
        <p className="dialog-intro">
          The wording can still be corrected because these minutes are a draft. Once they are
          final, a correction is an amendment to the minutes instead.
        </p>

        {error ? <Notice kind="error">{error}</Notice> : null}

        <div style={{ marginTop: 18 }}>
          <Field label="What was resolved (required)" htmlFor="edit_res_text">
            <textarea id="edit_res_text" value={text} rows={5}
                      onChange={(event) => setText(event.target.value)} />
          </Field>
        </div>

        <div className="dialog-actions">
          <button type="button" className="btn btn-ghost" onClick={onClose}>Cancel</button>
          <button type="button" className="btn btn-primary" disabled={busy || !text.trim()}
                  onClick={async () => {
                    setBusy(true);
                    setError(null);
                    const result = await updateResolution(resolutionId, text);
                    setBusy(false);
                    if (!result.ok) { setError(result.message); return; }
                    await onDone(`${reference} has been reworded.`);
                  }}>
            {busy ? "Saving…" : "Save the wording"}
          </button>
        </div>
      </div>
    </div>
  );
}

/** A confirmation that needs a reason before it will go through. */
export function ReasonDialog({
  title, intro, label, confirmLabel, onClose, onConfirm,
}: {
  title: string;
  intro: string;
  label: string;
  confirmLabel: string;
  onClose: () => void;
  onConfirm: (reason: string) => Promise<string | null>;
}) {
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  return (
    <div className="backdrop" role="dialog" aria-modal="true" aria-label={title}>
      <div className="dialog">
        <h2>{title}</h2>
        <p className="dialog-intro">{intro}</p>

        {error ? <Notice kind="error">{error}</Notice> : null}

        <div style={{ marginTop: 18 }}>
          <Field label={`${label} (required)`} htmlFor="reason">
            <textarea id="reason" value={reason} maxLength={1000}
                      onChange={(event) => setReason(event.target.value)} />
          </Field>
        </div>

        <div className="dialog-actions">
          <button type="button" className="btn btn-ghost" onClick={onClose}>Cancel</button>
          <button type="button" className="btn btn-danger" disabled={busy || !reason.trim()}
                  onClick={async () => {
                    setBusy(true);
                    const message = await onConfirm(reason.trim());
                    setBusy(false);
                    if (message) setError(message);
                  }}>
            {busy ? "Working…" : confirmLabel}
          </button>
        </div>
      </div>
    </div>
  );
}

/** A confirmation with nothing to type — just a deliberate second step. */
export function ConfirmDialog({
  title, intro, confirmLabel, onClose, onConfirm,
}: {
  title: string;
  intro: string;
  confirmLabel: string;
  onClose: () => void;
  onConfirm: () => Promise<string | null>;
}) {
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  return (
    <div className="backdrop" role="dialog" aria-modal="true" aria-label={title}>
      <div className="dialog">
        <h2>{title}</h2>
        <p className="dialog-intro">{intro}</p>
        {error ? <Notice kind="error">{error}</Notice> : null}
        <div className="dialog-actions">
          <button type="button" className="btn btn-ghost" onClick={onClose}>Cancel</button>
          <button type="button" className="btn btn-primary" disabled={busy}
                  onClick={async () => {
                    setBusy(true);
                    const message = await onConfirm();
                    setBusy(false);
                    if (message) setError(message);
                  }}>
            {busy ? "Working…" : confirmLabel}
          </button>
        </div>
      </div>
    </div>
  );
}
