import type { ResidentStatus } from "../../registry/types";

const LABELS: Record<ResidentStatus, string> = {
  active: "Active",
  inactive: "Inactive",
  deceased: "Deceased",
};

export function ResidentStatusBadge({ status }: { status: ResidentStatus }) {
  return (
    <span className={`badge badge-${status === "active" ? "active" : "deactivated"}`}>
      {LABELS[status] ?? status}
    </span>
  );
}
