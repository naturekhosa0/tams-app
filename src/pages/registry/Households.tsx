import { useCallback, useEffect, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { AppShell } from "../../components/AppShell";
import { Field, Loading, Notice, StatusBadge } from "../../components/ui";
import { CreateHouseholdDialog } from "./CreateHouseholdDialog";
import { searchHouseholds } from "../../registry/api";
import type { HouseholdSearchRow } from "../../registry/types";
import { PageHead } from "../../components/PageHead";

/** Households, identified by their code — never by surname. */
export function Households() {
  const navigate = useNavigate();
  const [search, setSearch] = useState("");
  const [rows, setRows] = useState<HouseholdSearchRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [creating, setCreating] = useState(false);

  const load = useCallback(async (term: string) => {
    const result = await searchHouseholds(term);
    if (result.ok) { setRows(result.data); setError(null); }
    else setError(result.message);
  }, []);

  useEffect(() => {
    const timer = window.setTimeout(() => void load(search), 250);
    return () => window.clearTimeout(timer);
  }, [search, load]);

  return (
    <AppShell>
      <PageHead
        title="Households"
        description="Each household is identified by its household code and lives on one residential site. Households may share a surname — the code is what tells them apart."
        crumbs={[{ label: "Dashboard", to: "/registry" }, { label: "Households" }]}
        actions={
          <>
            <Link to="/registry" className="btn btn-ghost">Back to dashboard</Link>
            <button type="button" className="btn btn-primary" onClick={() => setCreating(true)}>
              Create household
            </button>
          </>
        }
      />

      {error ? <Notice kind="error">{error}</Notice> : null}
      {success ? <div style={{ marginBottom: 18 }}><Notice kind="success">{success}</Notice></div> : null}

      <div className="card">
        <div className="filters">
          <Field label="Search" htmlFor="household-search">
            <input
              id="household-search"
              type="search"
              placeholder="Household code, site code, address or a member's name"
              value={search}
              onChange={(event) => setSearch(event.target.value)}
            />
          </Field>
        </div>

        {rows === null && !error ? <Loading what="Loading households" /> : null}

        {rows !== null
          ? (
            <div className="table-wrap" style={{ marginTop: 24 }}>
              <table>
                <thead>
                  <tr>
                    <th>Household</th>
                    <th>Site</th>
                    <th>Stand</th>
                    <th>Address</th>
                    <th>Section</th>
                    <th>Head of household</th>
                    <th>Members</th>
                    <th>Status</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.length === 0
                    ? <tr><td className="empty-row" colSpan={8}>No households match that search.</td></tr>
                    : rows.map((row) => (
                      <tr
                        key={row.household_id}
                        onClick={() => navigate(`/registry/households/${row.household_id}`)}
                        style={{ cursor: "pointer" }}
                      >
                        <td className="no-wrap"><span className="name">{row.household_code}</span></td>
                        <td className="no-wrap">{row.site_code}</td>
                        <td className="no-wrap">{row.stand_number ?? "—"}</td>
                        <td>{row.street_address}</td>
                        <td className="no-wrap">{row.village_section ?? "—"}</td>
                        <td>{row.head_full_name ?? <span className="muted-note">Not designated</span>}</td>
                        <td>{row.member_count}</td>
                        <td><StatusBadge status={row.household_status === "active" ? "active" : "deactivated"} /></td>
                      </tr>
                    ))}
                </tbody>
              </table>
            </div>
          )
          : null}
      </div>

      {creating
        ? (
          <CreateHouseholdDialog
            onClose={() => setCreating(false)}
            onDone={async (message: string) => {
              setCreating(false);
              setSuccess(message);
              await load(search);
            }}
          />
        )
        : null}
    </AppShell>
  );
}
