import { useEffect, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { useSession } from "../../auth/SessionProvider";
import { AppShell } from "../../components/AppShell";
import { PageHead } from "../../components/PageHead";
import { homeFor } from "../../components/navigation";
import { Field, Loading, Notice } from "../../components/ui";
import { MESSAGE_KINDS, messageTargets, sendMessage } from "../../registry/adminApi";
import type { MessageTargets } from "../../registry/adminApi";

const emptyForm = {
  subject: "", body: "", target_type: "direct", message_kind: "normal",
  target_staff_id: "", target_role_id: "",
  related_entity_type: "", related_entity_id: "",
};

/**
 * Writing to another role. A message may refer to a record by its
 * reference; that tells the reader what this is about and gives them no
 * access they did not already have.
 */
export function ComposeMessage() {
  const { session, profile } = useSession();
  const navigate = useNavigate();
  const [form, setForm] = useState(emptyForm);
  const [targets, setTargets] = useState<MessageTargets | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    let cancelled = false;
    messageTargets().then((result) => {
      if (cancelled) return;
      if (result.ok) setTargets(result.data);
      else setError(result.message);
    });
    return () => { cancelled = true; };
  }, []);

  const update = (key: keyof typeof emptyForm, value: string) =>
    setForm((current) => ({ ...current, [key]: value }));

  const home = homeFor(profile, Boolean(session));
  const ready = form.subject.trim() && form.body.trim()
    && (form.target_type !== "direct" || form.target_staff_id)
    && (form.target_type !== "role" || form.target_role_id);

  return (
    <AppShell>
      <PageHead
        title="Write a message"
        description="Send a message or a work request to another member of staff."
        crumbs={[
          { label: "Home", to: home },
          { label: "Messages", to: "/messages" },
          { label: "Compose" },
        ]}
        back={{ to: "/messages", label: "Back to messages" }}
      />

      {error ? <Notice kind="error">{error}</Notice> : null}
      {!targets && !error ? <Loading what="Loading who you can write to" /> : null}

      {targets
        ? (
          <form
            className="card"
            style={{ maxWidth: 780 }}
            onSubmit={async (event) => {
              event.preventDefault();
              setBusy(true);
              setError(null);
              const result = await sendMessage(form);
              setBusy(false);
              if (!result.ok) { setError(result.message); return; }
              navigate(`/messages/${result.data.message_id}`);
            }}
          >
            <div className="form-grid">
              <Field label="Send to (required)" htmlFor="target_type">
                <select id="target_type" value={form.target_type}
                        onChange={(event) => update("target_type", event.target.value)}>
                  <option value="direct">One staff member</option>
                  <option value="role">Everybody holding a role</option>
                  {targets.may_announce
                    ? <option value="all_staff">All staff — an announcement</option>
                    : null}
                </select>
              </Field>
              <Field label="Kind (required)" htmlFor="message_kind"
                     hint="An action required message becomes a work request.">
                <select id="message_kind" value={form.message_kind}
                        onChange={(event) => update("message_kind", event.target.value)}>
                  {MESSAGE_KINDS.map((kind) => (
                    <option key={kind.value} value={kind.value}>{kind.label}</option>
                  ))}
                </select>
              </Field>
            </div>

            {form.target_type === "direct"
              ? (
                <div style={{ marginTop: 16 }}>
                  <Field label="Staff member (required)" htmlFor="target_staff_id">
                    <select id="target_staff_id" value={form.target_staff_id}
                            onChange={(event) => update("target_staff_id", event.target.value)}>
                      <option value="">Choose…</option>
                      {targets.staff.map((person) => (
                        <option key={person.staff_id} value={person.staff_id}>
                          {person.full_name} — {person.role}
                        </option>
                      ))}
                    </select>
                  </Field>
                </div>
              )
              : null}

            {form.target_type === "role"
              ? (
                <div style={{ marginTop: 16 }}>
                  <Field label="Role (required)" htmlFor="target_role_id"
                         hint="Whoever holds that role right now receives it. A later role change does not change who was written to.">
                    <select id="target_role_id" value={form.target_role_id}
                            onChange={(event) => update("target_role_id", event.target.value)}>
                      <option value="">Choose…</option>
                      {targets.roles.map((role) => (
                        <option key={role.role_id} value={role.role_id}>
                          {role.role_name} ({role.active_members} active)
                        </option>
                      ))}
                    </select>
                  </Field>
                </div>
              )
              : null}

            <div style={{ marginTop: 16 }}>
              <Field label="Subject (required)" htmlFor="subject">
                <input id="subject" value={form.subject}
                       onChange={(event) => update("subject", event.target.value)} />
              </Field>
            </div>

            <div style={{ marginTop: 16 }}>
              <Field label="Message (required)" htmlFor="body">
                <textarea id="body" rows={8} value={form.body}
                          onChange={(event) => update("body", event.target.value)} />
              </Field>
            </div>

            <div className="form-grid" style={{ marginTop: 16 }}>
              <Field label="About a record" htmlFor="related_entity_type" hint="Optional.">
                <select id="related_entity_type" value={form.related_entity_type}
                        onChange={(event) => update("related_entity_type", event.target.value)}>
                  <option value="">Nothing in particular</option>
                  <option value="resident">Resident</option>
                  <option value="household">Household</option>
                  <option value="resident_account_request">Resident verification request</option>
                  <option value="land_application">Land application</option>
                  <option value="land_allocation">Land allocation</option>
                  <option value="pto">Permission to occupy</option>
                  <option value="meeting">Meeting</option>
                  <option value="resolution">Resolution</option>
                  <option value="project">Project</option>
                </select>
              </Field>
              {form.related_entity_type
                ? (
                  <Field label="Its identifier" htmlFor="related_entity_id"
                         hint="Copy it from the address bar of that record's page.">
                    <input id="related_entity_id" value={form.related_entity_id}
                           onChange={(event) => update("related_entity_id", event.target.value)} />
                  </Field>
                )
                : null}
            </div>

            <p className="muted-note" style={{ marginTop: 16 }}>
              Linking a record tells the reader what this is about. It gives them no permission
              they do not already have.
            </p>

            <div className="form-actions" style={{ marginTop: 22 }}>
              <button type="submit" className="btn btn-primary" disabled={busy || !ready}>
                {busy ? "Sending…" : "Send message"}
              </button>
              <Link to="/messages" className="btn btn-ghost">Cancel</Link>
            </div>
          </form>
        )
        : null}
    </AppShell>
  );
}
