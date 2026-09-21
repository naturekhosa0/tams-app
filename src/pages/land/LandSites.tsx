import { useCallback, useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { AppShell } from "../../components/AppShell";
import { Field, Loading, Notice } from "../../components/ui";
import { officerSites, registerSite, setBurialStatus, updateSite } from "../../registry/landApi";
import { LAND_TYPES, LAND_TYPE_LABELS } from "../../registry/landTypes";
import type { LandType, OfficerSiteRow } from "../../registry/landTypes";

const SITE_STATUSES = [
  { value: "available", label: "Available" },
  { value: "allocated", label: "Allocated" },
  { value: "unavailable", label: "Unavailable" },
];

const BURIAL_STATUSES = [
  { value: "usable", label: "Usable" },
  { value: "full", label: "Full" },
  { value: "closed", label: "Closed" },
];

const emptyForm = {
  site_code: "", site_type: "residential" as LandType, street_address: "",
  stand_number: "", village_section: "", village_name: "",
};

/** The register of land itself: every site, and what may be done with it. */
export function LandSites() {
  const [rows, setRows] = useState<OfficerSiteRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [search, setSearch] = useState("");
  const [applied, setApplied] = useState("");
  const [siteType, setSiteType] = useState("");
  const [registering, setRegistering] = useState(false);
  const [editing, setEditing] = useState<OfficerSiteRow | null>(null);

  const load = useCallback(async () => {
    const result = await officerSites(applied, siteType);
    if (result.ok) { setRows(result.data); setError(null); }
    else { setRows([]); setError(result.message); }
  }, [applied, siteType]);

  useEffect(() => { void load(); }, [load]);

  return (
    <AppShell>
      <div className="page-head row-between">
        <div>
          <h1>Land sites</h1>
          <p>
            Every site TAMS knows about. A site has one kind of land, and only an available site
            can be allocated.
          </p>
        </div>
        <button type="button" className="btn btn-primary" onClick={() => setRegistering(true)}>
          Register a site
        </button>
      </div>

      {error ? <Notice kind="error">{error}</Notice> : null}
      {success ? <div style={{ marginBottom: 18 }}><Notice kind="success">{success}</Notice></div> : null}

      <div className="card">
        <form className="filters" onSubmit={(event) => { event.preventDefault(); setApplied(search.trim()); }}>
          <Field label="Search" htmlFor="q" hint="Site code, stand number or address.">
            <input id="q" value={search} onChange={(event) => setSearch(event.target.value)} />
          </Field>
          <Field label="Land type" htmlFor="type">
            <select id="type" value={siteType} onChange={(event) => setSiteType(event.target.value)}>
              <option value="">All</option>
              {LAND_TYPES.map((type) => (
                <option key={type} value={type}>{LAND_TYPE_LABELS[type]}</option>
              ))}
            </select>
          </Field>
          <div className="form-actions">
            <button type="submit" className="btn btn-ghost">Search</button>
          </div>
        </form>
      </div>

      {rows === null && !error ? <Loading what="Loading sites" /> : null}

      {rows !== null
        ? (
          <div className="card">
            <h2 className="card-title">{rows.length} site{rows.length === 1 ? "" : "s"}</h2>
            <div className="table-wrap">
              <table>
                <thead>
                  <tr>
                    <th>Site code</th><th>Type</th><th>Address</th><th>Status</th>
                    <th>Held by</th><th>History</th><th>Actions</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.length === 0
                    ? <tr><td className="empty-row" colSpan={7}>No sites match.</td></tr>
                    : rows.map((row) => (
                      <tr key={row.site_id}>
                        <td className="no-wrap">
                          <span className="name">{row.site_code}</span>
                          {row.stand_number ? <div className="status-note">Stand {row.stand_number}</div> : null}
                        </td>
                        <td className="no-wrap">
                          {LAND_TYPE_LABELS[row.site_type] ?? row.site_type}
                          {row.site_type === "burial" && row.burial_status
                            ? <div className="status-note">Plot is {row.burial_status}</div>
                            : null}
                        </td>
                        <td>
                          {row.street_address}
                          {row.village_section ? <div className="status-note">{row.village_section}</div> : null}
                        </td>
                        <td>
                          <span className={`badge ${row.site_status === "available" ? "badge-active" : "badge-deactivated"}`}>
                            {row.site_status}
                          </span>
                        </td>
                        <td>{row.current_holder ?? "—"}</td>
                        <td className="no-wrap">
                          <Link to={`/land/sites/${row.site_id}`}>
                            {row.allocation_count} allocation{Number(row.allocation_count) === 1 ? "" : "s"}
                          </Link>
                        </td>
                        <td>
                          <div className="row-actions">
                            <button type="button" className="btn btn-ghost btn-small"
                                    onClick={() => setEditing(row)}>
                              Edit
                            </button>
                          </div>
                        </td>
                      </tr>
                    ))}
                </tbody>
              </table>
            </div>
            <p className="muted-note" style={{ marginTop: 16 }}>
              TAMS allocates residential, farming, business and burial land. Grazing land is not
              allocated and no permission to occupy is issued for it.
            </p>
          </div>
        )
        : null}

      {registering
        ? (
          <RegisterDialog
            onClose={() => setRegistering(false)}
            onDone={async (message) => {
              setRegistering(false);
              setSuccess(message);
              await load();
            }}
          />
        )
        : null}

      {editing
        ? (
          <EditDialog
            site={editing}
            onClose={() => setEditing(null)}
            onDone={async (message) => {
              setEditing(null);
              setSuccess(message);
              await load();
            }}
          />
        )
        : null}
    </AppShell>
  );
}

