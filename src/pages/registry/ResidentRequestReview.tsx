import { useCallback, useEffect, useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { AppShell } from "../../components/AppShell";
import { Field, Loading, Notice } from "../../components/ui";
import { ResidentStatusBadge } from "./bits";
import { formatDate, formatDateTime } from "../../lib/format";
import {
  approveResidentRequest, declineResidentRequest, residentCandidates,
  residentRequest, searchResidents,
} from "../../registry/api";
import { DOCUMENT_LABELS, signedDocumentUrl } from "../../registry/residentApi";
import type { CandidateRow, ResidentRequestDetail, ResidentSearchRow } from "../../registry/types";

/**
 * Judging one application, with what the applicant claims on the left
 * and the official record on the right.
 *
 * Nothing on the left is ever written to the register. It is evidence
 * for deciding which record on the right this person is — and the clerk
 * makes that decision, not the system.
 */
export function ResidentRequestReview() {
  const { requestId = "" } = useParams();
  const navigate = useNavigate();

  const [request, setRequest] = useState<ResidentRequestDetail | null>(null);
  const [candidates, setCandidates] = useState<CandidateRow[]>([]);
  const [chosen, setChosen] = useState<CandidateRow | null>(null);
  const [search, setSearch] = useState("");
  const [searchResults, setSearchResults] = useState<ResidentSearchRow[]>([]);
  const [declining, setDeclining] = useState(false);
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  const load = useCallback(async () => {
    const [detail, suggestions] = await Promise.all([
      residentRequest(requestId),
      residentCandidates(requestId),
    ]);
    if (!detail.ok) { setError(detail.message); return; }
    setRequest(detail.data);
    if (suggestions.ok) {
      setCandidates(suggestions.data);
      // The clerk still chooses; this only puts the likeliest in view.
      setChosen(suggestions.data.find((row) => row.match_rank === 1 && !row.already_linked) ?? null);
    }
  }, [requestId]);

  useEffect(() => { void load(); }, [load]);

  useEffect(() => {
    if (!search.trim()) { setSearchResults([]); return; }
    const timer = window.setTimeout(async () => {
      const result = await searchResidents(search);
      if (result.ok) setSearchResults(result.data.slice(0, 20));
    }, 250);
    return () => window.clearTimeout(timer);
  }, [search]);

  async function openDocument(path: string) {
    const url = await signedDocumentUrl(path);
    if (!url) { setError("That document could not be opened."); return; }
    window.open(url, "_blank", "noopener,noreferrer");
  }

  async function approve() {
    if (!chosen) return;
    setSubmitting(true);
    setError(null);
    const result = await approveResidentRequest(requestId, chosen.resident_id);
    setSubmitting(false);
    if (!result.ok) { setError(result.message); return; }
    navigate("/registry/resident-accounts", { replace: true });
  }

  async function decline() {
    setSubmitting(true);
    setError(null);
    const result = await declineResidentRequest(requestId, reason);
    setSubmitting(false);
    if (!result.ok) { setError(result.message); return; }
    navigate("/registry/resident-accounts", { replace: true });
  }

  if (error && !request) return <AppShell><Notice kind="error">{error}</Notice></AppShell>;
  if (!request) return <AppShell><Loading what="Loading the application" /></AppShell>;

  const claimed = request.claimed;
  const decided = request.request_status !== "pending";

  return (
    <AppShell>
      <div className="page-head row-between">
        <div>
          <h1>{claimed.full_name}</h1>
          <p>
            Applied {formatDateTime(request.submitted_at)} · {request.account_email}
            {request.earlier_attempts.length > 0
              ? ` · ${request.earlier_attempts.length} earlier attempt(s)`
              : ""}
          </p>
        </div>
        <Link to="/registry/resident-accounts" className="btn btn-ghost">Back to applications</Link>
      </div>

      {error ? <div style={{ marginBottom: 18 }}><Notice kind="error">{error}</Notice></div> : null}
      {decided
        ? (
          <div style={{ marginBottom: 18 }}>
            <Notice kind="info">
              This application was already {request.request_status}
              {request.reviewed_at ? ` on ${formatDate(request.reviewed_at)}` : ""}.
            </Notice>
          </div>
        )
        : null}

      <div className="grid-2">
        {/* ---- what the applicant says ---- */}
        <div className="card">
          <h2 className="card-title">What the applicant sent</h2>
          <div className="detail-list">
            <Row label="Full name" value={claimed.full_name} />
            <Row label="Previous surname" value={claimed.previous_surname} />
            <Row label="ID number" value={claimed.id_number} />
            <Row label="Date of birth" value={formatDate(claimed.date_of_birth)} />
            <Row label="Gender" value={claimed.gender} />
            <Row label="Cellphone" value={claimed.cellphone_number} />
            <Row label="Email" value={request.account_email} />
            <Row label="Address" value={`${claimed.house_number} ${claimed.street_address}`} />
            <Row label="Household head" value={claimed.household_head_name} />
            <Row label="Relationship to head" value={claimed.relationship_to_household_head} />
          </div>

          <h3 className="lineage-heading" style={{ marginTop: 22 }}>Documents</h3>
          <div className="stack">
            {request.documents.map((document) => (
              <div className="lineage-row" key={document.document_type}>
                <div>
                  <span className="name">{DOCUMENT_LABELS[document.document_type]}</span>
                  <div className="status-note">
                    {document.file_name} · {(document.file_size_bytes / 1024).toFixed(0)} KB
                  </div>
                </div>
                <button type="button" className="btn btn-ghost btn-small"
                        onClick={() => void openDocument(document.storage_path)}>
                  View
                </button>
              </div>
            ))}
          </div>
          <p className="muted-note" style={{ marginTop: 14 }}>
            Documents open through a link that expires in two minutes. They have no public address.
          </p>
        </div>

        {/* ---- the official record ---- */}
        <div className="card">
          <h2 className="card-title">The official record on the register</h2>

          {chosen
            ? (
              <>
                <div className="detail-list">
                  <Row label="Full name" value={chosen.full_name} />
                  <Row label="ID number" value={chosen.id_number} />
                  <Row label="Date of birth" value={formatDate(chosen.date_of_birth)} />
                  <Row label="Gender" value={chosen.gender} />
                  <div className="detail-item">
                    <span className="label">Resident status</span>
                    <span className="value"><ResidentStatusBadge status={chosen.resident_status} /></span>
                  </div>
                  <Row label="Address" value={chosen.street_address} />
                  <Row label="Household" value={chosen.household_code} />
                  <Row label="Household head" value={chosen.household_head} />
                </div>

                {!chosen.household_code
                  ? (
                    <div style={{ marginTop: 18 }}>
                      <Notice kind="error">
                        This resident is not linked to a household yet, so the account cannot be
                        approved. Link them to their household first, then come back.
                      </Notice>
                    </div>
                  )
                  : null}
                {chosen.already_linked
                  ? (
                    <div style={{ marginTop: 18 }}>
                      <Notice kind="error">This resident already has an account.</Notice>
                    </div>
                  )
                  : null}
              </>
            )
            : <Notice kind="info">Choose the record on the register that this applicant is.</Notice>}

          <h3 className="lineage-heading" style={{ marginTop: 22 }}>Likely matches</h3>
          <div className="picker">
            {candidates.length === 0
              ? <p className="muted-note">Nothing on the register resembles these details.</p>
              : candidates.slice(0, 12).map((row) => (
                <button type="button" key={row.resident_id}
                        className={`picker-row${chosen?.resident_id === row.resident_id ? " chosen" : ""}`}
                        onClick={() => setChosen(row)}>
                  <span className="name">{row.full_name}</span>
                  <span className="status-note">
                    {row.id_number} · {row.match_reason}
                    {row.household_code ? ` · ${row.household_code}` : " · no household"}
                    {row.already_linked ? " · already has an account" : ""}
                  </span>
                </button>
              ))}
          </div>

          <div style={{ marginTop: 18 }}>
            <Field label="Or search the register yourself" htmlFor="register-search">
              <input id="register-search" type="search" placeholder="Identity number, name or household"
                     value={search} onChange={(event) => setSearch(event.target.value)} />
            </Field>
            {searchResults.length > 0
              ? (
                <div className="picker">
                  {searchResults.map((row) => (
                    <button type="button" key={row.resident_id} className="picker-row"
                            onClick={() => {
                              setChosen({
                                resident_id: row.resident_id, full_name: row.full_name,
                                id_number: row.id_number, date_of_birth: row.date_of_birth,
                                gender: row.gender, resident_status: row.resident_status,
                                household_code: row.household_code, household_head: null,
                                street_address: row.street_address, already_linked: false,
                                match_rank: 99, match_reason: "Chosen by hand",
                              });
                              setSearch("");
                            }}>
                      <span className="name">{row.full_name}</span>
                      <span className="status-note">
                        {row.id_number}{row.household_code ? ` · ${row.household_code}` : " · no household"}
                      </span>
                    </button>
                  ))}
                </div>
              )
              : null}
          </div>
        </div>
      </div>

      {request.earlier_attempts.length > 0
        ? (
          <div className="card" style={{ marginTop: 22 }}>
            <h2 className="card-title">Earlier attempts</h2>
            <div className="stack">
              {request.earlier_attempts.map((attempt, index) => (
                <div className="lineage-row" key={index}>
                  <div>
                    <span className="name">
                      {attempt.request_status === "declined" ? "Declined" : attempt.request_status}
                    </span>
                    <div className="status-note">
                      Sent {formatDate(attempt.submitted_at)}
                      {attempt.decline_reason ? ` · ${attempt.decline_reason}` : ""}
                    </div>
                  </div>
                </div>
              ))}
            </div>
          </div>
        )
        : null}

      {!decided
        ? (
          <div className="card" style={{ marginTop: 22 }}>
            <h2 className="card-title">Decision</h2>

            {declining
              ? (
                <>
                  <Field label="Why is this being declined?" htmlFor="decline-reason"
                         hint="The applicant sees this, so it has to say what they should correct.">
                    <textarea id="decline-reason" value={reason} maxLength={500}
                              placeholder="e.g. Proof of residence could not be verified"
                              onChange={(event) => setReason(event.target.value)} />
                  </Field>
                  <div className="row" style={{ marginTop: 18 }}>
                    <button type="button" className="btn btn-danger" disabled={submitting || !reason.trim()}
                            onClick={() => void decline()}>
                      {submitting ? "Saving…" : "Decline application"}
                    </button>
                    <button type="button" className="btn btn-ghost" onClick={() => setDeclining(false)}>
                      Go back
                    </button>
                  </div>
                </>
              )
              : (
                <>
                  <p className="muted-note" style={{ marginBottom: 18 }}>
                    Approving links this account to the chosen record. It changes nothing on the
                    register itself — if the official details are wrong, correct them with Update
                    resident first.
                  </p>
                  <div className="row">
                    <button type="button" className="btn btn-primary" disabled={submitting || !chosen}
                            onClick={() => void approve()}>
                      {chosen ? `Approve as ${chosen.full_name}` : "Choose a record to approve"}
                    </button>
                    <button type="button" className="btn btn-danger" onClick={() => setDeclining(true)}>
                      Decline
                    </button>
                  </div>
                </>
              )}
          </div>
        )
        : null}
    </AppShell>
  );
}

function Row({ label, value }: { label: string; value: string | null }) {
  return (
    <div className="detail-item">
      <span className="label">{label}</span>
      <span className="value">{value ?? "—"}</span>
    </div>
  );
}
