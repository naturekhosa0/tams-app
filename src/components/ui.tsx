import type { ReactNode } from "react";

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
  return (
    <div className={`field${error ? " has-error" : ""}`}>
      <label htmlFor={htmlFor}>{label}</label>
      {children}
      {hint && !error ? <span className="hint">{hint}</span> : null}
      {error ? <span className="error" role="alert">{error}</span> : null}
    </div>
  );
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

export function Loading({ what = "Loading" }: { what?: string }) {
  return <div className="loading">{what}…</div>;
}