// ---------------------------------------------------------------------

function RegisterDialog({
  onClose, onDone,
}: { onClose: () => void; onDone: (message: string) => void | Promise<void> }) {
  const [form, setForm] = useState(emptyForm);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const update = (key: keyof typeof emptyForm, value: string) =>
    setForm((current) => ({ ...current, [key]: value }));

  return (
    <div className="backdrop" role="dialog" aria-modal="true" aria-label="Register a land site">
      <div className="dialog">
        <h2>Register a land site</h2>
        <p className="dialog-intro">
          A new site starts out available. A burial plot starts out usable.
        </p>

        {error ? <Notice kind="error">{error}</Notice> : null}

        <div className="form-grid" style={{ marginTop: 18 }}>
          <Field label="Site code" htmlFor="site_code" hint="For example RES-0101.">
            <input id="site_code" value={form.site_code}
                   onChange={(event) => update("site_code", event.target.value)} />
          </Field>
          <Field label="Land type" htmlFor="site_type">
            <select id="site_type" value={form.site_type}
                    onChange={(event) => update("site_type", event.target.value)}>
              {LAND_TYPES.map((type) => (
                <option key={type} value={type}>{LAND_TYPE_LABELS[type]}</option>
              ))}
            </select>
          </Field>
        </div>
        <div style={{ marginTop: 16 }}>
          <Field label="Street address" htmlFor="street_address">
            <input id="street_address" value={form.street_address}
                   onChange={(event) => update("street_address", event.target.value)} />
          </Field>
        </div>
        <div className="form-grid" style={{ marginTop: 16 }}>
          <Field label="Stand number" htmlFor="stand_number" hint="Optional.">
            <input id="stand_number" value={form.stand_number}
                   onChange={(event) => update("stand_number", event.target.value)} />
          </Field>
          <Field label="Village section" htmlFor="village_section" hint="Optional.">
            <input id="village_section" value={form.village_section}
                   onChange={(event) => update("village_section", event.target.value)} />
          </Field>
        </div>
        <div style={{ marginTop: 16 }}>
          <Field label="Village" htmlFor="village_name" hint="Optional.">
            <input id="village_name" value={form.village_name}
                   onChange={(event) => update("village_name", event.target.value)} />
          </Field>
        </div>

        <div className="dialog-actions">
          <button type="button" className="btn btn-ghost" onClick={onClose}>Cancel</button>
          <button type="button" className="btn btn-primary"
                  disabled={busy || !form.site_code.trim() || !form.street_address.trim()}
                  onClick={async () => {
                    setBusy(true);
                    setError(null);
                    const result = await registerSite(form);
                    setBusy(false);
                    if (!result.ok) { setError(result.message); return; }
                    await onDone(`Site ${result.data.site_code} has been registered.`);
                  }}>
            {busy ? "Saving…" : "Register the site"}
          </button>
        </div>
      </div>
    </div>
  );
}

