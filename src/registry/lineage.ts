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
//
// Relationships also fall into two kinds. Lineage is permanent: a
// father who has died is still the father. A marriage or a guardianship
// is an episode, which can end and can begin again later, and both the
// current one and the ones before it belong on the page.

import type { LineageRow, RelationshipType } from "./types";

export const TIME_BASED_TYPES: RelationshipType[] = ["spouse", "guardian", "dependant"];

export function isTimeBased(type: RelationshipType): boolean {
  return TIME_BASED_TYPES.includes(type);
}

export type LineageSection = "permanent" | "current" | "former";

type GroupDefinition = {
  section: LineageSection;
  heading: string;
  /** The stored relationship_type whose related person belongs here. */
  fromType: RelationshipType;
  /** Which status this group shows. Permanent lineage takes any. */
  status?: "active" | "inactive";
};

/** In the order a clerk reads them. */
export const RELATIONSHIP_GROUPS: GroupDefinition[] = [
  { section: "permanent", heading: "Parents", fromType: "child" },
  { section: "permanent", heading: "Children", fromType: "parent" },
  { section: "permanent", heading: "Siblings", fromType: "sibling" },
  { section: "permanent", heading: "Grandparents", fromType: "grandchild" },
  { section: "permanent", heading: "Grandchildren", fromType: "grandparent" },

  { section: "current", heading: "Current spouse", fromType: "spouse", status: "active" },
  { section: "current", heading: "Current guardians", fromType: "dependant", status: "active" },
  { section: "current", heading: "Current dependants", fromType: "guardian", status: "active" },

  { section: "former", heading: "Former spouse", fromType: "spouse", status: "inactive" },
  { section: "former", heading: "Former guardians", fromType: "dependant", status: "inactive" },
  { section: "former", heading: "Former dependants", fromType: "guardian", status: "inactive" },
];

export const SECTION_HEADINGS: Record<LineageSection, string> = {
  permanent: "Family lineage",
  current: "Current relationships",
  former: "Former relationships",
};

/** "Samuel is the parent of Kabelo Rachidi" — the unambiguous long form. */
export function relationshipSentence(residentName: string, row: LineageRow): string {
  return `${residentName} is the ${row.relationship_type} of ${row.related_full_name}`;
}

/** "Started 15 May 2010 · Ended 1 August 2022", where the dates are known. */
export function relationshipPeriod(row: LineageRow, formatDate: (value: string) => string): string {
  const parts: string[] = [];
  if (row.relationship_started_at) parts.push(`Started ${formatDate(row.relationship_started_at)}`);
  if (row.relationship_ended_at) parts.push(`Ended ${formatDate(row.relationship_ended_at)}`);
  return parts.join(" · ");
}

export type LineageGroup = { section: LineageSection; heading: string; rows: LineageRow[] };

/** Groups a resident's relationships under the headings above. */
export function groupLineage(rows: LineageRow[]): LineageGroup[] {
  return RELATIONSHIP_GROUPS
    .map(({ section, heading, fromType, status }) => ({
      section,
      heading,
      rows: rows.filter((row) =>
        row.relationship_type === fromType &&
        (status === undefined || row.relationship_status === status)
      ),
    }))
    .filter((group) => group.rows.length > 0);
}

/** The groups of one section, in reading order. */
export function sectionGroups(rows: LineageRow[], section: LineageSection): LineageGroup[] {
  return groupLineage(rows).filter((group) => group.section === section);
}

/**
 * Whether this relationship can be ended from the interface. Permanent
 * lineage never can: a parent remains a parent.
 */
export function mayBeEnded(row: LineageRow): boolean {
  return isTimeBased(row.relationship_type) && row.relationship_status === "active";
}
