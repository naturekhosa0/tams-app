// How a stored relationship reads on screen.
//
// A row in family_relationships says:
//
//     <resident_id> is the <relationship_type> of <related_resident_id>
//
// So a row of type 'parent' on Samuel's record means Samuel is the
// parent of that person — which makes that person Samuel's CHILD. The
// heading a reader needs is therefore the inverse of the stored type,
// and getting this backwards would show someone's grandchildren under
// "Grandparents".

import type { LineageRow, RelationshipType } from "./types";

/** In the order a clerk reads them, each with the stored type it comes from. */
export const RELATIONSHIP_GROUPS: {
  heading: string;
  /** The stored relationship_type whose related person belongs here. */
  fromType: RelationshipType;
}[] = [
  { heading: "Parents", fromType: "child" },
  { heading: "Children", fromType: "parent" },
  { heading: "Spouse", fromType: "spouse" },
  { heading: "Siblings", fromType: "sibling" },
  { heading: "Grandparents", fromType: "grandchild" },
  { heading: "Grandchildren", fromType: "grandparent" },
  { heading: "Guardians", fromType: "dependant" },
  { heading: "Dependants", fromType: "guardian" },
];

/** "Samuel is the parent of Kabelo Rachidi" — the unambiguous long form. */
export function relationshipSentence(residentName: string, row: LineageRow): string {
  return `${residentName} is the ${row.relationship_type} of ${row.related_full_name}`;
}

export type LineageGroup = { heading: string; rows: LineageRow[] };

/** Groups a resident's relationships under the headings above. */
export function groupLineage(rows: LineageRow[]): LineageGroup[] {
  return RELATIONSHIP_GROUPS
    .map(({ heading, fromType }) => ({
      heading,
      rows: rows.filter((row) => row.relationship_type === fromType),
    }))
    .filter((group) => group.rows.length > 0);
}
