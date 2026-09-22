import { Children, cloneElement, isValidElement } from "react";
import type { ReactElement, ReactNode } from "react";

/**
 * A labelled control, with its hint and its validation message.
 *
 * The hint and the error are tied to the control itself, not merely
 * placed near it: somebody using a screen reader hears "Email, invalid
 * entry, that address is already in use" rather than hearing the label
 * and having to go looking for the reason.
 *
 * The control keeps whatever the caller gave it. Only the two
 * accessibility attributes are added, and only when the caller has not
 * set them already.
 */
export function Field({
  label,
  htmlFor,
  error,
  hint,
  children,
}: {
  label: string;
  htmlFor: string;
  error?: string;
  hint?: string;
  children: ReactNode;
}) {
  const hintId = `${htmlFor}-hint`;
  const errorId = `${htmlFor}-error`;
  const showHint = Boolean(hint) && !error;
  const describedBy = [error ? errorId : null, showHint ? hintId : null]
    .filter(Boolean)
    .join(" ");

  return (
    <div className={`field${error ? " has-error" : ""}`}>
      <label htmlFor={htmlFor}>{label}</label>
      {describeControl(children, describedBy, Boolean(error))}
      {showHint ? <span className="hint" id={hintId}>{hint}</span> : null}
      {error ? <span className="error" id={errorId} role="alert">{error}</span> : null}
    </div>
  );
}

/** The elements that can carry a description and a validity state. */
const CONTROLS = new Set(["input", "select", "textarea"]);

/**
 * Points a control at its hint and its error.
 *
 * Some fields wrap their control — a password box with a Show button
 * beside it, for instance — so this looks through a wrapper for the
 * control inside rather than putting the attributes on a div where
 * they would mean nothing. The first control found wins; a wrapper
 * holding two would be a field with two answers, which TAMS does not
 * have.
 */
function describeControl(children: ReactNode, describedBy: string, invalid: boolean): ReactNode {
  if (!describedBy && !invalid) return children;

  let done = false;

  const walk = (node: ReactNode): ReactNode => {
    if (done || !isValidElement(node)) return node;

    if (typeof node.type === "string" && CONTROLS.has(node.type)) {
      done = true;
      const existing = node.props as Record<string, unknown>;
      const extra: Record<string, unknown> = {};
      if (describedBy && existing["aria-describedby"] === undefined) {
        extra["aria-describedby"] = describedBy;
      }
      if (invalid && existing["aria-invalid"] === undefined) {
        extra["aria-invalid"] = true;
      }
      return Object.keys(extra).length === 0 ? node : cloneElement(node as ReactElement, extra);
    }

    // A plain wrapper element: look inside it. Anything else — a
    // component, a string, a fragment of unknown shape — is left alone,
    // because its internals are not ours to rearrange.
    const inner = (node.props as { children?: ReactNode }).children;
    if (typeof node.type !== "string" || inner === undefined) return node;

    return cloneElement(
      node as ReactElement<{ children?: ReactNode }>,
      undefined,
      Children.map(inner, walk),
    );
  };

  return Children.map(children, walk);
}

export function Notice({ kind, children }: { kind: "error" | "success" | "info"; children: ReactNode }) {
  return (
    <div className={`notice notice-${kind}`} role={kind === "error" ? "alert" : "status"}>
      {children}
    </div>
  );
}

export function StatusBadge({ status }: { status: string }) {
  const label = status === "active" ? "Active" : "Deactivated";
  return <span className={`badge badge-${status === "active" ? "active" : "deactivated"}`}>{label}</span>;
}

/**
 * Shown while something is being fetched, so that no panel is ever
 * simply blank while a page waits.
 */
export function Loading({ what = "Loading" }: { what?: string }) {
  return <div className="loading" role="status" aria-live="polite">{what}…</div>;
}
