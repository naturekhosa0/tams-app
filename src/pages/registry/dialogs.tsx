import { useEffect, useState } from "react";
import { Field, Loading, Notice } from "../../components/ui";
import {
  designateHouseholdHead, linkResidentToHousehold, NEEDS_CONFIRMATION,
  recordFamilyRelationship, searchHouseholds, searchResidents,
} from "../../registry/api";
import { RELATIONSHIP_TYPES } from "../../registry/types";
import type {
  HouseholdMember, HouseholdSearchRow, RelationshipType, ResidentSearchRow,
} from "../../registry/types";

/** The frame every registry dialog uses. */
function Dialog({
  title,
  intro,
  children,
  onClose,
}: {
  title: string;
  intro: string;
  children: React.ReactNode;
  onClose: () => void;
}) {
  useEffect(() => {
    function onKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape") onClose();
    }
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [onClose]);

  return (
    <div className="backdrop" role="dialog" aria-modal="true" aria-label={title}>
      <div className="dialog">
        <h2>{title}</h2>
        <p className="dialog-intro">{intro}</p>
        {children}
      </div>
    </div>
  );
}

/**
 * Linking a resident to a household.
 *
 * A resident belongs to one household, so linking someone who already
 * has one moves them. The database refuses that until it is confirmed;
 * this catches the refusal and asks, rather than deciding for itself.
 */
export function LinkHouseholdDialog({
  resident,
  onClose,
  onDone,
}: {
  resident: { resident_id: string; full_name: string; household_code: string | null };
  onClose: () => void;
  onDone: (message: string) => void | Promise<void>;
}) {
  const [search, setSearch] = useState("");
  const [households, setHouseholds] = useState<HouseholdSearchRow[] | null>(null);
  const [chosen, setChosen] = useState<HouseholdSearchRow | null>(null);
  const [confirmation, setConfirmation] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    const timer = window.setTimeout(async () => {
      const result = await searchHouseholds(search);
      if (result.ok) setHouseholds(result.data.filter((row) => row.household_status === "active"));
    }, 250);
    return () => window.clearTimeout(timer);
  }, [search]);

  async function submit(confirmed: boolean) {
    if (!chosen) return;
    setSubmitting(true);
    setError(null);

    const result = await linkResidentToHousehold(resident.resident_id, chosen.household_id, confirmed);
    setSubmitting(false);

    if (result.ok) {
      await onDone(
        result.data.moved_from
          ? `${resident.full_name} was moved from ${result.data.moved_from} to ${result.data.household_code}.`
          : `${resident.full_name} was linked to ${result.data.household_code}.`,
      );
      return;
    }

    // The database asking for confirmation, not an error to report.
    if (result.code === NEEDS_CONFIRMATION.reassignHousehold && !confirmed && resident.household_code) {
      setConfirmation(result.message);
      return;
    }
    setError(result.message);
  }

  return (
    <Dialog
      title={resident.household_code ? "Move to another household" : "Link to a household"}
      intro={resident.household_code
        ? `${resident.full_name} currently belongs to ${resident.household_code}. A resident belongs to one household at a time, so this moves them.`
        : `${resident.full_name} is not linked to a household yet.`}
      onClose={onClose}
    >
      {error ? <Notice kind="error">{error}</Notice> : null}

      {confirmation
        ? (
          <>
            <div style={{ margin: "18px 0" }}>
              <Notice kind="error">{confirmation}</Notice>
            </div>
            <div className="dialog-actions">
              <button type="button" className="btn btn-ghost" onClick={() => setConfirmation(null)}>
                Go back
              </button>
              <button
                type="button"
                className="btn btn-primary"
                disabled={submitting}
                onClick={() => void submit(true)}
              >
                {submitting ? "Moving…" : `Move to ${chosen?.household_code}`}
              </button>
            </div>
          </>
        )
        : (
          <>
            <div style={{ marginTop: 18 }}>
              <Field label="Find a household" htmlFor="household-search">
                <input
                  id="household-search"
                  type="search"
                  placeholder="Household code, site code or address"
                  value={search}
                  onChange={(event) => setSearch(event.target.value)}
                />
              </Field>
            </div>

            <div className="picker">
              {households === null
                ? <Loading what="Loading households" />
                : households.length === 0
                ? <p className="muted-note">No current households match that search.</p>
                : households.slice(0, 40).map((row) => (
                  <button
                    type="button"
                    key={row.household_id}
                    className={`picker-row${chosen?.household_id === row.household_id ? " chosen" : ""}`}
                    onClick={() => setChosen(row)}
                  >
                    <span className="name">{row.household_code}</span>
                    <span className="status-note">
                      {row.site_code} · {row.street_address} · {row.member_count} member(s)
                    </span>
                  </button>
                ))}
            </div>

            <div className="dialog-actions">
              <button type="button" className="btn btn-ghost" onClick={onClose}>Cancel</button>
              <button
                type="button"
                className="btn btn-primary"
                disabled={!chosen || submitting}
                onClick={() => void submit(false)}
              >
                {submitting ? "Saving…" : "Link to household"}
              </button>
            </div>
          </>
        )}
    </Dialog>
  );
}

