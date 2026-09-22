import { useCallback, useEffect, useState } from "react";
import { Link, useSearchParams } from "react-router-dom";
import { AppShell } from "../../components/AppShell";
import { Field, Loading, Notice } from "../../components/ui";
import { formatDate, formatDateTime } from "../../lib/format";
import {
  resolutionVisibilityHistory, resolutions as loadResolutions,
  setResolutionStatus, setResolutionVisibility,
} from "../../registry/secretaryApi";
import type { ResolutionRow, VisibilityChange } from "../../registry/secretaryTypes";
import { ReasonDialog } from "./MeetingDetail";

const STATUSES = [
  { value: "", label: "All" },
  { value: "active", label: "Active" },
  { value: "implemented", label: "Implemented" },
  { value: "withdrawn", label: "Withdrawn" },
];

const VISIBILITIES = [
  { value: "", label: "All" },
  { value: "internal", label: "Internal" },
  { value: "public", label: "Public" },
];

/** Everything the council has ever resolved. */
export function Resolutions() {
  const [params, setParams] = useSearchParams();
  const status = params.get("status") ?? "";
  const visibility = params.get("visibility") ?? "";
  const [search, setSearch] = useState("");
  const [applied, setApplied] = useState("");
  const [rows, setRows] = useState<ResolutionRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [dialog, setDialog] = useState<
    | { kind: "withdraw"; row: ResolutionRow }
    | { kind: "unpublish"; row: ResolutionRow }
    | { kind: "history"; row: ResolutionRow }
    | null
  >(null);

  const load = useCallback(async () => {
    const result = await loadResolutions(status, visibility, applied);
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

  const done = async (message: string) => {
    setDialog(null);
    setSuccess(message);
    await load();
  };

  return (
    <AppShell>
      <div className="page-head">
        <h1>Resolutions</h1>
        <p>
          A resolution is recorded from the meeting that decided it, and its decision date is that
          meeting's date. Resolutions are recorded on the meeting's own page.
        </p>
      </div>

      {error ? <Notice kind="error">{error}</Notice> : null}
      {success ? <div style={{ marginBottom: 18 }}><Notice kind="success">{success}</Notice></div> : null}

      <div className="card">
        <form className="filters" onSubmit={(event) => { event.preventDefault(); setApplied(search.trim()); }}>
          <Field label="Search" htmlFor="q" hint="Reference, wording or meeting reference.">
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

      {rows === null && !error ? <Loading what="Loading resolutions" /> : null}

      {rows !== null
        ? (
          <div className="card">
            <h2 className="card-title">{rows.length} resolution{rows.length === 1 ? "" : "s"}</h2>
            {rows.length === 0
              ? <p className="muted-note">Nothing here.</p>
              : (
                <div className="stack">
                  {rows.map((row) => (
                    <div className="lineage-row" key={row.resolution_id}>
                      <div style={{ width: "100%" }}>
                        <div className="row-between">
                          <span className="name">{row.resolution_reference}</span>
                          <div className="row-actions">
                            <span className={`badge ${row.visibility === "public" ? "badge-active" : "badge-deactivated"}`}>
                              {row.visibility}
                            </span>
                            <span className={`badge ${row.resolution_status === "implemented" ? "badge-active" : "badge-deactivated"}`}>
                              {row.resolution_status}
                            </span>
                          </div>
                        </div>

                        <p style={{ marginTop: 6, whiteSpace: "pre-wrap" }}>{row.resolution_text}</p>

                        <div className="status-note" style={{ marginTop: 6 }}>
                          Decided {formatDate(row.decision_date)} at{" "}
                          <Link to={`/secretary/meetings/${row.meeting_id}`}>
                            {row.meeting_reference}
                          </Link>{" "}
                          · {row.project_count} project{row.project_count === 1 ? "" : "s"}
                          {row.withdrawal_reason ? ` · ${row.withdrawal_reason}` : ""}
                        </div>

                        <div className="status-note" style={{ marginTop: 4 }}>
                          {row.visible_to_residents
                            ? "Residents can see this in Community Updates."
                            : row.visibility === "public"
                            ? "Public, but residents cannot see it yet: the minutes of its meeting are not final."
                            : "Internal — residents cannot see it."}
                        </div>

                        <div className="row-actions" style={{ marginTop: 10 }}>
                          {row.resolution_status === "active"
                            ? (
                              <>
                                <button type="button" className="btn btn-ghost btn-small"
                                        onClick={() => void setResolutionStatus(
                                          row.resolution_id, "implemented").then(async (r) => {
                                            if (r.ok) await done(`${row.resolution_reference} is recorded as implemented.`);
                                            else setError(r.message);
                                          })}>
                                  Mark implemented
                                </button>
                                <button type="button" className="btn btn-danger btn-small"
                                        onClick={() => setDialog({ kind: "withdraw", row })}>
                                  Withdraw
                                </button>
                              </>
                            )
                            : null}
                          {row.visibility === "internal"
                            ? (
                              <button type="button" className="btn btn-ghost btn-small"
                                      onClick={() => void setResolutionVisibility(
                                        row.resolution_id, "public").then(async (r) => {
                                          if (r.ok) await done(`${row.resolution_reference} is now public.`);
                                          else setError(r.message);
                                        })}>
                                Make public
                              </button>
                            )
                            : (
                              <button type="button" className="btn btn-danger btn-small"
                                      onClick={() => setDialog({ kind: "unpublish", row })}>
                                Take off the public record
                              </button>
                            )}
                          <button type="button" className="btn btn-ghost btn-small"
                                  onClick={() => setDialog({ kind: "history", row })}>
                            Publication history
                          </button>
                        </div>
                      </div>
                    </div>
                  ))}
                </div>
              )}
          </div>
        )
        : null}

      {dialog?.kind === "withdraw"
        ? (
          <ReasonDialog
            title={`Withdraw ${dialog.row.resolution_reference}`}
            intro="The resolution is kept on record as withdrawn, with your reason. It cannot be made active again."
            label="Why is the resolution withdrawn?"
            confirmLabel="Withdraw the resolution"
            onClose={() => setDialog(null)}
            onConfirm={async (reason) => {
              const result = await setResolutionStatus(dialog.row.resolution_id, "withdrawn", reason);
              if (!result.ok) return result.message;
              await done(`${dialog.row.resolution_reference} has been withdrawn.`);
              return null;
            }}
          />
        )
        : null}

      {dialog?.kind === "unpublish"
        ? (
          <ReasonDialog
            title={`Take ${dialog.row.resolution_reference} off the public record`}
            intro={
              "Residents will no longer see this resolution. It does not disappear: the change, " +
              "your reason and your name are kept in its publication history."
            }
            label="Why is it being taken back?"
            confirmLabel="Make it internal"
            onClose={() => setDialog(null)}
            onConfirm={async (reason) => {
              const result = await setResolutionVisibility(dialog.row.resolution_id, "internal", reason);
              if (!result.ok) return result.message;
              await done(`${dialog.row.resolution_reference} is internal again.`);
              return null;
            }}
          />
        )
        : null}

      {dialog?.kind === "history"
        ? <HistoryDialog row={dialog.row} onClose={() => setDialog(null)} />
        : null}
    </AppShell>
  );
}

function HistoryDialog({ row, onClose }: { row: ResolutionRow; onClose: () => void }) {
  const [history, setHistory] = useState<VisibilityChange[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    resolutionVisibilityHistory(row.resolution_id).then((result) => {
      if (cancelled) return;
      if (result.ok) setHistory(result.data);
      else setError(result.message);
    });
    return () => { cancelled = true; };
  }, [row.resolution_id]);

  return (
    <div className="backdrop" role="dialog" aria-modal="true" aria-label="Publication history">
      <div className="dialog">
        <h2>{row.resolution_reference}</h2>
        <p className="dialog-intro">
          Every change of visibility, in both directions. Nothing published ever quietly disappears.
        </p>

        {error ? <Notice kind="error">{error}</Notice> : null}
        {history === null && !error ? <Loading what="Loading the history" /> : null}

        {history
          ? history.length === 0
            ? <p className="muted-note">This resolution has never been published.</p>
            : (
              <div className="stack" style={{ marginTop: 14 }}>
                {history.map((change, index) => (
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
            )
          : null}

        <div className="dialog-actions">
          <button type="button" className="btn btn-ghost" onClick={onClose}>Close</button>
        </div>
      </div>
    </div>
  );
}
