// Every Registry Clerk operation, as a call to one of the registry_*
// database functions.
//
// Each of those functions works out for itself, from auth.uid(), that
// the caller is an active Registry Clerk, and enforces its own rules.
// Nothing here is trusted: this layer only shapes requests and turns
// refusals into something readable.

import { supabase } from "../lib/supabaseClient";
import type {
  AvailableSite, CandidateRow, HouseholdRecord, HouseholdSearchRow, LineageRow,
  PendingRequestRow, RegistryStats, RelationshipType, ResidentRecord,
  ResidentRequestDetail, ResidentSearchRow, ResidentStatus,
} from "./types";

export type RegistryResult<T> =
  | { ok: true; data: T }
  | { ok: false; code: string; message: string };

/**
 * Codes the database raises that the interface acts on rather than just
 * reporting. Both mean "this would change something already there —
 * confirm first".
 */
export const NEEDS_CONFIRMATION = {
  reassignHousehold: "TA038",
  replaceHead: "TA041",
} as const;

function failure(error: { code?: string; message: string }): RegistryResult<never> {
  // PostgreSQL puts the raised message where we want it; strip the
  // prefix Supabase sometimes adds.
  const message = (error.message ?? "Something went wrong.")
    .replace(/^[A-Z0-9]{5}:\s*/, "")
    .trim();

  if (error.code === "42501") {
    return {
      ok: false,
      code: "42501",
      message: "Only an active Registry Clerk may do that. Ask the Council Administrator if this looks wrong.",
    };
  }

  // PostgREST could not find the function it was asked for. The raw
  // wording ("… in the schema cache") says nothing useful to whoever is
  // looking at the screen, so say what it actually means.
  if (error.code === "PGRST202") {
    return {
      ok: false,
      code: "PGRST202",
      message:
        "This part of the system is not installed on the database yet. " +
        "The Registry Clerk migration needs to be applied to the Supabase project " +
        "(see docs/REGISTRY-CLERK.md). Nothing you did caused this.",
    };
  }
  return { ok: false, code: error.code ?? "unknown", message };
}

async function call<T>(name: string, args: Record<string, unknown> = {}): Promise<RegistryResult<T>> {
  const { data, error } = await supabase.rpc(name, args);
  if (error) return failure(error);
  return { ok: true, data: data as T };
}

// ---- reading ---------------------------------------------------------

export const searchResidents = (search: string) =>
  call<ResidentSearchRow[]>("registry_search_residents", { p_search: search || null });

export const residentRecord = (residentId: string) =>
  call<ResidentRecord>("registry_resident_record", { p_resident_id: residentId });

export const familyLineage = (residentId: string) =>
  call<LineageRow[]>("registry_family_lineage", { p_resident_id: residentId });

export const searchHouseholds = (search: string) =>
  call<HouseholdSearchRow[]>("registry_search_households", { p_search: search || null });

export const householdRecord = (householdId: string) =>
  call<HouseholdRecord>("registry_household_record", { p_household_id: householdId });

export const dashboardStats = () => call<RegistryStats>("registry_dashboard_stats");

export const availableResidentialSites = () =>
  call<AvailableSite[]>("registry_available_residential_sites");

export const nextHouseholdCode = () => call<string>("registry_next_household_code");

// ---- writing ---------------------------------------------------------

export type ResidentDetails = {
  id_number: string;
  first_name: string;
  last_name: string;
  date_of_birth: string;
  gender: string;
  resident_status: ResidentStatus;
  contact_number: string;
  email: string;
};

export const createResident = (details: ResidentDetails, householdId?: string | null) =>
  call<{ resident_id: string; full_name: string }>("registry_create_resident", {
    p_id_number: details.id_number,
    p_first_name: details.first_name,
    p_last_name: details.last_name,
    p_date_of_birth: details.date_of_birth,
    p_gender: details.gender,
    p_resident_status: details.resident_status,
    p_contact_number: details.contact_number || null,
    p_email: details.email || null,
    p_household_id: householdId ?? null,
  });

export const updateResident = (residentId: string, details: ResidentDetails) =>
  call<{ resident_id: string; full_name: string }>("registry_update_resident", {
    p_resident_id: residentId,
    p_id_number: details.id_number,
    p_first_name: details.first_name,
    p_last_name: details.last_name,
    p_date_of_birth: details.date_of_birth,
    p_gender: details.gender,
    p_resident_status: details.resident_status,
    p_contact_number: details.contact_number || null,
    p_email: details.email || null,
  });

export const createHousehold = (code: string, siteId: string, status: "active" | "inactive") =>
  call<{ household_id: string; household_code: string }>("registry_create_household", {
    p_household_code: code,
    p_site_id: siteId,
    p_household_status: status,
  });

export const linkResidentToHousehold = (
  residentId: string,
  householdId: string,
  confirmReassignment = false,
) =>
  call<{ household_code: string; moved_from: string | null }>("registry_link_resident_to_household", {
    p_resident_id: residentId,
    p_household_id: householdId,
    p_confirm_reassignment: confirmReassignment,
  });

export const designateHouseholdHead = (
  householdId: string,
  residentId: string,
  confirmReplacement = false,
) =>
  call<{ head_full_name: string; replaced: string | null }>("registry_designate_household_head", {
    p_household_id: householdId,
    p_resident_id: residentId,
    p_confirm_replacement: confirmReplacement,
  });

export const recordFamilyRelationship = (
  residentId: string,
  relatedResidentId: string,
  relationshipType: RelationshipType,
  /** Required for a marriage or a guardianship; lineage has no start. */
  startedAt: string | null = null,
) =>
  call<{ relationship_type: string; inverse_type: string; started_at: string | null }>(
    "registry_record_family_relationship", {
      p_resident_id: residentId,
      p_related_resident_id: relatedResidentId,
      p_relationship_type: relationshipType,
      p_started_at: startedAt || null,
    });

/** Ends this episode and the matching one the other way round. */
export const endFamilyRelationship = (relationshipId: string, endedAt: string) =>
  call<{ relationship_type: string; ended_at: string }>("registry_end_family_relationship", {
    p_relationship_id: relationshipId,
    p_ended_at: endedAt,
  });

// ---- resident account verification ----------------------------------

export const pendingResidentRequests = () =>
  call<PendingRequestRow[]>("registry_pending_resident_requests");

export const residentRequest = (requestId: string) =>
  call<ResidentRequestDetail>("registry_resident_request", { p_request_id: requestId });

export const residentCandidates = (requestId: string) =>
  call<CandidateRow[]>("registry_resident_candidates", { p_request_id: requestId });

export const approveResidentRequest = (requestId: string, residentId: string) =>
  call<{ resident_name: string; household_code: string }>("registry_approve_resident_request", {
    p_request_id: requestId,
    p_resident_id: residentId,
  });

export const declineResidentRequest = (requestId: string, reason: string) =>
  call<{ decline_reason: string }>("registry_decline_resident_request", {
    p_request_id: requestId,
    p_reason: reason,
  });
