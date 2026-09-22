import { useEffect, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { AppShell } from "../../components/AppShell";
import { PageHead } from "../../components/PageHead";
import { Field, Notice } from "../../components/ui";
import {
  AUDIENCE_TYPES, COMMUNICATION_TYPES, ON_BEHALF_OF, searchResidents, sendCommunication,
} from "../../registry/adminApi";
import type { ResidentSearchRow } from "../../registry/adminApi";

const emptyForm = {
  communication_type: "general_notice",
  audience_type: "all_active_residents",
  subject: "", message: "",
  issued_on_behalf_of: "", event_date: "", event_time: "", venue: "",
  related_entity_type: "", related_entity_id: "",
};

/** Writing to residents on behalf of the Chief or the Traditional Council. */
export function SendCommunication() {
  const navigate = useNavigate();
  const [form, setForm] = useState(emptyForm);
  const [chosen, setChosen] = useState<ResidentSearchRow[]>([]);
  const [search, setSearch] = useState("");
  const [results, setResults] = useState<ResidentSearchRow[]>([]);
  const [searching, setSearching] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const update = (key: keyof typeof emptyForm, value: string) =>
    setForm((current) => ({ ...current, [key]: value }));

  const needsResidents = form.audience_type !== "all_active_residents";
  const single = form.audience_type === "one_resident";

  // Choosing "one resident" after picking several keeps only the first.
  useEffect(() => {
    if (single && chosen.length > 1) setChosen(chosen.slice(0, 1));
  }, [single, chosen]);

  const ready = form.subject.trim() && form.message.trim()
    && (!needsResidents || chosen.length > 0)
    && (!single || chosen.length === 1);

  return (
    <AppShell>
      <PageHead
        title="Send a notice"
        description="An announcement to the whole community, or an official notice to one resident or a few."
        crumbs={[
          { label: "Dashboard", to: "/secretary" },
          { label: "Communications", to: "/secretary/communications" },
          { label: "Send a notice" },
        ]}
        back={{ to: "/secretary/communications", label: "Back to communications" }}
      />

      {error ? <Notice kind="error">{error}</Notice> : null}

      <form
        className="card"
        style={{ maxWidth: 820 }}
        onSubmit={async (event) => {
          event.preventDefault();
          setBusy(true);
          setError(null);
          const result = await sendCommunication({
            ...form,
            resident_ids: chosen.map((person) => person.resident_id),
          });
          setBusy(false);
          if (!result.ok) { setError(result.message); return; }
          navigate("/secretary/communications");
        }}
      >
        <div className="form-grid">
          <Field label="Kind of notice (required)" htmlFor="communication_type">
            <select id="communication_type" value={form.communication_type}
                    onChange={(event) => update("communication_type", event.target.value)}>
              {COMMUNICATION_TYPES.map((option) => (
                <option key={option.value} value={option.value}>{option.label}</option>
              ))}
            </select>
          </Field>
          <Field label="Who it goes to (required)" htmlFor="audience_type">
            <select id="audience_type" value={form.audience_type}
                    onChange={(event) => update("audience_type", event.target.value)}>
              {AUDIENCE_TYPES.map((option) => (
                <option key={option.value} value={option.value}>{option.label}</option>
              ))}
            </select>
          </Field>
        </div>

        {needsResidents
          ? (
            <div style={{ marginTop: 18 }}>
              <div className="section-heading">
                {single ? "The resident" : "The residents"} ({chosen.length} chosen)
              </div>

              {chosen.length > 0
                ? (
                  <div className="chosen-list">
                    {chosen.map((person) => (
                      <span className="chip" key={person.resident_id}>
                        {person.full_name}
                        <button type="button" aria-label={`Remove ${person.full_name}`}
                                onClick={() => setChosen(chosen.filter(
                                  (p) => p.resident_id !== person.resident_id))}>
                          ×
                        </button>
                      </span>
                    ))}
                  </div>
                )
                : null}

              <div className="input-with-button" style={{ marginTop: 12 }}>
                <input
                  value={search}
                  placeholder="Name, identity number, household code or address"
                  aria-label="Search residents"
                  onChange={(event) => setSearch(event.target.value)}
                  onKeyDown={(event) => { if (event.key === "Enter") event.preventDefault(); }}
                />
                <button type="button" className="btn btn-ghost" disabled={searching}
                        onClick={async () => {
                          setSearching(true);
                          const result = await searchResidents(search.trim());
                          setSearching(false);
                          if (!result.ok) { setError(result.message); return; }
                          setResults(result.data);
                        }}>
                  {searching ? "Searching…" : "Search"}
                </button>
              </div>

              <div className="picker">
                {results.length === 0
                  ? <p className="muted-note">Search to find residents with active accounts.</p>
                  : results.map((person) => {
                    const already = chosen.some((p) => p.resident_id === person.resident_id);
                    return (
                      <button type="button" key={person.resident_id}
                              className={`picker-row${already ? " chosen" : ""}`}
                              onClick={() => {
                                if (already) return;
                                setChosen(single ? [person] : [...chosen, person]);
                              }}>
                        <span className="name">{person.full_name}</span>
                        <span className="status-note">
                          {person.id_number}
                          {person.household_code ? ` · ${person.household_code}` : ""}
                          {person.street_address ? ` · ${person.street_address}` : ""}
                          {already ? " · already chosen" : ""}
                        </span>
                      </button>
                    );
                  })}
              </div>
            </div>
          )
          : (
            <p className="muted-note" style={{ marginTop: 16 }}>
              Everybody with a verified, active resident account at the moment you send this will
              receive it. Anybody verified afterwards will not.
            </p>
          )}

        <div style={{ marginTop: 18 }}>
          <Field label="Subject (required)" htmlFor="subject">
            <input id="subject" value={form.subject}
                   onChange={(event) => update("subject", event.target.value)} />
          </Field>
        </div>

        <div style={{ marginTop: 16 }}>
          <Field label="Message (required)" htmlFor="message">
            <textarea id="message" rows={7} value={form.message}
                      onChange={(event) => update("message", event.target.value)} />
          </Field>
        </div>

        <div className="form-grid" style={{ marginTop: 16 }}>
          <Field label="Issued on behalf of" htmlFor="issued_on_behalf_of"
                 hint="Descriptive only — nobody here has a TAMS account.">
            <select id="issued_on_behalf_of" value={form.issued_on_behalf_of}
                    onChange={(event) => update("issued_on_behalf_of", event.target.value)}>
              <option value="">Not stated</option>
              {ON_BEHALF_OF.map((who) => <option key={who} value={who}>{who}</option>)}
            </select>
          </Field>
          <Field label="Venue" htmlFor="venue" hint="Optional.">
            <input id="venue" value={form.venue}
                   onChange={(event) => update("venue", event.target.value)} />
          </Field>
        </div>

        <div className="form-grid" style={{ marginTop: 16 }}>
          <Field label="Date" htmlFor="event_date" hint="Optional — for a summons or a meeting.">
            <input id="event_date" type="date" value={form.event_date}
                   onChange={(event) => update("event_date", event.target.value)} />
          </Field>
          <Field label="Time" htmlFor="event_time" hint="Optional.">
            <input id="event_time" type="time" value={form.event_time}
                   onChange={(event) => update("event_time", event.target.value)} />
          </Field>
        </div>

        <div className="form-grid" style={{ marginTop: 16 }}>
          <Field label="About a record" htmlFor="related_entity_type" hint="Optional.">
            <select id="related_entity_type" value={form.related_entity_type}
                    onChange={(event) => update("related_entity_type", event.target.value)}>
              <option value="">Nothing in particular</option>
              <option value="meeting">Meeting</option>
              <option value="resolution">Resolution</option>
              <option value="project">Project</option>
            </select>
          </Field>
          {form.related_entity_type
            ? (
              <Field label="Its identifier" htmlFor="related_entity_id"
                     hint="Copy it from the address bar of that record's page. Only its reference is shown.">
                <input id="related_entity_id" value={form.related_entity_id}
                       onChange={(event) => update("related_entity_id", event.target.value)} />
              </Field>
            )
            : null}
        </div>

        <p className="muted-note" style={{ marginTop: 16 }}>
          Every recipient gets this in TAMS and by email. Reading it is not attendance, acceptance
          or agreement — it only means they opened it.
        </p>

        <div className="form-actions" style={{ marginTop: 22 }}>
          <button type="submit" className="btn btn-primary" disabled={busy || !ready}>
            {busy ? "Sending…" : "Send the notice"}
          </button>
          <Link to="/secretary/communications" className="btn btn-ghost">Cancel</Link>
        </div>
      </form>
    </AppShell>
  );
}
