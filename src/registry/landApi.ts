// Land: applying for it, allocating it, and the permission to occupy it.
//
// Every one of these is a database function that establishes its own
// caller from auth.uid() and rechecks the rules for itself. Nothing
// here is trusted; this layer only shapes the calls.

import { supabase } from "../lib/supabaseClient";
import type {
  AvailableSiteRow, Eligibility, LandType, OfficerApplication, OfficerApplicationRow,
  OfficerAllocationRow, OfficerDashboard, OfficerPtoRow, OfficerSiteRow, PtoDocument,
  PtoVerification,
  RenewalRow, ResidentLandPortal, SiteHistory, SuccessionCandidate,
} from "./landTypes";

export type LandResult<T> = { ok: true; data: T } | { ok: false; code: string; message: string };

function failure(error: { code?: string; message: string }): LandResult<never> {
  const message = (error.message ?? "Something went wrong.").replace(/^[A-Z0-9]{5}:\s*/, "").trim();
  if (error.code === "42501") {
    return { ok: false, code: "42501", message: "You are not allowed to do that." };
  }
  if (error.code === "PGRST202") {
    return {
      ok: false, code: "PGRST202",
      message: "This part of the system is not installed on the database yet. " +
        "The land migrations need to be applied to the Supabase project.",
    };
  }
  return { ok: false, code: error.code ?? "unknown", message };
}

async function call<T>(name: string, args: Record<string, unknown> = {}): Promise<LandResult<T>> {
  const { data, error } = await supabase.rpc(name, args);
  if (error) return failure(error);
  return { ok: true, data: data as T };
}

// ---- resident --------------------------------------------------------

export const residentLandPortal = () => call<ResidentLandPortal>("resident_land_portal");

export const residentLandEligibility = (landType: LandType) =>
  call<Eligibility>("resident_land_eligibility", { p_land_type: landType });

export const submitLandApplication = (landType: LandType, details: Record<string, unknown>) =>
  call<{ application_reference: string }>("resident_submit_land_application", {
    p_land_type: landType, p_details: details,
  });

export const requestPtoRenewal = (ptoId: string, reason: string) =>
  call<{ pto_number: string }>("resident_request_pto_renewal", {
    p_pto_id: ptoId, p_reason: reason || null,
  });

export const ptoDocument = (ptoId: string) => call<PtoDocument>("pto_document", { p_pto_id: ptoId });

// ---- public ----------------------------------------------------------

export const verifyPto = (token: string) => call<PtoVerification>("verify_pto", { p_token: token });

// ---- land officer ----------------------------------------------------

export const officerDashboard = () => call<OfficerDashboard>("land_officer_dashboard");

export const officerApplications = (status?: string, landType?: string, search?: string) =>
  call<OfficerApplicationRow[]>("land_officer_applications", {
    p_status: status || null, p_land_type: landType || null, p_search: search || null,
  });

export const officerApplication = (applicationId: string) =>
  call<OfficerApplication>("land_officer_application", { p_application_id: applicationId });

export const approveApplication = (applicationId: string) =>
  call<{ application_reference: string }>("land_officer_approve_application", {
    p_application_id: applicationId,
  });

export const declineApplication = (applicationId: string, reason: string) =>
  call<{ decline_reason: string }>("land_officer_decline_application", {
    p_application_id: applicationId, p_reason: reason,
  });

export const availableSites = (landType: LandType) =>
  call<AvailableSiteRow[]>("land_officer_available_sites", { p_land_type: landType });

export const allocateSite = (applicationId: string, siteId: string) =>
  call<{ allocation_id: string; allocation_reference: string; site_code: string; land_type: string }>(
    "land_officer_allocate_site", { p_application_id: applicationId, p_site_id: siteId });

export const issuePto = (allocationId: string) =>
  call<{ pto_id: string; pto_number: string; expiry_date: string | null; perpetual: boolean }>(
    "land_officer_issue_pto", { p_allocation_id: allocationId });

export const officerSites = (search?: string, siteType?: string) =>
  call<OfficerSiteRow[]>("land_officer_sites", {
    p_search: search || null, p_site_type: siteType || null,
  });

export const siteHistory = (siteId: string) =>
  call<SiteHistory>("land_officer_site_history", { p_site_id: siteId });

export const registerSite = (site: {
  site_code: string; site_type: LandType; street_address: string;
  stand_number: string; village_section: string; village_name: string;
}) =>
  call<{ site_code: string }>("land_officer_register_site", {
    p_site_code: site.site_code, p_site_type: site.site_type,
    p_street_address: site.street_address, p_stand_number: site.stand_number || null,
    p_village_section: site.village_section || null, p_village_name: site.village_name || null,
  });

export const updateSite = (siteId: string, site: {
  site_type: LandType; street_address: string; stand_number: string;
  village_section: string; village_name: string; site_status: string;
}) =>
  call<{ site_code: string }>("land_officer_update_site", {
    p_site_id: siteId, p_site_type: site.site_type, p_street_address: site.street_address,
    p_stand_number: site.stand_number || null, p_village_section: site.village_section || null,
    p_village_name: site.village_name || null, p_site_status: site.site_status,
  });

export const setBurialStatus = (siteId: string, burialStatus: "usable" | "full" | "closed") =>
  call<{ site_code: string }>("land_officer_set_burial_status", {
    p_site_id: siteId, p_burial_status: burialStatus,
  });

export const officerAllocations = (status: string | null, landType?: string, search?: string) =>
  call<OfficerAllocationRow[]>("land_officer_allocations", {
    p_status: status, p_land_type: landType || null, p_search: search || null,
  });

export const officerPtos = (search?: string, status?: string) =>
  call<OfficerPtoRow[]>("land_officer_ptos", { p_search: search || null, p_status: status || null });

export const renewalRequests = (status: string | null = "pending") =>
  call<RenewalRow[]>("land_officer_renewal_requests", { p_status: status });

export const approveRenewal = (requestId: string) =>
  call<{ pto_number: string; expiry_date: string }>("land_officer_approve_renewal", {
    p_request_id: requestId,
  });

export const declineRenewal = (requestId: string, reason: string) =>
  call<{ decline_reason: string }>("land_officer_decline_renewal", {
    p_request_id: requestId, p_reason: reason,
  });

export const revokePto = (ptoId: string, reason: string) =>
  call<{ pto_number: string }>("land_officer_revoke_pto", { p_pto_id: ptoId, p_reason: reason });

export const releaseAllocation = (allocationId: string, reason: string) =>
  call<{ site_code: string; site_status: string }>("land_officer_release_allocation", {
    p_allocation_id: allocationId, p_reason: reason,
  });

export const successionCandidates = (allocationId: string) =>
  call<SuccessionCandidate[]>("land_officer_succession_candidates", { p_allocation_id: allocationId });

export const recordSuccession = (allocationId: string, successorId: string, reason: string) =>
  call<{ successor: string; pto_number: string }>("land_officer_record_succession", {
    p_allocation_id: allocationId, p_successor_id: successorId, p_reason: reason || null,
  });

export const returnToAuthority = (allocationId: string, reason: string) =>
  call<{ site_code: string }>("land_officer_return_to_authority", {
    p_allocation_id: allocationId, p_reason: reason,
  });