/**
 * Designating the head of a household. Only a member of that household
 * can be chosen, and replacing a sitting head has to be confirmed.
 */
export function DesignateHeadDialog({
  household,
  members,
  currentHead,
  onClose,
  onDone,
}: {
  household: { household_id: string; household_code: string };
  members: HouseholdMember[];
  currentHead: string | null;
  onClose: () => void;
  onDone: (message: string) => void | Promise<void>;
}) {
  const [chosen, setChosen] = useState<HouseholdMember | null>(null);
  const [confirmation, setConfirmation] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  async function submit(confirmed: boolean) {
    if (!chosen) return;
    setSubmitting(true);
    setError(null);

    const result = await designateHouseholdHead(household.household_id, chosen.resident_id, confirmed);
    setSubmitting(false);

    if (result.ok) {
      await onDone(`${result.data.head_full_name} is now the head of ${household.household_code}.`);
      return;
    }
    if (result.code === NEEDS_CONFIRMATION.replaceHead && !confirmed && currentHead) {
      setConfirmation(result.message);
      return;
    }
    setError(result.message);
  }

  const eligible = members.filter((member) => member.resident_status !== "deceased" && !member.is_head);

  return (
    <Dialog
      title="Designate head of household"
      intro={`A household has one head, and they must be a member of it. ${
        currentHead ? `${household.household_code} is currently headed by ${currentHead}.` : ""
      }`}
      onClose={onClose}
    >
      {error ? <Notice kind="error">{error}</Notice> : null}

      {confirmation
        ? (
          <>
            <div style={{ margin: "18px 0" }}><Notice kind="error">{confirmation}</Notice></div>
            <div className="dialog-actions">
              <button type="button" className="btn btn-ghost" onClick={() => setConfirmation(null)}>Go back</button>
              <button type="button" className="btn btn-primary" disabled={submitting} onClick={() => void submit(true)}>
                {submitting ? "Saving…" : `Make ${chosen?.full_name} the head`}
              </button>
            </div>
          </>
        )
        : (
          <>
            <div className="picker" style={{ marginTop: 18 }}>
              {eligible.length === 0
                ? (
                  <p className="muted-note">
                    There is nobody else in this household who could be designated head. Link a
                    resident to it first.
                  </p>
                )
                : eligible.map((member) => (
                  <button
                    type="button"
                    key={member.resident_id}
                    className={`picker-row${chosen?.resident_id === member.resident_id ? " chosen" : ""}`}
                    onClick={() => setChosen(member)}
                  >
                    <span className="name">{member.full_name}</span>
                    <span className="status-note">{member.id_number} · {member.resident_status}</span>
                  </button>
                ))}
            </div>

            <div className="dialog-actions">
              <button type="button" className="btn btn-ghost" onClick={onClose}>Cancel</button>
              <button type="button" className="btn btn-primary" disabled={!chosen || submitting}
                      onClick={() => void submit(false)}>
                {submitting ? "Saving…" : "Designate head"}
              </button>
            </div>
          </>
        )}
    </Dialog>
  );
}

