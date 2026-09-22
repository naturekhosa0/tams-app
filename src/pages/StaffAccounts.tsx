import { useCallback, useEffect, useMemo, useState } from "react";
import { Link } from "react-router-dom";
import { useSession } from "../auth/SessionProvider";
import { supabase } from "../lib/supabaseClient";
import { AppShell } from "../components/AppShell";
import { StaffActionDialog } from "../components/StaffActionDialog";
import { Field, Loading, Notice, StatusBadge } from "../components/ui";
import { formatDate } from "../lib/format";
import type { AssignableRole, StaffAccountRow, StaffAction } from "../lib/types";
import { PageHead } from "../components/PageHead";

/**
 * Every staff member, their single current role, and whether they can
 * currently reach the system.
 *
 * The actions shown here are a convenience. Which of them a person may
 * actually carry out is decided on the server every time, so hiding a
 * button is never what keeps an account safe.
 */
export function StaffAccounts() {
  const { profile } = useSession();
  const [rows, setRows] = useState<StaffAccountRow[] | null>(null);
  const [roles, setRoles] = useState<AssignableRole[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [search, setSearch] = useState("");
  const [roleFilter, setRoleFilter] = useState("all");
  const [statusFilter, setStatusFilter] = useState("all");
  const [openAction, setOpenAction] = useState<{ action: StaffAction; staff: StaffAccountRow } | null>(null);

  // The list comes from a function that re-checks, in the database, that
  // the caller is the active Council Administrator.
  const load = useCallback(async () => {
    const { data, error: queryError } = await supabase.rpc("admin_staff_accounts");
    if (queryError) setError("The staff accounts could not be loaded.");
    else {
      setError(null);
      setRows((data ?? []) as StaffAccountRow[]);
    }
  }, []);

  useEffect(() => {
    void load();
    // The assignable roles never include Council Administrator.
    supabase.rpc("assignable_staff_roles").then(({ data }) => {
      setRoles((data ?? []) as AssignableRole[]);
    });
  }, [load]);

  const roleNames = useMemo(
    () => [...new Set((rows ?? []).map((row) => row.role_name))].sort(),
    [rows],
  );

  const visible = useMemo(() => {
    const term = search.trim().toLowerCase();
    return (rows ?? []).filter((row) => {
      const matchesTerm = term === "" ||
        [row.employee_number, row.first_name, row.last_name, row.email]
          .some((value) => value.toLowerCase().includes(term));
      const matchesRole = roleFilter === "all" || row.role_name === roleFilter;
      const matchesStatus = statusFilter === "all" || row.account_status === statusFilter;
      return matchesTerm && matchesRole && matchesStatus;
    });
  }, [rows, search, roleFilter, statusFilter]);

  async function handleDone(message: string) {
    setOpenAction(null);
    setSuccess(message);
    // Straight back to the database, so the page shows what is now true.
    await load();
  }

  return (
    <AppShell>
      <PageHead
        title="Staff accounts"
        description="Every staff member, their role and whether they can sign in."
        crumbs={[{ label: "Dashboard", to: "/dashboard" }, { label: "Staff accounts" }]}
        actions={
          <>
            <Link to="/dashboard" className="btn btn-ghost">Back to dashboard</Link>
            <Link to="/staff/new" className="btn btn-primary">Create staff account</Link>
          </>
        }
      />

      {error ? <Notice kind="error">{error}</Notice> : null}
      {success
        ? (
          <div style={{ marginBottom: 18 }}>
            <Notice kind="success">{success}</Notice>
          </div>
        )
        : null}

      <div className="card">
        <div className="row-between" style={{ marginBottom: 20 }}>
          <h2 className="card-title" style={{ marginBottom: 0 }}>Find staff</h2>
          <Link to="/staff/new" className="btn btn-ghost">Create staff account</Link>
        </div>

        <div className="filters">
          <Field label="Search" htmlFor="search">
            <input
              id="search"
              type="search"
              placeholder="Employee number, first name, surname or email"
              value={search}
              onChange={(event) => setSearch(event.target.value)}
            />
          </Field>

          <Field label="Current role" htmlFor="role-filter">
            <select id="role-filter" value={roleFilter} onChange={(event) => setRoleFilter(event.target.value)}>
              <option value="all">All roles</option>
              {roleNames.map((name) => <option key={name} value={name}>{name}</option>)}
            </select>
          </Field>

          <Field label="Account status" htmlFor="status-filter">
            <select id="status-filter" value={statusFilter} onChange={(event) => setStatusFilter(event.target.value)}>
              <option value="all">All statuses</option>
              <option value="active">Active</option>
              <option value="deactivated">Deactivated</option>
            </select>
          </Field>
        </div>

        {rows === null && !error ? <Loading what="Loading staff accounts" /> : null}

        {rows !== null
          ? (
            <div className="table-wrap" style={{ marginTop: 24 }}>
              <table>
                <thead>
                  <tr>
                    <th>Employee no.</th>
                    <th>Name</th>
                    <th>Email</th>
                    <th>Contact</th>
                    <th>Current role</th>
                    <th>Account status</th>
                    <th>Created</th>
                    <th>Actions</th>
                  </tr>
                </thead>
                <tbody>
                  {visible.length === 0
                    ? (
                      <tr>
                        <td className="empty-row" colSpan={8}>No staff accounts match those filters.</td>
                      </tr>
                    )
                    : visible.map((row) => (
                      <tr key={row.account_id}>
                        <td className="no-wrap">{row.employee_number}</td>
                        <td>
                          <span className="name">{row.first_name} {row.last_name}</span>
                          {row.staff_id === profile?.staff_id ? <span className="self"> (you)</span> : null}
                        </td>
                        <td>{row.email}</td>
                        <td className="no-wrap">{row.contact_number}</td>
                        <td className="no-wrap">{row.role_name}</td>
                        <td>
                          <StatusBadge status={row.account_status} />
                          {row.account_status === "deactivated" && row.last_deactivated_at
                            ? (
                              <div className="status-note">
                                Deactivated {formatDate(row.last_deactivated_at)}
                                {row.last_deactivation_reason ? ` · ${row.last_deactivation_reason}` : ""}
                              </div>
                            )
                            : null}
                          {row.account_status === "active" && !row.invitation_completed
                            ? <div className="status-note">Invitation not completed</div>
                            : null}
                        </td>
                        <td className="no-wrap">{formatDate(row.account_created_at)}</td>
                        <td>
                          {/* The Council Administrator is not managed from this page. */}
                          {row.is_council_administrator
                            ? <span className="muted-note">Managed separately</span>
                            : (
                              <div className="row-actions">
                                {row.account_status === "active"
                                  ? (
                                    <>
                                      <button
                                        type="button"
                                        className="btn btn-ghost btn-small"
                                        onClick={() => setOpenAction({ action: "change_role", staff: row })}
                                      >
                                        Change role
                                      </button>
                                      <button
                                        type="button"
                                        className="btn btn-danger btn-small"
                                        onClick={() => setOpenAction({ action: "deactivate", staff: row })}
                                      >
                                        Deactivate
                                      </button>
                                    </>
                                  )
                                  : (
                                    <button
                                      type="button"
                                      className="btn btn-restore btn-small"
                                      onClick={() => setOpenAction({ action: "reactivate", staff: row })}
                                    >
                                      Reactivate
                                    </button>
                                  )}
                              </div>
                            )}
                        </td>
                      </tr>
                    ))}
                </tbody>
              </table>
            </div>
          )
          : null}
      </div>

      {openAction
        ? (
          <StaffActionDialog
            action={openAction.action}
            staff={openAction.staff}
            roles={roles}
            onClose={() => setOpenAction(null)}
            onDone={handleDone}
          />
        )
        : null}
    </AppShell>
  );
}
