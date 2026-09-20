import { useCallback, useEffect, useMemo, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { AppShell } from "../../components/AppShell";
import { Field, Loading, Notice } from "../../components/ui";
import { ResidentStatusBadge } from "./bits";
import { formatDate } from "../../lib/format";
import { searchResidents } from "../../registry/api";
import type { ResidentSearchRow } from "../../registry/types";

/** Search and view the village register. */
export function Residents() {
  const navigate = useNavigate();
  const [search, setSearch] = useState("");
  const [rows, setRows] = useState<ResidentSearchRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [statusFilter, setStatusFilter] = useState("all");

  const load = useCallback(async (term: string) => {
    const result = await searchResidents(term);
    if (result.ok) {
      setRows(result.data);
      setError(null);
    } else {
      setError(result.message);
    }
  }, []);

  useEffect(() => {
    // The search runs in the database; wait for a pause in typing.
    const timer = window.setTimeout(() => void load(search), 250);
    return () => window.clearTimeout(timer);
  }, [search, load]);

  const visible = useMemo(
    () => (rows ?? []).filter((row) => statusFilter === "all" || row.resident_status === statusFilter),
    [rows, statusFilter],
  );

  return (
    <AppShell>
      <div className="page-head row-between">
        <div>
          <h1>Residents</h1>
          <p>Everyone on the village register, with their household and where they live.</p>
        </div>
        <Link to="/registry/residents/new" className="btn btn-primary">Create resident</Link>
      </div>

      {error ? <Notice kind="error">{error}</Notice> : null}

      <div className="card">
        <div className="filters">
          <Field label="Search" htmlFor="search">
            <input
              id="search"
              type="search"
              placeholder="Identity number, name, household code, site code or address"
              value={search}
              onChange={(event) => setSearch(event.target.value)}
            />
          </Field>
          <Field label="Resident status" htmlFor="status">
            <select id="status" value={statusFilter} onChange={(event) => setStatusFilter(event.target.value)}>
              <option value="all">All statuses</option>
              <option value="active">Active</option>
              <option value="inactive">Inactive</option>
              <option value="deceased">Deceased</option>
            </select>
          </Field>
          <div className="field">
            <label>&nbsp;</label>
            <div className="muted-note">
              {rows === null ? "" : `${visible.length} resident${visible.length === 1 ? "" : "s"}`}
            </div>
          </div>
        </div>

        {rows === null && !error ? <Loading what="Searching the register" /> : null}

        {rows !== null
          ? (
            <div className="table-wrap" style={{ marginTop: 24 }}>
              <table>
                <thead>
                  <tr>
                    <th>ID number</th>
                    <th>Name</th>
                    <th>Date of birth</th>
                    <th>Gender</th>
                    <th>Contact</th>
                    <th>Household</th>
                    <th>Site / address</th>
                    <th>Status</th>
                  </tr>
                </thead>
                <tbody>
                  {visible.length === 0
                    ? <tr><td className="empty-row" colSpan={8}>No residents match that search.</td></tr>
                    : visible.map((row) => (
                      <tr
                        key={row.resident_id}
                        onClick={() => navigate(`/registry/residents/${row.resident_id}`)}
                        style={{ cursor: "pointer" }}
                      >
                        <td className="no-wrap">{row.id_number}</td>
                        <td>
                          <span className="name">{row.full_name}</span>
                          {row.is_household_head ? <div className="status-note">Head of household</div> : null}
                        </td>
                        <td className="no-wrap">{formatDate(row.date_of_birth)}</td>
                        <td>{row.gender}</td>
                        <td className="no-wrap">{row.contact_number ?? "—"}</td>
                        <td className="no-wrap">{row.household_code ?? "—"}</td>
                        <td>
                          {row.site_code ? <div className="no-wrap">{row.site_code}</div> : "—"}
                          {row.street_address ? <div className="status-note">{row.street_address}</div> : null}
                        </td>
                        <td><ResidentStatusBadge status={row.resident_status} /></td>
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
