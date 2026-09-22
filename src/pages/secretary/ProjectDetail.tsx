import { useCallback, useEffect, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { AppShell } from "../../components/AppShell";
import { Field, Loading, Notice } from "../../components/ui";
import { formatDate, formatDateTime } from "../../lib/format";
import {
  addMilestone, project as loadProject, setMilestoneStatus, setProjectStatus,
  setProjectVisibility, updateMilestone,
} from "../../registry/secretaryApi";
import { MILESTONE_LABELS } from "../../registry/secretaryTypes";
import type { MilestoneRecord, ProjectDetail as Detail } from "../../registry/secretaryTypes";
import { ConfirmDialog, ReasonDialog } from "./MeetingDetail";

const MILESTONE_BADGE: Record<string, string> = {
  completed: "badge-active",
  in_progress: "badge-deactivated",
  pending: "badge-deactivated",
  overdue: "badge-overdue",
};

/** One project, with its milestones. */
export function ProjectDetail() {
  const { projectId = "" } = useParams();
  const [detail, setDetail] = useState<Detail | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [dialog, setDialog] = useState<
    | { kind: "milestone"; row?: MilestoneRecord }
    | { kind: "cancel" }
    | { kind: "complete" }
    | { kind: "unpublish" }
    | null
  >(null);

  const load = useCallback(async () => {
    const result = await loadProject(projectId);
    if (result.ok) { setDetail(result.data); setError(null); }
    else setError(result.message);
  }, [projectId]);

  useEffect(() => { void load(); }, [load]);

  const done = async (message: string) => {
    setDialog(null);
    setSuccess(message);
    setError(null);
    await load();
  };

  if (error && !detail) return <AppShell><Notice kind="error">{error}</Notice></AppShell>;
  if (!detail) return <AppShell><Loading what="Loading the project" /></AppShell>;

  const open = detail.project_status === "planned" || detail.project_status === "active";
  const overdue = detail.milestones.filter((m) => m.effective_status === "overdue").length;
  const completed = detail.milestones.filter((m) => m.effective_status === "completed").length;

  return (
    <AppShell>
      <div className="page-head row-between">
        <div>
          <h1>{detail.project_reference}</h1>
          <p>
            {detail.project_name} · starts {formatDate(detail.start_date)}
            {detail.target_completion_date
              ? ` · target ${formatDate(detail.target_completion_date)}`
              : ""}
          </p>
        </div>
        <Link to="/secretary/projects" className="btn btn-ghost">Back to projects</Link>
      </div>

      {error ? <Notice kind="error">{error}</Notice> : null}
      {success ? <div style={{ marginBottom: 18 }}><Notice kind="success">{success}</Notice></div> : null}

      <div className="grid-2">
        <div className="card">
          <div className="row-between">
            <h2 className="card-title" style={{ marginBottom: 0 }}>The project</h2>
            <div className="row-actions">
              <span className={`badge ${detail.visibility === "public" ? "badge-active" : "badge-deactivated"}`}>
                {detail.visibility}
              </span>
              <span className={`badge ${detail.project_status === "active" || detail.project_status === "completed" ? "badge-active" : "badge-deactivated"}`}>
                {detail.project_status}
              </span>
            </div>
          </div>

          <div className="detail-list" style={{ marginTop: 16 }}>
            <div className="detail-item stacked">
              <span className="label">Description</span>
              <span className="value" style={{ whiteSpace: "pre-wrap" }}>{detail.description}</span>
            </div>
            <div className="detail-item">
              <span className="label">Milestones</span>
              <span className="value">
                {completed} of {detail.milestones.length} done
                {overdue > 0 ? ` · ${overdue} overdue` : ""}
              </span>
            </div>
            {detail.completed_on
              ? (
                <div className="detail-item">
                  <span className="label">Completed on</span>
                  <span className="value">{formatDate(detail.completed_on)}</span>
                </div>
              )
              : null}
            {detail.cancellation_reason
              ? (
                <div className="detail-item">
                  <span className="label">Cancelled because</span>
                  <span className="value">{detail.cancellation_reason}</span>
                </div>
              )
              : null}
            <div className="detail-item">
              <span className="label">Recorded by</span>
              <span className="value">
                {detail.created_by ?? "—"} · {formatDateTime(detail.created_at)}
              </span>
            </div>
          </div>

          {open
            ? (
              <div className="row" style={{ marginTop: 20 }}>
                {detail.project_status === "planned"
                  ? (
                    <button type="button" className="btn btn-primary"
                            onClick={() => void setProjectStatus(projectId, "active").then(async (r) => {
                              if (r.ok) await done("The project is now active.");
                              else setError(r.message);
                            })}>
                      Start the project
                    </button>
                  )
                  : (
                    <button type="button" className="btn btn-primary"
                            onClick={() => setDialog({ kind: "complete" })}>
                      Mark completed
                    </button>
                  )}
                {detail.visibility === "internal"
                  ? (
                    <button type="button" className="btn btn-ghost"
                            onClick={() => void setProjectVisibility(projectId, "public").then(async (r) => {
                              if (r.ok) await done("The project is now public.");
                              else setError(r.message);
                            })}>
                      Make public
                    </button>
                  )
                  : (
                    <button type="button" className="btn btn-ghost"
                            onClick={() => setDialog({ kind: "unpublish" })}>
                      Take off the public record
                    </button>
                  )}
                <button type="button" className="btn btn-danger"
                        onClick={() => setDialog({ kind: "cancel" })}>
                  Cancel the project
                </button>
              </div>
            )
            : (
              <p className="muted-note" style={{ marginTop: 18 }}>
                A project that has been {detail.project_status} is part of the record and is kept
                as it is.
              </p>
            )}
        </div>

        <div className="card">
          <h2 className="card-title">Where it came from</h2>
          {detail.resolution
            ? (
              <div className="detail-list">
                <div className="detail-item">
                  <span className="label">Resolution</span>
                  <span className="value">
                    {detail.resolution.resolution_reference} · {detail.resolution.meeting_reference}
                  </span>
                </div>
                <div className="detail-item stacked">
                  <span className="label">Wording</span>
                  <span className="value">{detail.resolution.resolution_text}</span>
                </div>
                <div className="detail-item">
                  <span className="label">Its visibility</span>
                  <span className="value">
                    <span className={`badge ${detail.resolution.visibility === "public" ? "badge-active" : "badge-deactivated"}`}>
                      {detail.resolution.visibility}
                    </span>
                  </span>
                </div>
              </div>
            )
            : (
              <p className="muted-note">
                This project stands on its own — no resolution is linked to it, and that is an
                ordinary thing for a project to do.
              </p>
            )}

          {detail.resolution?.visibility === "internal" && detail.visibility === "public"
            ? (
              <div style={{ marginTop: 16 }}>
                <Notice kind="info">
                  The resolution behind this project is internal. Residents see the project, but
                  nothing at all of that resolution — not its reference, not its wording.
                </Notice>
              </div>
            )
            : null}

          {detail.visibility_history.length > 0
            ? (
              <>
                <div className="section-heading" style={{ marginTop: 22 }}>Publication history</div>
                <div className="stack">
                  {detail.visibility_history.map((change, index) => (
                    <div className="lineage-row" key={`${change.changed_at}-${index}`}>
                      <div>
                        <span className="name">
                          {change.from_visibility} → {change.to_visibility}
                        </span>
                        <div className="status-note">
                          {change.changed_by ?? "—"} · {formatDateTime(change.changed_at)}
                          {change.reason ? ` · ${change.reason}` : ""}
                        </div>
                      </div>
                    </div>
                  ))}
                </div>
              </>
            )
            : null}
        </div>
      </div>

      <div className="card">
        <div className="row-between">
          <h2 className="card-title" style={{ marginBottom: 0 }}>Milestones</h2>
          {open
            ? (
              <button type="button" className="btn btn-ghost btn-small"
                      onClick={() => setDialog({ kind: "milestone" })}>
                Add a milestone
              </button>
            )
            : null}
        </div>

        <p className="muted-note" style={{ marginTop: 12 }}>
          A milestone is pending, in progress or completed. Overdue is not something you set: a
          milestone is overdue the moment its due date passes without it being finished.
        </p>

        {detail.milestones.length === 0
          ? <p className="muted-note" style={{ marginTop: 14 }}>No milestones yet.</p>
          : (
            <div className="table-wrap" style={{ marginTop: 14 }}>
              <table>
                <thead>
                  <tr><th>Milestone</th><th>Due</th><th>Status</th><th>Completed</th><th>Actions</th></tr>
                </thead>
                <tbody>
                  {detail.milestones.map((milestone) => (
                    <tr key={milestone.milestone_id}>
                      <td>
                        <span className="name">{milestone.title}</span>
                        {milestone.description
                          ? <div className="status-note">{milestone.description}</div>
                          : null}
                      </td>
                      <td className="no-wrap">{formatDate(milestone.due_date)}</td>
                      <td>
                        <span className={`badge ${MILESTONE_BADGE[milestone.effective_status] ?? "badge-deactivated"}`}>
                          {MILESTONE_LABELS[milestone.effective_status]}
                        </span>
                      </td>
                      <td className="no-wrap">
                        {milestone.completed_at
                          ? formatDate(milestone.completed_at)
                          : <span className="muted-note">—</span>}
                      </td>
                      <td>
                        <div className="row-actions">
                          {milestone.milestone_status !== "completed" && open
                            ? (
                              <>
                                {milestone.milestone_status === "pending"
                                  ? (
                                    <button type="button" className="btn btn-ghost btn-small"
                                            onClick={() => void setMilestoneStatus(
                                              milestone.milestone_id, "in_progress").then(async (r) => {
                                                if (r.ok) await done(`${milestone.title} is in progress.`);
                                                else setError(r.message);
                                              })}>
                                      Start
                                    </button>
                                  )
                                  : null}
                                <button type="button" className="btn btn-ghost btn-small"
                                        onClick={() => void setMilestoneStatus(
                                          milestone.milestone_id, "completed").then(async (r) => {
                                            if (r.ok) await done(`${milestone.title} is completed.`);
                                            else setError(r.message);
                                          })}>
                                  Mark completed
                                </button>
                                <button type="button" className="btn btn-ghost btn-small"
                                        onClick={() => setDialog({ kind: "milestone", row: milestone })}>
                                  Edit
                                </button>
                              </>
                            )
                            : <span className="muted-note">—</span>}
                        </div>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
      </div>

      {dialog?.kind === "milestone"
        ? (
          <MilestoneDialog
            projectId={projectId}
            row={dialog.row}
            onClose={() => setDialog(null)}
            onDone={done}
          />
        )
        : null}

      {dialog?.kind === "complete"
        ? (
          <ConfirmDialog
            title={`Mark ${detail.project_reference} completed`}
            intro={
              "TAMS never completes a project by itself, however many milestones are finished — " +
              "this is your decision and it is recorded as yours. A completed project cannot be " +
              "reopened."
            }
            confirmLabel="Mark it completed"
            onClose={() => setDialog(null)}
            onConfirm={async () => {
              const result = await setProjectStatus(projectId, "completed");
              if (!result.ok) return result.message;
              await done(`${detail.project_reference} is recorded as completed.`);
              return null;
            }}
          />
        )
        : null}

      {dialog?.kind === "cancel"
        ? (
          <ReasonDialog
            title={`Cancel ${detail.project_reference}`}
            intro="The project is kept on record as cancelled, with your reason. It cannot be restarted."
            label="Why is the project cancelled?"
            confirmLabel="Cancel the project"
            onClose={() => setDialog(null)}
            onConfirm={async (reason) => {
              const result = await setProjectStatus(projectId, "cancelled", reason);
              if (!result.ok) return result.message;
              await done(`${detail.project_reference} has been cancelled.`);
              return null;
            }}
          />
        )
        : null}

      {dialog?.kind === "unpublish"
        ? (
          <ReasonDialog
            title={`Take ${detail.project_reference} off the public record`}
            intro={
              "Residents will no longer see this project or its milestones. It does not disappear: " +
              "the change, your reason and your name are kept in its publication history."
            }
            label="Why is it being taken back?"
            confirmLabel="Make it internal"
            onClose={() => setDialog(null)}
            onConfirm={async (reason) => {
              const result = await setProjectVisibility(projectId, "internal", reason);
              if (!result.ok) return result.message;
              await done(`${detail.project_reference} is internal again.`);
              return null;
            }}
          />
        )
        : null}
    </AppShell>
  );
}

function MilestoneDialog({
  projectId, row, onClose, onDone,
}: {
  projectId: string;
  row?: MilestoneRecord;
  onClose: () => void;
  onDone: (message: string) => Promise<void>;
}) {
  const [title, setTitle] = useState(row?.title ?? "");
  const [dueDate, setDueDate] = useState(row?.due_date ?? "");
  const [description, setDescription] = useState(row?.description ?? "");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  return (
    <div className="backdrop" role="dialog" aria-modal="true"
         aria-label={row ? "Edit a milestone" : "Add a milestone"}>
      <div className="dialog">
        <h2>{row ? "Edit the milestone" : "Add a milestone"}</h2>
        <p className="dialog-intro">
          A new milestone starts as pending. Its due date decides, on its own, whether it ever
          shows as overdue.
        </p>

        {error ? <Notice kind="error">{error}</Notice> : null}

        <div style={{ marginTop: 18 }}>
          <Field label="Title (required)" htmlFor="ms_title">
            <input id="ms_title" value={title} onChange={(event) => setTitle(event.target.value)} />
          </Field>
        </div>
        <div style={{ marginTop: 16 }}>
          <Field label="Due date (required)" htmlFor="ms_due"
                 hint="Never before the project's own start date.">
            <input id="ms_due" type="date" value={dueDate}
                   onChange={(event) => setDueDate(event.target.value)} />
          </Field>
        </div>
        <div style={{ marginTop: 16 }}>
          <Field label="Note" htmlFor="ms_description" hint="Optional.">
            <textarea id="ms_description" value={description}
                      onChange={(event) => setDescription(event.target.value)} />
          </Field>
        </div>

        <div className="dialog-actions">
          <button type="button" className="btn btn-ghost" onClick={onClose}>Cancel</button>
          <button type="button" className="btn btn-primary"
                  disabled={busy || !title.trim() || !dueDate}
                  onClick={async () => {
                    setBusy(true);
                    setError(null);
                    const result = row
                      ? await updateMilestone(row.milestone_id, title, dueDate, description)
                      : await addMilestone(projectId, title, dueDate, description);
                    setBusy(false);
                    if (!result.ok) { setError(result.message); return; }
                    await onDone(row ? "The milestone has been updated." : `${title} has been added.`);
                  }}>
            {busy ? "Saving…" : row ? "Save changes" : "Add the milestone"}
          </button>
        </div>
      </div>
    </div>
  );
}
