import { useCallback, useEffect, useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { AppShell } from "../../components/AppShell";
import { Field, Loading, Notice } from "../../components/ui";
import { LineageList } from "./LineageList";
import { RecordRelationshipDialog } from "./dialogs";
import { familyLineage, residentRecord, searchResidents, setRelationshipStatus } from "../../registry/api";
import type { LineageRow, ResidentRecord, ResidentSearchRow } from "../../registry/types";

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

  async function retire(row: LineageRow) {
    const result = await setRelationshipStatus(row.relationship_id, "inactive");
    if (!result.ok) { setError(result.message); return; }
    setSuccess(
      `${row.related_full_name} is no longer recorded as a current ${row.relationship_type}. ` +
        "The relationship is kept on record.",
    );
    await load();
  }

  // ---- no resident chosen yet: pick one ------------------------------
  if (!residentId) {
    return (
      <AppShell>
        <div className="page-head">
          <h1>Family lineage</h1>
          <p>Choose a resident to see how they are related to everyone else on the register.</p>
        </div>

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
        <LineageList residentName={record.full_name} rows={rows} onRetire={(row) => void retire(row)} />
        <p className="muted-note" style={{ marginTop: 20 }}>
          Relationships are never deleted. One that is no longer current is marked so and kept
          on record, together with the matching relationship the other way round.
        </p>
      </div>

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
