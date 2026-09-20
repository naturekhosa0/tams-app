import { useEffect, useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { AppShell } from "../../components/AppShell";
import { Field, Loading, Notice } from "../../components/ui";
import { createResident, residentRecord, updateResident } from "../../registry/api";
import type { ResidentDetails } from "../../registry/api";
import type { ResidentStatus } from "../../registry/types";

const EMPTY: ResidentDetails = {
  id_number: "", first_name: "", last_name: "", date_of_birth: "",
  gender: "", resident_status: "active", contact_number: "", email: "",
};

/**
 * Create or update a resident record.
 *
 * This is the village's record of a person, not a sign-in account: no
 * Supabase Auth user and no user account is created here. Household
 * membership is not set from this form either — that has its own rules,
 * and its own function.
 */
export function ResidentForm({ mode }: { mode: "create" | "update" }) {
  const { residentId = "" } = useParams();
  const navigate = useNavigate();

  const [form, setForm] = useState<ResidentDetails>(EMPTY);
  const [loading, setLoading] = useState(mode === "update");
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    if (mode !== "update") return;
    let cancelled = false;
    residentRecord(residentId).then((result) => {
      if (cancelled) return;
      if (!result.ok) { setError(result.message); setLoading(false); return; }
      const record = result.data;
      setForm({
        id_number: record.id_number,
        first_name: record.first_name,
        last_name: record.last_name,
        date_of_birth: record.date_of_birth,
        gender: record.gender,
        resident_status: record.resident_status,
        contact_number: record.contact_number ?? "",
        email: record.email ?? "",
      });
      setLoading(false);
    });
    return () => { cancelled = true; };
  }, [mode, residentId]);

  function update(key: keyof ResidentDetails, value: string) {
    setForm((current) => ({ ...current, [key]: value }));
  }

  async function handleSubmit(event: React.FormEvent) {
    event.preventDefault();
    setSubmitting(true);
    setError(null);

    const result = mode === "create"
      ? await createResident(form)
      : await updateResident(residentId, form);

    setSubmitting(false);
    if (!result.ok) { setError(result.message); return; }
    navigate(`/registry/residents/${result.data.resident_id}`, { replace: true });
  }

  if (loading) return <AppShell><Loading what="Loading the resident record" /></AppShell>;

  return (
    <AppShell>
      <div className="page-head">
        <h1>{mode === "create" ? "Create resident" : "Update resident"}</h1>
        <p>
          {mode === "create"
            ? "The official village record of a person. This does not create a sign-in account."
            : "Corrections to the record. The resident keeps the same record and the same history."}
        </p>
      </div>

      <div className="card" style={{ maxWidth: 820 }}>
        <h2 className="card-title">Resident details</h2>
        {error ? <Notice kind="error">{error}</Notice> : null}

        <form onSubmit={handleSubmit} noValidate style={{ marginTop: error ? 20 : 0 }}>
          <div className="form-grid">
            <Field label="ID number" htmlFor="id_number">
              <input id="id_number" value={form.id_number} onChange={(e) => update("id_number", e.target.value)} />
            </Field>
            <Field label="Date of birth" htmlFor="date_of_birth">
              <input id="date_of_birth" type="date" value={form.date_of_birth}
                     onChange={(e) => update("date_of_birth", e.target.value)} />
            </Field>
            <Field label="First name" htmlFor="first_name">
              <input id="first_name" value={form.first_name} onChange={(e) => update("first_name", e.target.value)} />
            </Field>
            <Field label="Surname" htmlFor="last_name">
              <input id="last_name" value={form.last_name} onChange={(e) => update("last_name", e.target.value)} />
            </Field>
            <Field label="Gender" htmlFor="gender">
              <input id="gender" value={form.gender} onChange={(e) => update("gender", e.target.value)} />
            </Field>
            <Field label="Resident status" htmlFor="resident_status"
                   hint="Records are never deleted. A person who has died is recorded as deceased.">
              <select id="resident_status" value={form.resident_status}
                      onChange={(e) => update("resident_status", e.target.value as ResidentStatus)}>
                <option value="active">Active</option>
                <option value="inactive">Inactive</option>
                <option value="deceased">Deceased</option>
              </select>
            </Field>
            <Field label="Contact number" htmlFor="contact_number" hint="Optional.">
              <input id="contact_number" value={form.contact_number}
                     onChange={(e) => update("contact_number", e.target.value)} />
            </Field>
            <Field label="Email address" htmlFor="email" hint="Optional.">
              <input id="email" type="email" value={form.email} onChange={(e) => update("email", e.target.value)} />
            </Field>
          </div>

          <div className="form-actions row">
            <button type="submit" className="btn btn-primary" disabled={submitting}>
              {submitting ? "Saving…" : mode === "create" ? "Create resident" : "Save changes"}
            </button>
            <Link
              to={mode === "create" ? "/registry/residents" : `/registry/residents/${residentId}`}
              className="btn btn-ghost"
            >
              Cancel
            </Link>
          </div>

          {mode === "create"
            ? (
              <p className="muted-note" style={{ marginTop: 18 }}>
                Link the resident to a household from their record once it exists.
              </p>
            )
            : null}
        </form>
      </div>
    </AppShell>
  );
}