/**
 * Recording a family relationship. The database records the other side
 * of it too — a parent gains a child, a spouse gains a spouse — so it
 * is only entered once, from one person's point of view.
 */
export function RecordRelationshipDialog({
  resident,
  onClose,
  onDone,
}: {
  resident: { resident_id: string; full_name: string };
  onClose: () => void;
  onDone: (message: string) => void | Promise<void>;
}) {
  const [relationshipType, setRelationshipType] = useState<RelationshipType>("parent");
  const [search, setSearch] = useState("");
  const [residents, setResidents] = useState<ResidentSearchRow[] | null>(null);
  const [chosen, setChosen] = useState<ResidentSearchRow | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    const timer = window.setTimeout(async () => {
      const result = await searchResidents(search);
      if (result.ok) setResidents(result.data.filter((row) => row.resident_id !== resident.resident_id));
    }, 250);
    return () => window.clearTimeout(timer);
  }, [search, resident.resident_id]);

  async function submit() {
    if (!chosen) return;
    setSubmitting(true);
    setError(null);

    const result = await recordFamilyRelationship(resident.resident_id, chosen.resident_id, relationshipType);
    setSubmitting(false);

    if (!result.ok) { setError(result.message); return; }
    await onDone(
      `${resident.full_name} is the ${result.data.relationship_type} of ${chosen.full_name}. ` +
        `${chosen.full_name} was recorded as their ${result.data.inverse_type}.`,
    );
  }

  return (
    <Dialog
      title="Record a family relationship"
      intro={`Recorded from ${resident.full_name}'s point of view. The matching relationship the other way round is recorded automatically. Relatives do not have to live in the same household.`}
      onClose={onClose}
    >
      {error ? <Notice kind="error">{error}</Notice> : null}

      <div style={{ marginTop: 18 }}>
        <Field label={`${resident.full_name} is the…`} htmlFor="relationship-type">
          <select
            id="relationship-type"
            value={relationshipType}
            onChange={(event) => setRelationshipType(event.target.value as RelationshipType)}
          >
            {RELATIONSHIP_TYPES.map((type) => <option key={type} value={type}>{type}</option>)}
          </select>
        </Field>
      </div>

      <div style={{ marginTop: 16 }}>
        <Field label="…of which resident?" htmlFor="relative-search">
          <input
            id="relative-search"
            type="search"
            placeholder="Identity number or name"
            value={search}
            onChange={(event) => setSearch(event.target.value)}
          />
        </Field>
      </div>

      <div className="picker">
        {residents === null
          ? <Loading what="Loading residents" />
          : residents.length === 0
          ? <p className="muted-note">No residents match that search.</p>
          : residents.slice(0, 40).map((row) => (
            <button
              type="button"
              key={row.resident_id}
              className={`picker-row${chosen?.resident_id === row.resident_id ? " chosen" : ""}`}
              onClick={() => setChosen(row)}
            >
              <span className="name">{row.full_name}</span>
              <span className="status-note">
                {row.id_number}{row.household_code ? ` · ${row.household_code}` : ""}
              </span>
            </button>
          ))}
      </div>

      <div className="dialog-actions">
        <button type="button" className="btn btn-ghost" onClick={onClose}>Cancel</button>
        <button type="button" className="btn btn-primary" disabled={!chosen || submitting} onClick={() => void submit()}>
          {submitting ? "Saving…" : "Record relationship"}
        </button>
      </div>
    </Dialog>
  );
}
