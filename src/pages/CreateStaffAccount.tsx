import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { supabase, callEdgeFunction } from "../lib/supabaseClient";
import { AppShell } from "../components/AppShell";
import { Field, Notice } from "../components/ui";
import type { AssignableRole } from "../lib/types";
import { PageHead } from "../components/PageHead";

type CreatedStaff = {
  staff: { employee_number: string; email: string; role_name: string };
  message: string;
};

const EMPTY_FORM = {
  employee_number: "",
  first_name: "",
  last_name: "",
  email: "",
  contact_number: "",
  role_id: "",
};

/**
 * Create Staff Account.
 *
 * The form is only the convenient half. The request goes to the
 * create-staff-account edge function, which re-checks on the server that
 * the caller is the active Council Administrator and that the chosen
 * role is one that may be handed out.
 */
export function CreateStaffAccount() {
  const [form, setForm] = useState(EMPTY_FORM);
  const [roles, setRoles] = useState<AssignableRole[]>([]);
  const [rolesError, setRolesError] = useState<string | null>(null);
  const [fieldErrors, setFieldErrors] = useState<Record<string, string>>({});
  const [formError, setFormError] = useState<string | null>(null);
  const [success, setSuccess] = useState<CreatedStaff | null>(null);
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    let cancelled = false;
    // The list comes from the database and never contains the Council
    // Administrator role.
    supabase.rpc("assignable_staff_roles").then(({ data, error }) => {
      if (cancelled) return;
      if (error) setRolesError("The list of roles could not be loaded.");
      else setRoles((data ?? []) as AssignableRole[]);
    });
    return () => { cancelled = true; };
  }, []);

  function update(key: keyof typeof EMPTY_FORM, value: string) {
    setForm((current) => ({ ...current, [key]: value }));
    setFieldErrors((current) => {
      if (!current[key]) return current;
      const next = { ...current };
      delete next[key];
      return next;
    });
  }

  async function handleSubmit(event: React.FormEvent) {
    event.preventDefault();
    setFormError(null);
    setFieldErrors({});
    setSuccess(null);
    setSubmitting(true);

    const result = await callEdgeFunction<CreatedStaff>("create-staff-account", form);
    setSubmitting(false);

    if (!result.ok) {
      setFormError(result.message ?? "The staff account could not be created.");
      setFieldErrors(result.fields ?? {});
      return;
    }

    setSuccess(result.data!);
    setForm(EMPTY_FORM);
  }

  return (
    <AppShell>
      <PageHead
        title="Create staff account"
        description="The staff member is invited by email and chooses their own password."
        crumbs={[
          { label: "Dashboard", to: "/dashboard" },
          { label: "Staff accounts", to: "/staff" },
          { label: "Create staff account" },
        ]}
        back={{ to: "/staff", label: "Back to staff accounts" }}
      />

      {success
        ? (
          <div className="card" style={{ maxWidth: 780 }}>
            <Notice kind="success">
              <strong>{success.staff.employee_number}</strong> — {success.staff.role_name} account
              created. {success.message}
            </Notice>
            <div className="row" style={{ marginTop: 22 }}>
              <button type="button" className="btn btn-primary" onClick={() => setSuccess(null)}>
                Create another staff account
              </button>
              <Link to="/staff" className="btn btn-ghost">View staff accounts</Link>
            </div>
          </div>
        )
        : (
          <div className="card" style={{ maxWidth: 780 }}>
            <h2 className="card-title">Staff details</h2>

            {formError ? <Notice kind="error">{formError}</Notice> : null}
            {rolesError ? <Notice kind="error">{rolesError}</Notice> : null}

            <form onSubmit={handleSubmit} noValidate style={{ marginTop: formError || rolesError ? 20 : 0 }}>
              <div className="form-grid">
                <Field label="Employee number" htmlFor="employee_number" error={fieldErrors.employee_number}>
                  <input
                    id="employee_number"
                    value={form.employee_number}
                    onChange={(event) => update("employee_number", event.target.value)}
                  />
                </Field>

                <Field label="Email address" htmlFor="email" error={fieldErrors.email}>
                  <input
                    id="email"
                    type="email"
                    value={form.email}
                    onChange={(event) => update("email", event.target.value)}
                  />
                </Field>

                <Field label="First name" htmlFor="first_name" error={fieldErrors.first_name}>
                  <input
                    id="first_name"
                    value={form.first_name}
                    onChange={(event) => update("first_name", event.target.value)}
                  />
                </Field>

                <Field label="Surname" htmlFor="last_name" error={fieldErrors.last_name}>
                  <input
                    id="last_name"
                    value={form.last_name}
                    onChange={(event) => update("last_name", event.target.value)}
                  />
                </Field>

                <Field label="Contact number" htmlFor="contact_number" error={fieldErrors.contact_number}>
                  <input
                    id="contact_number"
                    value={form.contact_number}
                    onChange={(event) => update("contact_number", event.target.value)}
                  />
                </Field>

                <Field
                  label="Staff role"
                  htmlFor="role_id"
                  error={fieldErrors.role_id}
                  hint="A staff member holds exactly one role."
                >
                  <select
                    id="role_id"
                    value={form.role_id}
                    onChange={(event) => update("role_id", event.target.value)}
                  >
                    <option value="">Choose a role…</option>
                    {roles.map((role) => (
                      <option key={role.id} value={role.id}>{role.role_name}</option>
                    ))}
                  </select>
                </Field>
              </div>

              <div className="form-actions">
                <button type="submit" className="btn btn-primary" disabled={submitting}>
                  {submitting ? "Creating…" : "Create staff account"}
                </button>
              </div>
            </form>
          </div>
        )}
    </AppShell>
  );
}