function EditDialog({
  site, onClose, onDone,
}: { site: OfficerSiteRow; onClose: () => void; onDone: (message: string) => void | Promise<void> }) {
  const [form, setForm] = useState({
    site_type: site.site_type,
    street_address: site.street_address,
    stand_number: site.stand_number ?? "",
    village_section: site.village_section ?? "",
    village_name: site.village_name ?? "",
    site_status: site.site_status,
  });
  const [burial, setBurial] = useState(site.burial_status ?? "usable");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const update = (key: keyof typeof form, value: string) =>
    setForm((current) => ({ ...current, [key]: value }));

  return (
    <div className="backdrop" role="dialog" aria-modal="true" aria-label={`Edit ${site.site_code}`}>
      <div className="dialog">
        <h2>{site.site_code}</h2>
        <p className="dialog-intro">
          A site that is allocated stays allocated: release the allocation rather than editing the
          status here. Its land type can only be changed while it has never been allocated.
        </p>

        {error ? <Notice kind="error">{error}</Notice> : null}

        <div className="form-grid" style={{ marginTop: 18 }}>
          <Field label="Land type" htmlFor="edit_type">
            <select id="edit_type" value={form.site_type}
                    onChange={(event) => update("site_type", event.target.value)}>
              {LAND_TYPES.map((type) => (
                <option key={type} value={type}>{LAND_TYPE_LABELS[type]}</option>
              ))}
            </select>
          </Field>
          <Field label="Status" htmlFor="edit_status">
            <select id="edit_status" value={form.site_status}
                    onChange={(event) => update("site_status", event.target.value)}>
              {SITE_STATUSES.map((option) => (
                <option key={option.value} value={option.value}>{option.label}</option>
              ))}
            </select>
          </Field>
        </div>
        <div style={{ marginTop: 16 }}>
          <Field label="Street address" htmlFor="edit_address">
            <input id="edit_address" value={form.street_address}
                   onChange={(event) => update("street_address", event.target.value)} />
          </Field>
        </div>
        <div className="form-grid" style={{ marginTop: 16 }}>
          <Field label="Stand number" htmlFor="edit_stand">
            <input id="edit_stand" value={form.stand_number}
                   onChange={(event) => update("stand_number", event.target.value)} />
          </Field>
          <Field label="Village section" htmlFor="edit_section">
            <input id="edit_section" value={form.village_section}
                   onChange={(event) => update("village_section", event.target.value)} />
          </Field>
        </div>
        <div style={{ marginTop: 16 }}>
          <Field label="Village" htmlFor="edit_village">
            <input id="edit_village" value={form.village_name}
                   onChange={(event) => update("village_name", event.target.value)} />
          </Field>
        </div>

        {form.site_type === "burial"
          ? (
            <div style={{ marginTop: 16 }}>
              <Field label="Burial plot" htmlFor="edit_burial"
                     hint="A full or closed plot is never allocated again, and the household keeps it.">
                <select id="edit_burial" value={burial}
                        onChange={(event) => setBurial(event.target.value)}>
                  {BURIAL_STATUSES.map((option) => (
                    <option key={option.value} value={option.value}>{option.label}</option>
                  ))}
                </select>
              </Field>
            </div>
          )
          : null}

        <div className="dialog-actions">
          <button type="button" className="btn btn-ghost" onClick={onClose}>Cancel</button>
          <button type="button" className="btn btn-primary"
                  disabled={busy || !form.street_address.trim()}
                  onClick={async () => {
                    setBusy(true);
                    setError(null);
                    const result = await updateSite(site.site_id, form);
                    if (!result.ok) { setBusy(false); setError(result.message); return; }

                    if (form.site_type === "burial" && burial !== (site.burial_status ?? "usable")) {
                      const burialResult = await setBurialStatus(
                        site.site_id, burial as "usable" | "full" | "closed");
                      if (!burialResult.ok) { setBusy(false); setError(burialResult.message); return; }
                    }
                    setBusy(false);
                    await onDone(`Site ${site.site_code} has been updated.`);
                  }}>
            {busy ? "Saving…" : "Save changes"}
          </button>
        </div>
      </div>
    </div>
  );
}
