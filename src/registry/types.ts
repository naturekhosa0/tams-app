/** Shapes returned by the registry_* database functions. */

export type ResidentSearchRow = {
  resident_id: string;
  id_number: string;
  first_name: string;
  last_name: string;
  full_name: string;
  date_of_birth: string;
  gender: string;
  contact_number: string | null;
  email: string | null;
  resident_status: ResidentStatus;
  household_code: string | null;
  site_code: string | null;
  street_address: string | null;
  is_household_head: boolean | null;
};

export type ResidentStatus = "active" | "inactive" | "deceased";

export type ResidentRecord = {
  resident_id: string;
  id_number: string;
  first_name: string;
  last_name: string;
  full_name: string;
  date_of_birth: string;
  gender: string;
  contact_number: string | null;
  email: string | null;
  resident_status: ResidentStatus;
  household_id: string | null;
  household_code: string | null;
  household_status: string | null;
  is_household_head: boolean;
  household_head: string | null;
  site_code: string | null;
  stand_number: string | null;
  street_address: string | null;
  village_section: string | null;
  village_name: string | null;
  relationship_count: number;
};

export const RELATIONSHIP_TYPES = [
  "parent", "child", "spouse", "sibling",
  "grandparent", "grandchild", "guardian", "dependant",
] as const;

export type RelationshipType = typeof RELATIONSHIP_TYPES[number];

export type LineageRow = {
  relationship_id: string;
  relationship_type: RelationshipType;
  relationship_status: "active" | "inactive";
  related_resident_id: string;
  related_full_name: string;
  related_id_number: string;
  related_status: ResidentStatus;
  related_household_code: string | null;
};

export type HouseholdSearchRow = {
  household_id: string;
  household_code: string;
  household_status: "active" | "inactive";
  site_code: string;
  stand_number: string | null;
  street_address: string;
  village_section: string | null;
  village_name: string | null;
  head_full_name: string | null;
  member_count: number;
};

export type HouseholdMember = {
  resident_id: string;
  full_name: string;
  id_number: string;
  date_of_birth: string;
  gender: string;
  resident_status: ResidentStatus;
  is_head: boolean;
};

export type HouseholdRecord = {
  household_id: string;
  household_code: string;
  household_status: "active" | "inactive";
  site_id: string;
  site_code: string;
  site_type: string;
  stand_number: string | null;
  street_address: string;
  village_section: string | null;
  village_name: string | null;
  head_resident_id: string | null;
  head_full_name: string | null;
  members: HouseholdMember[];
  /** Context only — land allocations belong to the Land Officer. */
  allocation: {
    allocation_reference: string;
    allocation_date: string;
    allocation_status: string;
    holder_full_name: string;
    holder_is_household_head: boolean;
  } | null;
};

export type RegistryStats = {
  residents: number;
  active_residents: number;
  households: number;
  residents_without_household: number;
  households_without_head: number;
  family_relationships: number;
};

export type AvailableSite = {
  site_id: string;
  site_code: string;
  stand_number: string | null;
  street_address: string;
  village_section: string | null;
  village_name: string | null;
};
