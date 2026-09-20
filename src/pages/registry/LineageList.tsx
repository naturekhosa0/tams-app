import { Link } from "react-router-dom";
import {
  mayBeEnded, relationshipPeriod, relationshipSentence, SECTION_HEADINGS, sectionGroups,
} from "../../registry/lineage";
import type { LineageSection } from "../../registry/lineage";
import { formatDate } from "../../lib/format";
import type { LineageRow } from "../../registry/types";

/**
 * A resident's relationships, grouped the way a clerk reads them: the
 * lineage that never changes, the marriages and guardianships that hold
 * now, and the ones that have ended.
 *
 * All of it comes straight from family_relationships — there is no
 * separate family tree stored anywhere.
 */
export function LineageList({
  residentName,
  rows,
  onEnd,
}: {
  residentName: string;
  rows: LineageRow[];
  onEnd?: (row: LineageRow) => void;
}) {
  if (rows.length === 0) {
    return <p className="muted-note">No family relationships have been recorded for {residentName} yet.</p>;
  }

  const sections: LineageSection[] = ["permanent", "current", "former"];

  return (
    <>
      {sections.map((section) => {
        const groups = sectionGroups(rows, section);
        if (groups.length === 0) return null;

        return (
          <div key={section} style={{ marginBottom: 26 }}>
            <div className="section-heading">{SECTION_HEADINGS[section]}</div>
            <div className="lineage">
              {groups.map(({ heading, rows: group }) => (
                <div className="lineage-group" key={heading}>
                  <div className="lineage-heading">{heading}</div>
                  {group.map((row) => {
                    const period = relationshipPeriod(row, formatDate);
                    return (
                      <div className="lineage-row" key={row.relationship_id}>
                        <div>
                          <Link to={`/registry/residents/${row.related_resident_id}`}>
                            {row.related_full_name}
                          </Link>
                          <div className="status-note" title={relationshipSentence(residentName, row)}>
                            {row.related_id_number}
                            {row.related_household_code ? ` \u00b7 ${row.related_household_code}` : ""}
                            {row.related_status !== "active" ? ` \u00b7 ${row.related_status}` : ""}
                          </div>
                          {period ? <div className="status-note">{period}</div> : null}
                        </div>
                        {onEnd && mayBeEnded(row)
                          ? (
                            <button type="button" className="btn btn-ghost btn-small" onClick={() => onEnd(row)}>
                              End
                            </button>
                          )
                          : null}
                      </div>
                    );
                  })}
                </div>
              ))}
            </div>
          </div>
        );
      })}
    </>
  );
}
