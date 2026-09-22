import { useCallback, useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { Field, Loading, Notice } from "../../components/ui";
import { formatDate } from "../../lib/format";
import { requestPtoRenewal, residentLandPortal, submitLandApplication } from "../../registry/landApi";
import {
  BUSINESS_TYPES, FARMING_TYPES, LAND_TYPES, LAND_TYPE_LABELS, LAND_TYPE_TERMS,
} from "../../registry/landTypes";
import type { LandType, PtoRow, ResidentLandPortal as Portal } from "../../registry/landTypes";

const STATUS_BADGE: Record<string, string> = {
  active: "badge-active", allocated: "badge-active", approved: "badge-active",
  pending: "badge-deactivated", declined: "badge-deactivated",
  expired: "badge-deactivated", revoked: "badge-deactivated",
  renewed: "badge-deactivated", superseded: "badge-deactivated",
};

/** A verified resident's land: what they hold, what they have asked for. */
export function ResidentLand() {
  const [portal, setPortal] = useState<Portal | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [applyingFor, setApplyingFor] = useState<LandType | null>(null);
  const [renewing, setRenewing] = useState<PtoRow | null>(null);

  const load = useCallback(async () => {
    const result = await residentLandPortal();
    if (result.ok) { setPortal(result.data); setError(null); }
    else setError(result.message);
  }, []);

  useEffect(() => { void load(); }, [load]);

  if (error) return <Notice kind="error">{error}</Notice>;
  if (!portal) return <Loading what="Loading your land" />;

  if (applyingFor) {
    return (
      <ApplicationForm
        landType={applyingFor}
        portal={portal}
        onCancel={() => setApplyingFor(null)}
        onDone={async (message) => {
          setApplyingFor(null);
          setSuccess(message);
          await load();
        }}
      />
    );
  }

  return (
    <>
      {success ? <div style={{ marginBottom: 18 }}><Notice kind="success">{success}</Notice></div> : null}

      <div className="card">
        <h2 className="card-title">Apply for land</h2>
        <p className="muted-note" style={{ marginBottom: 18 }}>
          You do not choose a site. If your application is approved, the Land Officer allocates
          one to you.
        </p>

        <div className="grid-2">
          {LAND_TYPES.map((landType) => {
            const eligibility = portal.eligibility[landType];
            return (
              <div className="land-option" key={landType}>
                <div className="row-between">
                  <div>
                    <div className="name">{LAND_TYPE_LABELS[landType]}</div>
                    <div className="status-note">{LAND_TYPE_TERMS[landType]}</div>
                  </div>
                  <button
                    type="button"
                    className="btn btn-primary btn-small"
                    disabled={!eligibility?.eligible}
                    onClick={() => setApplyingFor(landType)}
                  >
                    Apply
                  </button>
                </div>
                {!eligibility?.eligible && (eligibility?.problems?.length ?? 0) > 0
                  ? (
                    <ul className="land-problems">
                      {eligibility.problems.map((problem) => <li key={problem}>{problem}</li>)}
                    </ul>
                  )
                  : null}
              </div>
            );
          })}
        </div>
      </div>

      <div className="card">
        <h2 className="card-title">My land applications</h2>
        {portal.applications.length === 0
          ? <p className="muted-note">You have not applied for any land yet.</p>
          : (
            <div className="table-wrap">
              <table>
                <thead>
                  <tr>
                    <th>Reference</th><th>Land type</th><th>Submitted</th>
                    <th>Status</th><th>If declined, why</th>
                  </tr>
                </thead>
                <tbody>
                  {portal.applications.map((application) => (
                    <tr key={application.application_reference}>
                      <td className="no-wrap">{application.application_reference}</td>
                      <td className="no-wrap">{LAND_TYPE_LABELS[application.land_type]}</td>
                      <td className="no-wrap">{formatDate(application.submitted_at)}</td>
                      <td>
                        <span className={`badge ${STATUS_BADGE[application.application_status] ?? "badge-deactivated"}`}>
                          {application.application_status}
                        </span>
                      </td>
                      <td>{application.decline_reason ?? "—"}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
      </div>

      <div className="card">
        <h2 className="card-title">My allocations</h2>
        {portal.allocations.length === 0
          ? <p className="muted-note">No land has been allocated to you yet.</p>
          : (
            <div className="table-wrap">
              <table>
                <thead>
                  <tr><th>Reference</th><th>Land type</th><th>Site</th><th>Address</th>
                      <th>Allocated</th><th>Status</th></tr>
                </thead>
                <tbody>
                  {portal.allocations.map((allocation) => (
                    <tr key={allocation.allocation_reference}>
                      <td className="no-wrap">{allocation.allocation_reference}</td>
                      <td className="no-wrap">{LAND_TYPE_LABELS[allocation.land_type]}</td>
                      <td className="no-wrap">{allocation.site_code}</td>
                      <td>
                        {allocation.street_address}
                        {allocation.village_section ? <div className="status-note">{allocation.village_section}</div> : null}
                      </td>
                      <td className="no-wrap">{formatDate(allocation.allocation_date)}</td>
                      <td>
                        <span className={`badge ${STATUS_BADGE[allocation.allocation_status] ?? "badge-deactivated"}`}>
                          {allocation.allocation_status.replace("_", " ")}
                        </span>
                        {allocation.burial_status && allocation.burial_status !== "usable"
                          ? <div className="status-note">Plot is {allocation.burial_status}</div>
                          : null}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
      </div>

      <div className="card">
        <h2 className="card-title">My permissions to occupy</h2>
        {portal.ptos.length === 0
          ? <p className="muted-note">You do not hold any permission to occupy yet.</p>
          : (
            <div className="table-wrap">
              <table>
                <thead>
                  <tr><th>PTO number</th><th>Land type</th><th>Site</th><th>Issued</th>
                      <th>Expires</th><th>Status</th><th>Actions</th></tr>
                </thead>
                <tbody>
                  {portal.ptos.map((pto) => (
                    <tr key={pto.pto_id}>
                      <td className="no-wrap">{pto.pto_number}</td>
                      <td className="no-wrap">{LAND_TYPE_LABELS[pto.land_type]}</td>
                      <td className="no-wrap">{pto.site_code}</td>
                      <td className="no-wrap">{formatDate(pto.issue_date)}</td>
                      <td className="no-wrap">
                        {pto.perpetual ? <span className="muted-note">Perpetual</span> : formatDate(pto.expiry_date)}
                      </td>
                      <td>
                        <span className={`badge ${STATUS_BADGE[pto.effective_status] ?? "badge-deactivated"}`}>
                          {pto.effective_status}
                        </span>
                      </td>
                      <td>
                        <div className="row-actions">
                          <Link to={`/pto/${pto.pto_id}`} className="btn btn-ghost btn-small">View</Link>
                          {pto.renewable && !pto.renewal_pending
                            ? (
                              <button type="button" className="btn btn-ghost btn-small"
                                      onClick={() => setRenewing(pto)}>
                                Renew
                              </button>
                            )
                            : pto.renewal_pending
                            ? <span className="muted-note">Renewal requested</span>
                            : null}
                        </div>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        <p className="muted-note" style={{ marginTop: 16 }}>
          Residential and burial permissions are perpetual and are not renewed. Farming and
          business permissions run for a fixed term and can be renewed before or after they lapse.
        </p>
      </div>

      {renewing
        ? (
          <RenewalDialog
            pto={renewing}
            onClose={() => setRenewing(null)}
            onDone={async (message) => {
              setRenewing(null);
              setSuccess(message);
              await load();
            }}
          />
        )
        : null}
    </>
  );
}

// ---------------------------------------------------------------------

function ApplicationForm({
  landType, portal, onCancel, onDone,
}: {
  landType: LandType;
  portal: Portal;
  onCancel: () => void;
  onDone: (message: string) => void | Promise<void>;
}) {
  const [form, setForm] = useState<Record<string, string>>({
    reason_for_application: "", intended_use: "", farming_type: "", farming_activity: "",
    business_name: "", business_type: "", business_description: "",
  });
  const [livesWithHousehold, setLivesWithHousehold] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  const update = (key: string, value: string) => setForm((f) => ({ ...f, [key]: value }));

  async function handleSubmit(event: React.FormEvent) {
    event.preventDefault();
    setSubmitting(true);
    setError(null);

    const result = await submitLandApplication(landType, {
      ...form,
      lives_with_household: landType === "residential" ? livesWithHousehold : undefined,
    });
    setSubmitting(false);
    if (!result.ok) { setError(result.message); return; }
    await onDone(
      `Your ${LAND_TYPE_LABELS[landType].toLowerCase()} land application ` +
        `(${result.data.application_reference}) has been sent to the Land Officer.`,
    );
  }

  const eligibility = portal.eligibility[landType];

  return (
    <form onSubmit={handleSubmit} noValidate style={{ maxWidth: 760 }}>
      <div className="card">
        <h2 className="card-title">Apply for {LAND_TYPE_LABELS[landType].toLowerCase()} land</h2>
        <p className="muted-note" style={{ marginBottom: 18 }}>
          {LAND_TYPE_TERMS[landType]}. We already know who you are, your age and your household,
          so you do not need to tell us again — and you do not choose the site.
        </p>

        {error ? <Notice kind="error">{error}</Notice> : null}
        {!eligibility?.eligible
          ? (
            <Notice kind="error">
              {eligibility?.problems?.join(" ") ?? "You are not eligible for this kind of land."}
            </Notice>
          )
          : null}

        <div style={{ marginTop: 18 }}>
          <Field label="Why are you applying?" htmlFor="reason">
            <textarea id="reason" value={form.reason_for_application} maxLength={1000}
                      onChange={(e) => update("reason_for_application", e.target.value)} />
          </Field>
        </div>

        {landType === "residential"
          ? (
            <>
              <div style={{ marginTop: 16 }}>
                <Field label="What will the land be used for?" htmlFor="intended_use"
                       hint="For example: permanent residential home.">
                  <input id="intended_use" value={form.intended_use}
                         onChange={(e) => update("intended_use", e.target.value)} />
                </Field>
              </div>
              <label className="confirm-line">
                <input type="checkbox" checked={livesWithHousehold}
                       onChange={(e) => setLivesWithHousehold(e.target.checked)} />
                <span>I currently live with my household or family.</span>
              </label>
            </>
          )
          : null}

        {landType === "farming"
          ? (
            <>
              <div style={{ marginTop: 16 }}>
                <Field label="What kind of farming?" htmlFor="farming_type">
                  <select id="farming_type" value={form.farming_type}
                          onChange={(e) => update("farming_type", e.target.value)}>
                    <option value="">Choose…</option>
                    {FARMING_TYPES.map((t) => <option key={t.value} value={t.value}>{t.label}</option>)}
                  </select>
                </Field>
              </div>
              <div style={{ marginTop: 16 }}>
                <Field label="What will you farm?" htmlFor="farming_activity"
                       hint="A sentence is enough — no business plan is needed.">
                  <input id="farming_activity" value={form.farming_activity}
                         onChange={(e) => update("farming_activity", e.target.value)} />
                </Field>
              </div>
            </>
          )
          : null}

        {landType === "business"
          ? (
            <>
              <div className="form-grid" style={{ marginTop: 16 }}>
                <Field label="Business name" htmlFor="business_name" hint="Optional.">
                  <input id="business_name" value={form.business_name}
                         onChange={(e) => update("business_name", e.target.value)} />
                </Field>
                <Field label="Kind of business" htmlFor="business_type">
                  <select id="business_type" value={form.business_type}
                          onChange={(e) => update("business_type", e.target.value)}>
                    <option value="">Choose…</option>
                    {BUSINESS_TYPES.map((t) => <option key={t.value} value={t.value}>{t.label}</option>)}
                  </select>
                </Field>
              </div>
              <div style={{ marginTop: 16 }}>
                <Field label="What will the business do?" htmlFor="business_description"
                       hint="A short description — no business plan is needed.">
                  <textarea id="business_description" value={form.business_description}
                            onChange={(e) => update("business_description", e.target.value)} />
                </Field>
              </div>
            </>
          )
          : null}

        {landType === "burial"
          ? (
            <p className="muted-note" style={{ marginTop: 16 }}>
              A burial plot is allocated to your household. You will be given another only once
              every plot the household holds is full.
            </p>
          )
          : null}

        <div className="row" style={{ marginTop: 24 }}>
          <button type="submit" className="btn btn-primary"
                  disabled={submitting || !eligibility?.eligible || !form.reason_for_application.trim()}>
            {submitting ? "Sending…" : "Send application"}
          </button>
          <button type="button" className="btn btn-ghost" onClick={onCancel}>Cancel</button>
        </div>
      </div>
    </form>
  );
}

function RenewalDialog({
  pto, onClose, onDone,
}: {
  pto: PtoRow;
  onClose: () => void;
  onDone: (message: string) => void | Promise<void>;
}) {
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  async function submit() {
    setSubmitting(true);
    setError(null);
    const result = await requestPtoRenewal(pto.pto_id, reason);
    setSubmitting(false);
    if (!result.ok) { setError(result.message); return; }
    await onDone(`Your renewal request for ${pto.pto_number} has been sent to the Land Officer.`);
  }

  return (
    <div className="backdrop" role="dialog" aria-modal="true" aria-label="Request a renewal">
      <div className="dialog">
        <h2>Request a renewal</h2>
        <p className="dialog-intro">
          {pto.pto_number} runs out on {formatDate(pto.expiry_date)}. Renewing does not change
          the site: the Land Officer reviews the request and, if it is approved, a new permission
          is issued and this one is kept on record.
        </p>

        {error ? <Notice kind="error">{error}</Notice> : null}

        <div style={{ marginTop: 18 }}>
          <Field label="Anything the Land Officer should know?" htmlFor="renewal-reason" hint="Optional.">
            <textarea id="renewal-reason" value={reason} maxLength={500}
                      onChange={(event) => setReason(event.target.value)} />
          </Field>
        </div>

        <div className="dialog-actions">
          <button type="button" className="btn btn-ghost" onClick={onClose}>Cancel</button>
          <button type="button" className="btn btn-primary" disabled={submitting}
                  onClick={() => void submit()}>
            {submitting ? "Sending…" : "Request renewal"}
          </button>
        </div>
      </div>
    </div>
  );
}
