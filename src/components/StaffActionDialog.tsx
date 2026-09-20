import { useEffect, useState } from "react";
import { callEdgeFunction } from "../lib/supabaseClient";
import { formatDate } from "../lib/format";
import { Field, Notice, StatusBadge } from "./ui";
import type { AssignableRole, StaffAccountRow, StaffAction } from "../lib/types";

const TITLES: Record<StaffAction, string> = {
  change_role: "Change role",
  deactivate: "Deactivate staff account",
  reactivate: "Reactivate staff account",
};

const INTROS: Record<StaffAction, string> = {
  change_role:
    "A staff member holds exactly one role. The new role replaces the current one — nothing else about their account changes.",
  deactivate:
    "The account is kept, along with their role and history. They simply cannot use the system until it is reactivated.",
  reactivate:
    "They get access back with the same account, the same role and the same password. Nothing is created.",
};

const CONFIRMATIONS: Record<StaffAction, string> = {
  change_role: "I confirm this staff member's role should be changed.",
  deactivate: "I confirm this staff member should lose access to the system.",
  reactivate: "I confirm this staff member should have access to the system again.",
};

/**
 * Change role, Deactivate and Reactivate all work the same way: show the
 * administrator exactly who they are acting on, ask for what the action
 * needs, and require an explicit confirmation before anything is sent.
 *
 * The request goes to the manage-staff-account edge function, which
 * re-establishes on the server that the caller is the active Council
 * Administrator. Every rule shown here is enforced again there and in
 * the database.
 */
export function StaffActionDialog({
  action,
  staff,
  roles,
  onClose,
  onDone,
}: {
  action: StaffAction;
  staff: StaffAccountRow;
  roles: AssignableRole[];
  onClose: () => void;
  onDone: (message: string) => void;
}) {
  const [roleId, setRoleId] = useState("");
  const [reason, setReason] = useState("");
  const [confirmed, setConfirmed] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [fieldErrors, setFieldErrors] = useState<Record<string, string>>({});

  useEffect(() => {
    function onKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape") onClose();
    }
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [onClose]);

  async function handleSubmit(event: React.FormEvent) {
    event.preventDefault();
    setError(null);
    setFieldErrors({});
    setSubmitting(true);

    const result = await callEdgeFunction<{ message: string }>("manage-staff-account", {
      action,
      staff_id: staff.staff_id,
      ...(action === "change_role" ? { role_id: roleId } : { reason }),
    });

    setSubmitting(false);

    if (!result.ok) {
      setError(result.message ?? "The change could not be saved.");
      setFieldErrors(result.fields ?? {});
      return;
    }

    onDone(result.data?.message ?? "The change has been saved.");
  }

  return (
    <div className="backdrop" role="dialog" aria-modal="true" aria-label={TITLES[action]}>
      <div className="dialog">
        <h2>{TITLES[action]}</h2>
        <p className="dialog-intro">{INTROS[action]}</p>

        <div className="dialog-details">
          <div className="detail-item">
            <span className="label">Employee number</span>
            <span className="value">{staff.employee_number}</span>
          </div>
          <div className="detail-item">
            <span className="label">Full name</span>
            <span className="value">{staff.first_name} {staff.last_name}</span>
          </div>
          <div className="detail-item">
            <span className="label">Email</span>
            <span className="value">{staff.email}</span>
          </div>
          <div className="detail-item">
            <span className="label">Current role</span>
            <span className="value">{staff.role_name}</span>
          </div>
          {action !== "change_role"
            ? (
              <div className="detail-item">
                <span className="label">Account status</span>
                <span className="value"><StatusBadge status={staff.account_status} /></span>
              </div>
            )
            : null}
          {action === "reactivate"
            ? (
              <>
                <div className="detail-item">
                  <span className="label">Last deactivated</span>
                  <span className="value">{formatDate(staff.last_deactivated_at)}</span>
                </div>
                <div className="detail-item">
                  <span className="label">Reason given then</span>
                  <span className="value">{staff.last_deactivation_reason ?? "—"}</span>
                </div>
              </>
            )
            : null}
        </div>

        <form onSubmit={handleSubmit} noValidate>
          {error ? <Notice kind="error">{error}</Notice> : null}

          <div style={{ marginTop: error ? 18 : 0 }}>
            {action === "change_role"
              ? (
                <Field
                  label="New role"
                  htmlFor="new-role"
                  error={fieldErrors.role_id}
                  hint="Only these three roles can be assigned."
                >
                  <select id="new-role" value={roleId} onChange={(event) => setRoleId(event.target.value)}>
                    <option value="">Choose a role…</option>
                    {roles.map((role) => (
                      <option key={role.id} value={role.id}>
                        {role.role_name}{role.id === staff.role_id ? " (current role)" : ""}
                      </option>
                    ))}
                  </select>
                </Field>
              )
              : (
                <Field
                  label={action === "deactivate" ? "Reason for deactivating" : "Reason for reactivating"}
                  htmlFor="reason"
                  error={fieldErrors.reason}
                  hint="Kept on the staff record, with your name and the date."
                >
                  <textarea
                    id="reason"
                    value={reason}
                    maxLength={500}
                    placeholder={action === "deactivate"
                      ? "e.g. Staff member resigned"
                      : "e.g. Returned from leave"}
                    onChange={(event) => setReason(event.target.value)}
                  />
                </Field>
              )}
          </div>

          <label className="confirm-line">
            <input
              type="checkbox"
              checked={confirmed}
              onChange={(event) => setConfirmed(event.target.checked)}
            />
            <span>{CONFIRMATIONS[action]}</span>
          </label>

          <div className="dialog-actions">
            <button type="button" className="btn btn-ghost" onClick={onClose} disabled={submitting}>
              Cancel
            </button>
            <button type="submit" className="btn btn-primary" disabled={submitting || !confirmed}>
              {submitting ? "Saving…" : TITLES[action]}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}
