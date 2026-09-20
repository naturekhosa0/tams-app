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
  relationship_started_at: string | null;
  relationship_ended_at: string | null;
  time_based: boolean;
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

// ---- resident account verification ----------------------------------

export type PendingRequestRow = {
  request_id: string;
  full_name: string;
  id_number: string;
  date_of_birth: string;
  gender: string;
  email: string;
  cellphone_number: string;
  house_number: string;
  street_address: string;
  household_head_name: string;
  relationship_to_household_head: string;
  submitted_at: string;
  previous_attempts: number;
};

export type RequestDocument = {
  document_type: "certified_id_copy" | "proof_of_residence";
  storage_path: string;
  file_name: string;
  mime_type: string;
  file_size_bytes: number;
};

export type ResidentRequestDetail = {
  request_id: string;
  request_status: "pending" | "approved" | "declined";
  submitted_at: string;
  reviewed_at: string | null;
  decline_reason: string | null;
  account_email: string;
  account_status: string;
  claimed: {
    first_name: string;
    middle_names: string | null;
    last_name: string;
    previous_surname: string | null;
    full_name: string;
    id_number: string;
    date_of_birth: string;
    gender: string;
    cellphone_number: string;
    house_number: string;
    street_address: string;
    household_head_name: string;
    relationship_to_household_head: string;
  };
  documents: RequestDocument[];
  earlier_attempts: {
    request_status: string;
    submitted_at: string;
    reviewed_at: string | null;
    decline_reason: string | null;
  }[];
  matched_resident_id: string | null;
};

export type CandidateRow = {
  resident_id: string;
  full_name: string;
  id_number: string;
  date_of_birth: string;
  gender: string;
  resident_status: ResidentStatus;
  household_code: string | null;
  household_head: string | null;
  street_address: string | null;
  already_linked: boolean;
  match_rank: number;
  match_reason: string;
};
