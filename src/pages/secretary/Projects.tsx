import { useCallback, useEffect, useState } from "react";
import { Link, useNavigate, useSearchParams } from "react-router-dom";
import { AppShell } from "../../components/AppShell";
import { Field, Loading, Notice } from "../../components/ui";
import { formatDate } from "../../lib/format";
import {
  createProject, projects as loadProjects, resolutions as loadResolutions,
} from "../../registry/secretaryApi";
import type { ProjectRow, ResolutionRow } from "../../registry/secretaryTypes";
import { PageHead } from "../../components/PageHead";

const STATUSES = [
  { value: "", label: "All" },
  { value: "planned", label: "Planned" },
  { value: "active", label: "Active" },
  { value: "completed", label: "Completed" },
  { value: "cancelled", label: "Cancelled" },
];

const VISIBILITIES = [
  { value: "", label: "All" },
  { value: "internal", label: "Internal" },
  { value: "public", label: "Public" },
];

const emptyForm = {
  project_name: "", description: "", start_date: "",
  target_completion_date: "", resolution_id: "", visibility: "internal",
};

/** The community's projects. */
export function Projects() {
  const navigate = useNavigate();
  const [params, setParams] = useSearchParams();
  const status = params.get("status") ?? "";
  const visibility = params.get("visibility") ?? "";
  const [search, setSearch] = useState("");
  const [applied, setApplied] = useState("");
  const [rows, setRows] = useState<ProjectRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [creating, setCreating] = useState(false);

  const load = useCallback(async () => {
    const result = await loadProjects(status, visibility, applied);
    if (result.ok) { setRows(result.data); setError(null); }
    else { setRows([]); setError(result.message); }
  }, [status, visibility, applied]);

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
        title="Projects"
        description="What the community is building. A project may come out of a resolution or stand on its own, and only a public one is shown to residents."
        crumbs={[{ label: "Dashboard", to: "/secretary" }, { label: "Projects" }]}
        actions={
          <>
            <Link to="/secretary" className="btn btn-ghost">Back to dashboard</Link>
            <button type="button" className="btn btn-primary" onClick={() => setCreating(true)}>
              Create a project
            </button>
          </>
        }
      />

      {error ? <Notice kind="error">{error}</Notice> : null}
      {success ? <div style={{ marginBottom: 18 }}><Notice kind="success">{success}</Notice></div> : null}

      <div className="card">
        <form className="filters" onSubmit={(event) => { event.preventDefault(); setApplied(search.trim()); }}>
          <Field label="Search" htmlFor="q" hint="Reference, name or description.">
            <input id="q" value={search} onChange={(event) => setSearch(event.target.value)} />
          </Field>
          <Field label="Status" htmlFor="status">
            <select id="status" value={status} onChange={(event) => setParam("status", event.target.value)}>
              {STATUSES.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
            </select>
          </Field>
          <Field label="Visibility" htmlFor="visibility">
            <select id="visibility" value={visibility}
                    onChange={(event) => setParam("visibility", event.target.value)}>
              {VISIBILITIES.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
            </select>
          </Field>
        </form>
      </div>

      {rows === null && !error ? <Loading what="Loading projects" /> : null}

      {rows !== null
        ? (
          <div className="card">
            <h2 className="card-title">{rows.length} project{rows.length === 1 ? "" : "s"}</h2>
            <div className="table-wrap">
              <table>
                <thead>
                  <tr>
                    <th>Reference</th><th>Project</th><th>Status</th><th>Visibility</th>
                    <th>Starts</th><th>Target</th><th>Resolution</th><th>Milestones</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.length === 0
                    ? <tr><td className="empty-row" colSpan={8}>No projects match.</td></tr>
                    : rows.map((row) => (
                      <tr key={row.project_id} style={{ cursor: "pointer" }}
                          onClick={() => navigate(`/secretary/projects/${row.project_id}`)}>
                        <td className="no-wrap">{row.project_reference}</td>
                        <td>
                          <span className="name">{row.project_name}</span>
                          {row.cancellation_reason
                            ? <div className="status-note">{row.cancellation_reason}</div>
                            : null}
                        </td>
                        <td>
                          <span className={`badge ${row.project_status === "active" || row.project_status === "completed" ? "badge-active" : "badge-deactivated"}`}>
                            {row.project_status}
                          </span>
                        </td>
                        <td>
                          <span className={`badge ${row.visibility === "public" ? "badge-active" : "badge-deactivated"}`}>
                            {row.visibility}
                          </span>
                        </td>
                        <td className="no-wrap">{formatDate(row.start_date)}</td>
                        <td className="no-wrap">
                          {row.target_completion_date
                            ? formatDate(row.target_completion_date)
                            : <span className="muted-note">None set</span>}
                        </td>
                        <td className="no-wrap">
                          {row.resolution_reference
                            ? (
                              <>
                                {row.resolution_reference}
                                {row.resolution_visibility === "internal"
                                  ? <div className="status-note">internal</div>
                                  : null}
                              </>
                            )
                            : <span className="muted-note">—</span>}
                        </td>
                        <td className="no-wrap">
                          {row.milestone_count === 0
                            ? <span className="muted-note">None</span>
                            : (
                              <>
                                {row.completed_milestones} of {row.milestone_count} done
                                {row.overdue_milestones > 0
                                  ? <div className="status-note overdue">
                                      {row.overdue_milestones} overdue
                                    </div>
                                  : null}
                              </>
                            )}
                        </td>
                      </tr>
                    ))}
                </tbody>
              </table>
            </div>
          </div>
        )
        : null}

      {creating
        ? (
          <CreateProjectDialog
            onClose={() => setCreating(false)}
            onDone={async (message) => {
              setCreating(false);
              setSuccess(message);
              await load();
            }}
          />
        )
        : null}
    </AppShell>
  );
}

