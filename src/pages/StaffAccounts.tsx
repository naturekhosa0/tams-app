import { useEffect, useMemo, useState } from "react";
import { Link } from "react-router-dom";
import { useSession } from "../auth/SessionProvider";
import { supabase } from "../lib/supabaseClient";
import { AppShell } from "../components/AppShell";
import { Field, Loading, Notice, StatusBadge } from "../components/ui";
import { formatDate } from "../lib/format";
import type { StaffAccountRow } from "../lib/types";

/**
 * Every staff member, their single current role, and whether they can
 * currently reach the system. Read only for now — changing a role and
 * deactivating an account are separate functions, not yet built.
 */
export function StaffAccounts() {
  const { profile } = useSession();
  const [rows, setRows] = useState<StaffAccountRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [search, setSearch] = useState("");
  const [roleFilter, setRoleFilter] = useState("all");
  const [statusFilter, setStatusFilter] = useState("all");

  useEffect(() => {
    let cancelled = false;
    // The list comes from a function that re-checks, in the database,
    // that the caller is the active Council Administrator.
    supabase.rpc("admin_staff_accounts").then(({ data, error: queryError }) => {
      if (cancelled) return;
      if (queryError) setError("The staff accounts could not be loaded.");
      else setRows((data ?? []) as StaffAccountRow[]);
    });
    return () => { cancelled = true; };
  }, []);

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

  return (
    <AppShell>
      <div className="page-head">
        <h1>Staff accounts</h1>
        <p>Every staff member, their single current role and whether they can currently access the system.</p>
      </div>

      {error ? <Notice kind="error">{error}</Notice> : null}

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
                  </tr>
                </thead>
                <tbody>
                  {visible.length === 0
                    ? (
                      <tr>
                        <td className="empty-row" colSpan={7}>No staff accounts match those filters.</td>
                      </tr>
                    )
                    : visible.map((row) => (
                      <tr key={row.account_id}>
                        <td>{row.employee_number}</td>
                        <td>
                          <span className="name">{row.first_name} {row.last_name}</span>
                          {row.staff_id === profile?.staff_id ? <span className="self"> (you)</span> : null}
                        </td>
                        <td>{row.email}</td>
                        <td>{row.contact_number}</td>
                        <td>{row.role_name}</td>
                        <td>
                          <StatusBadge status={row.account_status} />
                          {!row.invitation_completed
                            ? <div className="self">Invitation not completed</div>
                            : null}
                        </td>
                        <td>{formatDate(row.account_created_at)}</td>
                      </tr>
                    ))}
                </tbody>
              </table>
            </div>
          )
          : null}
      </div>
    </AppShell>
  );
}
