import { useCallback, useEffect, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { AppShell } from "../../components/AppShell";
import { Field, Loading, Notice } from "../../components/ui";
import { formatDate, formatDateTime } from "../../lib/format";
import {
  allocateSite, approveApplication, availableSites, declineApplication, issuePto,
  officerApplication,
} from "../../registry/landApi";
import { BUSINESS_TYPES, FARMING_TYPES, LAND_TYPE_LABELS, LAND_TYPE_TERMS } from "../../registry/landTypes";
import type { AvailableSiteRow, LandType, OfficerApplication } from "../../registry/landTypes";

function labelOf(options: readonly { value: string; label: string }[], value: string | null) {
  return options.find((option) => option.value === value)?.label ?? value ?? "—";
}

/**
 * One application, everything that bears on it, and the decision.
 *
 * Approving does not allocate anything: a site is chosen afterwards,
 * and the rules are checked again at that point.
 */
export function LandApplicationReview() {
  const { applicationId = "" } = useParams();
  const [application, setApplication] = useState<OfficerApplication | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [declining, setDeclining] = useState(false);
  const [declineReason, setDeclineReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [sites, setSites] = useState<AvailableSiteRow[] | null>(null);
  const [chosenSite, setChosenSite] = useState<string | null>(null);
  const [allocation, setAllocation] = useState<{ id: string; reference: string; siteCode: string } | null>(null);
  const [issued, setIssued] = useState<{ ptoId: string; number: string } | null>(null);

  const load = useCallback(async () => {
    const result = await officerApplication(applicationId);
    if (result.ok) { setApplication(result.data); setError(null); }
    else setError(result.message);
  }, [applicationId]);

  useEffect(() => { void load(); }, [load]);

  // The list of free sites is only fetched once an application has been
  // approved — before that there is nothing to allocate.
  useEffect(() => {
    if (!application || application.application_status !== "approved") { setSites(null); return; }
    let cancelled = false;
    availableSites(application.land_type).then((result) => {
      if (cancelled) return;
      if (result.ok) setSites(result.data);
      else setError(result.message);
    });
    return () => { cancelled = true; };
  }, [application]);

  if (error && !application) {
    return <AppShell><Notice kind="error">{error}</Notice></AppShell>;
  }
  if (!application) return <AppShell><Loading what="Loading the application" /></AppShell>;

  async function run(work: () => Promise<{ ok: true } | { ok: false; message: string }>, done: string) {
    setBusy(true);
    setError(null);
    const result = await work();
    setBusy(false);
    if (!result.ok) { setError(result.message); return false; }
    setSuccess(done);
    await load();
    return true;
  }

  const eligibility = application.eligibility;
  const pending = application.application_status === "pending";
  const approved = application.application_status === "approved";

  return (
    <AppShell>
      <div className="page-head row-between">
        <div>
          <h1>{application.application_reference}</h1>
          <p>
            {LAND_TYPE_LABELS[application.land_type]} land · submitted{" "}
            {formatDateTime(application.submitted_at)} · {LAND_TYPE_TERMS[application.land_type]}
          </p>
        </div>
        <Link to="/land/applications" className="btn btn-ghost">Back to applications</Link>
      </div>

      {error ? <Notice kind="error">{error}</Notice> : null}
      {success ? <div style={{ marginBottom: 18 }}><Notice kind="success">{success}</Notice></div> : null}

      <div className="grid-2">
        <div className="card">
          <h2 className="card-title">The applicant</h2>
          <div className="detail-list">
            <div className="detail-item">
              <span className="label">Name</span>
              <span className="value">{application.applicant.full_name}</span>
            </div>
            <div className="detail-item">
              <span className="label">Identity number</span>
              <span className="value">{application.applicant.id_number}</span>
            </div>
            <div className="detail-item">
              <span className="label">Date of birth</span>
              <span className="value">
                {formatDate(application.applicant.date_of_birth)} · {application.applicant.age} years old
              </span>
            </div>
            <div className="detail-item">
              <span className="label">On the register</span>
              <span className="value">
                <span className={`badge ${application.applicant.resident_status === "active" ? "badge-active" : "badge-deactivated"}`}>
                  {application.applicant.resident_status}
                </span>
              </span>
            </div>
            <div className="detail-item">
              <span className="label">Household</span>
              <span className="value">
                {application.household.household_code}
                {application.household.is_head ? " · head of this household" : ""}
              </span>
            </div>
            <div className="detail-item">
              <span className="label">Head of household</span>
              <span className="value">{application.household.head_full_name ?? "—"}</span>
            </div>
          </div>
        </div>

        <div className="card">
          <h2 className="card-title">What was asked for</h2>
          <div className="detail-list">
            <div className="detail-item">
              <span className="label">Land type</span>
              <span className="value">{LAND_TYPE_LABELS[application.land_type]}</span>
            </div>
            <div className="detail-item">
              <span className="label">Reason given</span>
              <span className="value">{application.reason_for_application}</span>
            </div>
            {application.land_type === "residential"
              ? (
                <>
                  <div className="detail-item">
                    <span className="label">Intended use</span>
                    <span className="value">{application.intended_use ?? "—"}</span>
                  </div>
                  <div className="detail-item">
                    <span className="label">Lives with the household</span>
                    <span className="value">{application.lives_with_household ? "Yes" : "No"}</span>
                  </div>
                </>
              )
              : null}
            {application.land_type === "farming"
              ? (
                <>
                  <div className="detail-item">
                    <span className="label">Kind of farming</span>
                    <span className="value">{labelOf(FARMING_TYPES, application.farming_type)}</span>
                  </div>
                  <div className="detail-item">
                    <span className="label">What will be farmed</span>
                    <span className="value">{application.farming_activity ?? "—"}</span>
                  </div>
                </>
              )
              : null}
            {application.land_type === "business"
              ? (
                <>
                  <div className="detail-item">
                    <span className="label">Business name</span>
                    <span className="value">{application.business_name ?? "—"}</span>
                  </div>
                  <div className="detail-item">
                    <span className="label">Kind of business</span>
                    <span className="value">{labelOf(BUSINESS_TYPES, application.business_type)}</span>
                  </div>
                  <div className="detail-item">
                    <span className="label">What it will do</span>
                    <span className="value">{application.business_description ?? "—"}</span>
                  </div>
                </>
              )
              : null}
            <div className="detail-item">
              <span className="label">Status</span>
              <span className="value">
                <span className={`badge ${pending || application.application_status === "declined" ? "badge-deactivated" : "badge-active"}`}>
                  {application.application_status}
                </span>
              </span>
            </div>
            {application.decline_reason
              ? (
                <div className="detail-item">
                  <span className="label">Declined because</span>
                  <span className="value">{application.decline_reason}</span>
                </div>
              )
              : null}
          </div>
        </div>
      </div>

      <div className="card">
        <h2 className="card-title">Eligibility, checked just now</h2>
        {eligibility.eligible
          ? <Notice kind="success">Nothing stands in the way of this application.</Notice>
          : (
            <Notice kind="error">
              This applicant is not eligible:
              <ul className="land-problems">
                {eligibility.problems.map((problem) => <li key={problem}>{problem}</li>)}
              </ul>
            </Notice>
          )}
        <p className="muted-note" style={{ marginTop: 14 }}>
          The same check runs inside the database when you approve, and again when you allocate a
          site, so nothing can slip through between now and then.
        </p>
      </div>

      <div className="grid-2">
        <div className="card">
          <h2 className="card-title">Land this household already holds</h2>
          {application.land_held.length === 0
            ? <p className="muted-note">None.</p>
            : (
              <div className="table-wrap">
                <table>
                  <thead>
                    <tr><th>Reference</th><th>Type</th><th>Site</th><th>Held by</th><th>Status</th></tr>
                  </thead>
                  <tbody>
                    {application.land_held.map((held) => (
                      <tr key={held.allocation_reference}>
                        <td className="no-wrap">{held.allocation_reference}</td>
                        <td className="no-wrap">{LAND_TYPE_LABELS[held.land_type as LandType] ?? held.land_type}</td>
                        <td className="no-wrap">{held.site_code}</td>
                        <td>{held.held_by}</td>
                        <td className="no-wrap">
                          {held.allocation_status}
                          {held.burial_status ? ` · ${held.burial_status}` : ""}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
        </div>

        <div className="card">
          <h2 className="card-title">Earlier applications</h2>
          {application.earlier_applications.length === 0
            ? <p className="muted-note">This is their first application.</p>
            : (
              <div className="stack">
                {application.earlier_applications.map((earlier) => (
                  <div className="lineage-row" key={earlier.application_reference}>
                    <div>
                      <span className="name">
                        {earlier.application_reference} ·{" "}
                        {LAND_TYPE_LABELS[earlier.land_type as LandType] ?? earlier.land_type}
                      </span>
                      <div className="status-note">
                        {earlier.application_status} · {formatDate(earlier.submitted_at)}
                        {earlier.decline_reason ? ` · ${earlier.decline_reason}` : ""}
                      </div>
                    </div>
                  </div>
                ))}
              </div>
            )}
        </div>
      </div>

      {pending
        ? (
          <div className="card">
            <h2 className="card-title">Your decision</h2>
            {declining
              ? (
                <>
                  <Field label="Why is this application declined?" htmlFor="decline-reason"
                         hint="The applicant sees this, so say what they would need to change.">
                    <textarea id="decline-reason" value={declineReason} maxLength={1000}
                              onChange={(event) => setDeclineReason(event.target.value)} />
                  </Field>
                  <div className="row" style={{ marginTop: 18 }}>
                    <button type="button" className="btn btn-danger" disabled={busy || !declineReason.trim()}
                            onClick={() => void run(
                              () => declineApplication(applicationId, declineReason.trim()),
                              "The application has been declined and the reason recorded.",
                            ).then((done) => { if (done) setDeclining(false); })}>
                      {busy ? "Working…" : "Decline this application"}
                    </button>
                    <button type="button" className="btn btn-ghost" onClick={() => setDeclining(false)}>
                      Cancel
                    </button>
                  </div>
                </>
              )
              : (
                <>
                  <p className="muted-note">
                    Approving does not give anybody a site. It says the applicant qualifies; you
                    choose the site in the next step.
                  </p>
                  <div className="row" style={{ marginTop: 18 }}>
                    <button type="button" className="btn btn-primary" disabled={busy || !eligibility.eligible}
                            onClick={() => void run(
                              () => approveApplication(applicationId),
                              "Approved. Now choose a site to allocate.",
                            )}>
                      {busy ? "Working…" : "Approve"}
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

      {approved
        ? (
          <div className="card">
            <h2 className="card-title">Allocate a site</h2>
            {sites === null
              ? <Loading what="Loading available sites" />
              : sites.length === 0
              ? (
                <Notice kind="info">
                  There is no available {LAND_TYPE_LABELS[application.land_type].toLowerCase()} site
                  to allocate. Register one first, or free one up.
                </Notice>
              )
              : (
                <>
                  <div className="picker">
                    {sites.map((site) => (
                      <button type="button" key={site.site_id}
                              className={`picker-row${chosenSite === site.site_id ? " chosen" : ""}`}
                              onClick={() => setChosenSite(site.site_id)}>
                        <span className="name">{site.site_code}</span>
                        <span className="status-note">
                          {site.stand_number ? `Stand ${site.stand_number} · ` : ""}
                          {site.street_address}
                          {site.village_section ? ` · ${site.village_section}` : ""}
                        </span>
                      </button>
                    ))}
                  </div>
                  <div className="row" style={{ marginTop: 18 }}>
                    <button type="button" className="btn btn-primary" disabled={busy || !chosenSite}
                            onClick={async () => {
                              setBusy(true);
                              setError(null);
                              const result = await allocateSite(applicationId, chosenSite ?? "");
                              setBusy(false);
                              if (!result.ok) { setError(result.message); return; }
                              setAllocation({
                                id: result.data.allocation_id,
                                reference: result.data.allocation_reference,
                                siteCode: result.data.site_code,
                              });
                              setSuccess(
                                `Site ${result.data.site_code} allocated as ${result.data.allocation_reference}.`,
                              );
                              await load();
                            }}>
                      {busy ? "Allocating…" : "Allocate this site"}
                    </button>
                  </div>
                </>
              )}
          </div>
        )
        : null}

      {allocation
        ? (
          <div className="card">
            <h2 className="card-title">Issue the permission to occupy</h2>
            {issued
              ? (
                <>
                  <Notice kind="success">
                    {issued.number} has been issued for {allocation.siteCode}.
                  </Notice>
                  <div className="row" style={{ marginTop: 18 }}>
                    <Link to={`/pto/${issued.ptoId}`} className="btn btn-primary">
                      Open the document
                    </Link>
                    <Link to="/land/applications" className="btn btn-ghost">Back to applications</Link>
                  </div>
                </>
              )
              : (
                <>
                  <p className="muted-note">
                    Every field comes from the allocation and the register — the holder, the site
                    and the term. There is nothing for you to type, and nobody countersigns it.
                  </p>
                  <div className="row" style={{ marginTop: 18 }}>
                    <button type="button" className="btn btn-primary" disabled={busy}
                            onClick={async () => {
                              setBusy(true);
                              setError(null);
                              const result = await issuePto(allocation.id);
                              setBusy(false);
                              if (!result.ok) { setError(result.message); return; }
                              setIssued({ ptoId: result.data.pto_id, number: result.data.pto_number });
                            }}>
                      {busy ? "Issuing…" : "Issue the permission"}
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