function CreateProjectDialog({
  onClose, onDone,
}: { onClose: () => void; onDone: (message: string) => void | Promise<void> }) {
  const [form, setForm] = useState(emptyForm);
  const [available, setAvailable] = useState<ResolutionRow[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    let cancelled = false;
    loadResolutions("", "", "").then((result) => {
      if (!cancelled && result.ok) setAvailable(result.data);
    });
    return () => { cancelled = true; };
  }, []);

  const update = (key: keyof typeof emptyForm, value: string) =>
    setForm((current) => ({ ...current, [key]: value }));

  const ready = form.project_name.trim() && form.description.trim() && form.start_date;

  return (
    <div className="backdrop" role="dialog" aria-modal="true" aria-label="Create a project">
      <div className="dialog">
        <h2>Create a project</h2>
        <p className="dialog-intro">
          Linking a resolution is optional — a project may stand entirely on its own.
        </p>

        {error ? <Notice kind="error">{error}</Notice> : null}

        <div style={{ marginTop: 18 }}>
          <Field label="Project name (required)" htmlFor="project_name">
            <input id="project_name" value={form.project_name}
                   onChange={(event) => update("project_name", event.target.value)} />
          </Field>
        </div>
        <div style={{ marginTop: 16 }}>
          <Field label="Description (required)" htmlFor="description">
            <textarea id="description" value={form.description}
                      onChange={(event) => update("description", event.target.value)} />
          </Field>
        </div>
        <div className="form-grid" style={{ marginTop: 16 }}>
          <Field label="Start date (required)" htmlFor="start_date">
            <input id="start_date" type="date" value={form.start_date}
                   onChange={(event) => update("start_date", event.target.value)} />
          </Field>
          <Field label="Target completion date" htmlFor="target_completion_date"
                 hint="Optional, and never before the start date.">
            <input id="target_completion_date" type="date" value={form.target_completion_date}
                   onChange={(event) => update("target_completion_date", event.target.value)} />
          </Field>
        </div>
        <div style={{ marginTop: 16 }}>
          <Field label="Resolution behind it" htmlFor="resolution_id" hint="Optional.">
            <select id="resolution_id" value={form.resolution_id}
                    onChange={(event) => update("resolution_id", event.target.value)}>
              <option value="">None — this project stands on its own</option>
              {available.map((r) => (
                <option key={r.resolution_id} value={r.resolution_id}>
                  {r.resolution_reference} ({r.visibility}) — {r.resolution_text.slice(0, 60)}
                  {r.resolution_text.length > 60 ? "…" : ""}
                </option>
              ))}
            </select>
          </Field>
        </div>
        <div style={{ marginTop: 16 }}>
          <Field label="Visibility (required)" htmlFor="visibility"
                 hint="A public project appears in residents' Community Updates straight away.">
            <select id="visibility" value={form.visibility}
                    onChange={(event) => update("visibility", event.target.value)}>
              <option value="internal">Internal — council record only</option>
              <option value="public">Public — shown to residents</option>
            </select>
          </Field>
        </div>

        <div className="dialog-actions">
          <button type="button" className="btn btn-ghost" onClick={onClose}>Cancel</button>
          <button type="button" className="btn btn-primary" disabled={busy || !ready}
                  onClick={async () => {
                    setBusy(true);
                    setError(null);
                    const result = await createProject(form);
                    setBusy(false);
                    if (!result.ok) { setError(result.message); return; }
                    await onDone(`Project ${result.data.project_reference} has been created.`);
                  }}>
            {busy ? "Saving…" : "Create the project"}
          </button>
        </div>
      </div>
    </div>
  );
}
