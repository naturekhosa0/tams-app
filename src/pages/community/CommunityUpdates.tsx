import { useEffect, useState } from "react";
import { Loading, Notice } from "../../components/ui";
import { formatDate } from "../../lib/format";
import { communityUpdates } from "../../registry/secretaryApi";
import { MILESTONE_LABELS } from "../../registry/secretaryTypes";
import type { CommunityUpdates as Updates } from "../../registry/secretaryTypes";

const MILESTONE_MARK: Record<string, string> = {
  completed: "✓",
  in_progress: "•",
  overdue: "!",
  pending: "•",
};

/**
 * What the traditional authority has published for the community: the
 * resolutions it has confirmed and the projects it is running.
 *
 * Read-only, and narrow by construction. The database hands a resident
 * only these fields, for only these records — nothing is fetched and
 * then hidden here.
 */
export function CommunityUpdates() {
  const [updates, setUpdates] = useState<Updates | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    communityUpdates().then((result) => {
      if (cancelled) return;
      if (result.ok) setUpdates(result.data);
      else setError(result.message);
    });
    return () => { cancelled = true; };
  }, []);

  if (error) return <Notice kind="error">{error}</Notice>;
  if (!updates) return <Loading what="Loading community updates" />;

  return (
    <>
      <div className="card">
        <h2 className="card-title">Council resolutions</h2>
        <p className="muted-note" style={{ marginBottom: 16 }}>
          Decisions the traditional council has taken and published, once the minutes of the
          meeting have been confirmed.
        </p>

        {updates.resolutions.length === 0
          ? <p className="muted-note">Nothing has been published yet.</p>
          : (
            <div className="stack">
              {updates.resolutions.map((resolution) => (
                <div className="lineage-row" key={resolution.resolution_reference}>
                  <div style={{ width: "100%" }}>
                    <div className="row-between">
                      <span className="name">{resolution.resolution_reference}</span>
                      <span className={`badge ${resolution.resolution_status === "withdrawn" ? "badge-deactivated" : "badge-active"}`}>
                        {resolution.resolution_status}
                      </span>
                    </div>
                    <p style={{ marginTop: 6, whiteSpace: "pre-wrap" }}>
                      {resolution.resolution_text}
                    </p>
                    <div className="status-note" style={{ marginTop: 6 }}>
                      Decided {formatDate(resolution.decision_date)}
                      {resolution.resolution_status === "withdrawn"
                        ? " · this decision has since been withdrawn"
                        : ""}
                    </div>
                  </div>
                </div>
              ))}
            </div>
          )}
      </div>

      <div className="card">
        <h2 className="card-title">Community projects</h2>
        <p className="muted-note" style={{ marginBottom: 16 }}>
          What is being built, and how far along it is.
        </p>

        {updates.projects.length === 0
          ? <p className="muted-note">No projects have been published yet.</p>
          : (
            <div className="stack">
              {updates.projects.map((project) => (
                <div className="project-card" key={project.project_reference}>
                  <div className="row-between">
                    <div>
                      <span className="name">{project.project_name}</span>
                      <div className="status-note">{project.project_reference}</div>
                    </div>
                    <span className={`badge ${project.project_status === "active" || project.project_status === "completed" ? "badge-active" : "badge-deactivated"}`}>
                      {project.project_status}
                    </span>
                  </div>

                  <p style={{ marginTop: 10, whiteSpace: "pre-wrap" }}>{project.description}</p>

                  <div className="status-note" style={{ marginTop: 8 }}>
                    Started {formatDate(project.start_date)}
                    {project.target_completion_date
                      ? ` · due to finish ${formatDate(project.target_completion_date)}`
                      : ""}
                    {project.resolution_reference
                      ? ` · from resolution ${project.resolution_reference}`
                      : ""}
                  </div>

                  {project.milestones.length > 0
                    ? (
                      <ul className="milestone-list">
                        {project.milestones.map((milestone) => (
                          <li key={milestone.title}
                              className={`milestone milestone-${milestone.effective_status}`}>
                            <span className="milestone-mark" aria-hidden="true">
                              {MILESTONE_MARK[milestone.effective_status] ?? "•"}
                            </span>
                            <span className="milestone-title">{milestone.title}</span>
                            <span className="milestone-status">
                              {MILESTONE_LABELS[milestone.effective_status]}
                            </span>
                          </li>
                        ))}
                      </ul>
                    )
                    : null}
                </div>
              ))}
            </div>
          )}
      </div>
    </>
  );
}
