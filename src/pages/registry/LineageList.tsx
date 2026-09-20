import { Link } from "react-router-dom";
import { groupLineage, relationshipSentence } from "../../registry/lineage";
import type { LineageRow } from "../../registry/types";

/**
 * A resident's relationships, grouped the way a clerk reads them. The
 * groups come straight from family_relationships — there is no separate
 * family tree stored anywhere.
 */
export function LineageList({
  residentName,
  rows,
  onRetire,
}: {
  residentName: string;
  rows: LineageRow[];
  onRetire?: (row: LineageRow) => void;
}) {
  const current = rows.filter((row) => row.relationship_status === "active");
  const retired = rows.filter((row) => row.relationship_status === "inactive");

  if (rows.length === 0) {
    return <p className="muted-note">No family relationships have been recorded for {residentName} yet.</p>;
  }

  return (
    <>
      <div className="lineage">
        {groupLineage(current).map(({ heading, rows: group }) => (
          <div className="lineage-group" key={heading}>
            <div className="lineage-heading">{heading}</div>
            {group.map((row) => (
              <div className="lineage-row" key={row.relationship_id}>
                <div>
                  <Link to={`/registry/residents/${row.related_resident_id}`}>{row.related_full_name}</Link>
                  <div className="status-note" title={relationshipSentence(residentName, row)}>
                    {row.related_id_number}
                    {row.related_household_code ? ` · ${row.related_household_code}` : ""}
                    {row.related_status !== "active" ? ` · ${row.related_status}` : ""}
                  </div>
                </div>
                {onRetire
                  ? (
                    <button type="button" className="btn btn-ghost btn-small" onClick={() => onRetire(row)}>
                      Mark no longer current
                    </button>
                  )
                  : null}
              </div>
            ))}
          </div>
        ))}
      </div>

      {retired.length > 0
        ? (
          <div style={{ marginTop: 20 }}>
            <div className="lineage-heading">No longer current</div>
            {retired.map((row) => (
              <div className="lineage-row" key={row.relationship_id}>
                <div>
                  <Link to={`/registry/residents/${row.related_resident_id}`}>{row.related_full_name}</Link>
                  <div className="status-note">{relationshipSentence(residentName, row)} · kept on record</div>
                </div>
              </div>
            ))}
          </div>
        )
        : null}
    </>
  );
}
