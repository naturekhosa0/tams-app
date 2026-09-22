import { useCallback, useEffect, useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { AppShell } from "../../components/AppShell";
import { Field, Loading, Notice } from "../../components/ui";
import { LineageList } from "./LineageList";
import { EndRelationshipDialog, RecordRelationshipDialog } from "./dialogs";
import { familyLineage, residentRecord, searchResidents } from "../../registry/api";
import type { LineageRow, ResidentRecord, ResidentSearchRow } from "../../registry/types";
import { PageHead } from "../../components/PageHead";

/**
 * Family lineage for one resident, built entirely from
 * family_relationships. Nothing here is stored as a tree.
 */
export function FamilyLineage() {
  const { residentId } = useParams();
  const navigate = useNavigate();

  const [search, setSearch] = useState("");
  const [candidates, setCandidates] = useState<ResidentSearchRow[]>([]);
  const [record, setRecord] = useState<ResidentRecord | null>(null);
  const [rows, setRows] = useState<LineageRow[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [recording, setRecording] = useState(false);
  const [ending, setEnding] = useState<LineageRow | null>(null);
  const [loading, setLoading] = useState(Boolean(residentId));

  const load = useCallback(async () => {
    if (!residentId) { setRecord(null); setRows([]); setLoading(false); return; }
    setLoading(true);
    const [detail, relationships] = await Promise.all([
      residentRecord(residentId),
      familyLineage(residentId),
    ]);
    if (!detail.ok) { setError(detail.message); setLoading(false); return; }
    setRecord(detail.data);
    setRows(relationships.ok ? relationships.data : []);
    setError(null);
    setLoading(false);
  }, [residentId]);

  useEffect(() => { void load(); }, [load]);

  useEffect(() => {
    if (residentId) return;
    const timer = window.setTimeout(async () => {
      const result = await searchResidents(search);
      if (result.ok) setCandidates(result.data.slice(0, 40));
    }, 250);
    return () => window.clearTimeout(timer);
  }, [search, residentId]);

  // ---- no resident chosen yet: pick one ------------------------------
  if (!residentId) {
    return (
      <AppShell>
        <PageHead
          title="Family lineage"
          description="Choose a resident to see their family relationships."
          crumbs={[{ label: "Dashboard", to: "/registry" }, { label: "Family lineage" }]}
          actions={<Link to="/registry" className="btn btn-ghost">Back to dashboard</Link>}
        />

        <div className="card">
          <Field label="Find a resident" htmlFor="lineage-search">
            <input
              id="lineage-search"
              type="search"
              placeholder="Identity number, name or household code"
              value={search}
              onChange={(event) => setSearch(event.target.value)}
            />
          </Field>

          <div className="picker" style={{ marginTop: 18 }}>
            {candidates.length === 0
              ? <p className="muted-note">No residents match that search.</p>
              : candidates.map((row) => (
                <button
                  type="button"
                  key={row.resident_id}
                  className="picker-row"
                  onClick={() => navigate(`/registry/lineage/${row.resident_id}`)}
                >
                  <span className="name">{row.full_name}</span>
                  <span className="status-note">
                    {row.id_number}{row.household_code ? ` · ${row.household_code}` : ""}
                  </span>
                </button>
              ))}
          </div>
        </div>
      </AppShell>
    );
  }

  if (loading) return <AppShell><Loading what="Loading the family lineage" /></AppShell>;
  if (error && !record) return <AppShell><Notice kind="error">{error}</Notice></AppShell>;
  if (!record) return null;

  return (
    <AppShell>
      <div className="page-head row-between">
        <div>
          <h1>{record.full_name}</h1>
          <p>
            Family lineage · {record.id_number}
            {record.household_code ? ` · ${record.household_code}` : ""}
          </p>
        </div>
        <div className="row">
          <Link to={`/registry/residents/${record.resident_id}`} className="btn btn-ghost">Resident record</Link>
          <Link to="/registry/lineage" className="btn btn-ghost">Choose another</Link>
          <button type="button" className="btn btn-primary" onClick={() => setRecording(true)}>
            Record relationship
          </button>
        </div>
      </div>

      {error ? <Notice kind="error">{error}</Notice> : null}
      {success ? <div style={{ marginBottom: 18 }}><Notice kind="success">{success}</Notice></div> : null}

      <div className="card">
        <h2 className="card-title">Related to</h2>
        <LineageList residentName={record.full_name} rows={rows} onEnd={(row) => setEnding(row)} />
        <p className="muted-note" style={{ marginTop: 20 }}>
          Lineage is permanent and is never ended: a parent remains a parent. A marriage or a
          guardianship can end, and can begin again later as a new one — nothing is ever deleted.
        </p>
      </div>

      {ending
        ? (
          <EndRelationshipDialog
            residentName={record.full_name}
            row={ending}
            onClose={() => setEnding(null)}
            onDone={async (message: string) => {
              setEnding(null);
              setSuccess(message);
              await load();
            }}
          />
        )
        : null}

      {recording
        ? (
          <RecordRelationshipDialog
            resident={{ resident_id: record.resident_id, full_name: record.full_name }}
            onClose={() => setRecording(false)}
            onDone={async (message: string) => {
              setRecording(false);
              setSuccess(message);
              await load();
            }}
          />
        )
        : null}
    </AppShell>
  );
}
