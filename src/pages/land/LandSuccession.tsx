import { useCallback, useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { AppShell } from "../../components/AppShell";
import { Field, Loading, Notice } from "../../components/ui";
import { formatDate } from "../../lib/format";
import {
  officerAllocations, recordSuccession, returnToAuthority, successionCandidates,
} from "../../registry/landApi";
import type { OfficerAllocationRow, SuccessionCandidate } from "../../registry/landTypes";

/**
 * A residential permission is perpetual, so when the holder dies the
 * stand does not fall vacant — it waits.
 *
 * TAMS never picks an heir. The Traditional Authority decides off the
 * system; the Land Officer records what was decided, or records that
 * the land comes back to the Authority.
 */
export function LandSuccession() {
  const [rows, setRows] = useState<OfficerAllocationRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [chosen, setChosen] = useState<OfficerAllocationRow | null>(null);

  const load = useCallback(async () => {
    const result = await officerAllocations("succession_pending");
    if (result.ok) { setRows(result.data); setError(null); }
    else { setRows([]); setError(result.message); }
  }, []);

  useEffect(() => { void load(); }, [load]);

  if (chosen) {
    return (
      <AppShell>
        <SuccessionReview
          allocation={chosen}
          onBack={() => setChosen(null)}
          onDone={async (message) => {
            setChosen(null);
            setSuccess(message);
            await load();
          }}
        />
      </AppShell>
    );
  }

  return (
    <AppShell>
      <div className="page-head">
        <h1>Residential succession</h1>
        <p>
          When a residential holder is recorded as deceased, their stand is held here rather than
          being freed. Nobody else can be given it until the Authority has decided who takes it on.
        </p>
      </div>

      {error ? <Notice kind="error">{error}</Notice> : null}
      {success ? <div style={{ marginBottom: 18 }}><Notice kind="success">{success}</Notice></div> : null}
      {rows === null && !error ? <Loading what="Loading" /> : null}

      {rows !== null
        ? (
          <div className="card">
            <h2 className="card-title">
              {rows.length} stand{rows.length === 1 ? "" : "s"} waiting for succession
            </h2>
            {rows.length === 0
              ? <p className="muted-note">Nothing is waiting.</p>
              : (
                <div className="table-wrap">
                  <table>
                    <thead>
                      <tr>
                        <th>Reference</th><th>Site</th><th>Household</th>
                        <th>Previous holder</th><th>Allocated</th><th></th>
                      </tr>
                    </thead>
                    <tbody>
                      {rows.map((row) => (
                        <tr key={row.allocation_id}>
                          <td className="no-wrap">{row.allocation_reference}</td>
                          <td className="no-wrap">
                            <Link to={`/land/sites/${row.site_id}`}>{row.site_code}</Link>
                            <div className="status-note">{row.street_address}</div>
                          </td>
                          <td className="no-wrap">{row.household_code ?? "—"}</td>
                          <td>{row.holder_name ?? "—"}</td>
                          <td className="no-wrap">{formatDate(row.allocation_date)}</td>
                          <td>
                            <button type="button" className="btn btn-primary btn-small"
                                    onClick={() => setChosen(row)}>
                              Record the decision
                            </button>
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
    </AppShell>
  );
}

// ---------------------------------------------------------------------

function SuccessionReview({
  allocation, onBack, onDone,
}: {
  allocation: OfficerAllocationRow;
  onBack: () => void;
  onDone: (message: string) => void | Promise<void>;
}) {
  const [candidates, setCandidates] = useState<SuccessionCandidate[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [chosenId, setChosenId] = useState<string | null>(null);
  const [note, setNote] = useState("");
  const [returning, setReturning] = useState(false);
  const [returnReason, setReturnReason] = useState("");
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    let cancelled = false;
    successionCandidates(allocation.allocation_id).then((result) => {
      if (cancelled) return;
      if (result.ok) setCandidates(result.data);
      else setError(result.message);
    });
    return () => { cancelled = true; };
  }, [allocation.allocation_id]);

  return (
    <>
      <div className="page-head row-between">
        <div>
          <h1>{allocation.site_code}</h1>
          <p>
            {allocation.allocation_reference} · household {allocation.household_code ?? "—"} ·
            previously held by {allocation.holder_name ?? "—"}
          </p>
        </div>
        <button type="button" className="btn btn-ghost" onClick={onBack}>Back</button>
      </div>

      {error ? <Notice kind="error">{error}</Notice> : null}

      <div className="card">
        <Notice kind="info">
          TAMS does not choose a successor and does not rank anyone. The people below are simply
          the other members of this household. Record whoever the Traditional Authority has
          decided on.
        </Notice>
      </div>

      <div className="card">
        <h2 className="card-title">Members of this household</h2>
        {candidates === null && !error
          ? <Loading what="Loading household members" />
          : candidates && candidates.length === 0
          ? <p className="muted-note">This household has no other members on the register.</p>
          : (
            <div className="picker">
              {(candidates ?? []).map((candidate) => (
                <button type="button" key={candidate.resident_id}
                        className={`picker-row${chosenId === candidate.resident_id ? " chosen" : ""}`}
                        disabled={!candidate.eligible}
                        onClick={() => setChosenId(candidate.resident_id)}>
                  <span className="name">{candidate.full_name}</span>
                  <span className="status-note">
                    {candidate.age} years old · {candidate.id_number}
                    {candidate.relationship ? ` · ${candidate.relationship}` : ""}
                  </span>
                  {!candidate.eligible
                    ? (
                      <ul className="land-problems">
                        {candidate.problems.map((problem) => <li key={problem}>{problem}</li>)}
                      </ul>
                    )
                    : null}
                </button>
              ))}
            </div>
          )}

        <div style={{ marginTop: 18 }}>
          <Field label="What did the Authority decide?" htmlFor="succession-note"
                 hint="Optional — a note of the decision, kept with the record.">
            <textarea id="succession-note" value={note} maxLength={1000}
                      onChange={(event) => setNote(event.target.value)} />
          </Field>
        </div>

        <div className="row" style={{ marginTop: 18 }}>
          <button type="button" className="btn btn-primary" disabled={busy || !chosenId}
                  onClick={async () => {
                    setBusy(true);
                    setError(null);
                    const result = await recordSuccession(
                      allocation.allocation_id, chosenId ?? "", note.trim());
                    setBusy(false);
                    if (!result.ok) { setError(result.message); return; }
                    await onDone(
                      `${result.data.successor} now holds ${allocation.site_code}, ` +
                        `under ${result.data.pto_number}.`,
                    );
                  }}>
            {busy ? "Recording…" : "Record the successor"}
          </button>
          <button type="button" className="btn btn-danger" onClick={() => setReturning(true)}>
            Return the land to the Authority
          </button>
        </div>
      </div>

      {returning
        ? (
          <div className="backdrop" role="dialog" aria-modal="true"
               aria-label="Return the land to the Authority">
            <div className="dialog">
              <h2>Return {allocation.site_code} to the Authority</h2>
              <p className="dialog-intro">
                Use this only when the Authority has decided there is no successor. The allocation
                is closed, the site becomes available again, and everything stays on record.
              </p>

              {error ? <Notice kind="error">{error}</Notice> : null}

              <div style={{ marginTop: 18 }}>
                <Field label="Why is the land coming back?" htmlFor="return-reason">
                  <textarea id="return-reason" value={returnReason} maxLength={1000}
                            onChange={(event) => setReturnReason(event.target.value)} />
                </Field>
              </div>

              <div className="dialog-actions">
                <button type="button" className="btn btn-ghost" onClick={() => setReturning(false)}>
                  Cancel
                </button>
                <button type="button" className="btn btn-danger" disabled={busy || !returnReason.trim()}
                        onClick={async () => {
                          setBusy(true);
                          setError(null);
                          const result = await returnToAuthority(
                            allocation.allocation_id, returnReason.trim());
                          setBusy(false);
                          if (!result.ok) { setError(result.message); return; }
                          await onDone(
                            `${allocation.site_code} has been returned to the Traditional Authority.`,
                          );
                        }}>
                  {busy ? "Working…" : "Return the land"}
                </button>
              </div>
            </div>
          </div>
        )
        : null}
    </>
  );
}
