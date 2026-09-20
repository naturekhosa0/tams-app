import { useEffect, useState } from "react";
import { Field, Loading, Notice } from "../../components/ui";
import { availableResidentialSites, createHousehold, nextHouseholdCode } from "../../registry/api";
import type { AvailableSite } from "../../registry/types";

/**
 * Creating a household.
 *
 * The code is suggested by looking at what is actually in the database,
 * never assumed. The site must be a residential one that no current
 * household already lives on — and a Registry Clerk cannot create
 * sites, so only existing ones are offered.
 */
export function CreateHouseholdDialog({
  onClose,
  onDone,
}: {
  onClose: () => void;
  onDone: (message: string) => void | Promise<void>;
}) {
  const [code, setCode] = useState("");
  const [status, setStatus] = useState<"active" | "inactive">("active");
  const [sites, setSites] = useState<AvailableSite[] | null>(null);
  const [siteId, setSiteId] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    let cancelled = false;
    Promise.all([nextHouseholdCode(), availableResidentialSites()]).then(([suggested, available]) => {
      if (cancelled) return;
      if (suggested.ok) setCode(suggested.data);
      if (available.ok) setSites(available.data);
      else setError(available.message);
    });
    return () => { cancelled = true; };
  }, []);

  useEffect(() => {
    function onKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape") onClose();
    }
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [onClose]);

  async function handleSubmit(event: React.FormEvent) {
    event.preventDefault();
    setSubmitting(true);
    setError(null);

    const result = await createHousehold(code, siteId, status);
    setSubmitting(false);
    if (!result.ok) { setError(result.message); return; }
    await onDone(`Household ${result.data.household_code} was created. Link residents to it, then designate a head.`);
  }

  return (
    <div className="backdrop" role="dialog" aria-modal="true" aria-label="Create household">
      <div className="dialog">
        <h2>Create household</h2>
        <p className="dialog-intro">
          A household is identified by its code, not by a surname. It starts empty: link
          residents to it, then designate one of them as its head.
        </p>

        <form onSubmit={handleSubmit} noValidate>
          {error ? <div style={{ marginTop: 18 }}><Notice kind="error">{error}</Notice></div> : null}

          <div style={{ marginTop: 18 }}>
            <Field label="Household code" htmlFor="household-code"
                   hint="Suggested from the codes already in the database.">
              <input id="household-code" value={code} onChange={(event) => setCode(event.target.value)} />
            </Field>
          </div>

          <div style={{ marginTop: 16 }}>
            <Field label="Residential site" htmlFor="site"
                   hint="Only residential sites with no current household are listed. Registry Clerks cannot create sites.">
              {sites === null
                ? <Loading what="Loading sites" />
                : (
                  <select id="site" value={siteId} onChange={(event) => setSiteId(event.target.value)}>
                    <option value="">Choose a site…</option>
                    {sites.map((site) => (
                      <option key={site.site_id} value={site.site_id}>
                        {site.site_code} — {site.street_address}
                        {site.village_section ? `, ${site.village_section}` : ""}
                      </option>
                    ))}
                  </select>
                )}
            </Field>
          </div>

          {sites !== null && sites.length === 0
            ? (
              <div style={{ marginTop: 16 }}>
                <Notice kind="info">
                  Every residential site already has a current household on it. A new site has to
                  be added by the Land Officer before another household can be created.
                </Notice>
              </div>
            )
            : null}

          <div style={{ marginTop: 16 }}>
            <Field label="Household status" htmlFor="household-status">
              <select id="household-status" value={status}
                      onChange={(event) => setStatus(event.target.value as "active" | "inactive")}>
                <option value="active">Active</option>
                <option value="inactive">Inactive</option>
              </select>
            </Field>
          </div>

          <div className="dialog-actions">
            <button type="button" className="btn btn-ghost" onClick={onClose}>Cancel</button>
            <button type="submit" className="btn btn-primary" disabled={submitting || !siteId || !code}>
              {submitting ? "Creating…" : "Create household"}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}
