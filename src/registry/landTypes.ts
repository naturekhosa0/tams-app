/** The four kinds of land TAMS allocates. Grazing is not among them. */

export const LAND_TYPES = ["residential", "farming", "business", "burial"] as const;
export type LandType = typeof LAND_TYPES[number];

export const LAND_TYPE_LABELS: Record<LandType, string> = {
  residential: "Residential",
  farming: "Farming",
  business: "Business",
  burial: "Burial",
};

/** What the permission to occupy is worth, and for how long. */
export const LAND_TYPE_TERMS: Record<LandType, string> = {
  residential: "Perpetual",
  farming: "5 years, renewable",
  business: "2 years, renewable",
  burial: "Perpetual",
};

export const RENEWABLE_LAND_TYPES: LandType[] = ["farming", "business"];

export const FARMING_TYPES = [
  { value: "crop", label: "Crop farming" },
  { value: "livestock", label: "Livestock farming" },
  { value: "mixed", label: "Mixed farming" },
  { value: "other", label: "Other" },
] as const;

export const BUSINESS_TYPES = [
  { value: "shop", label: "Shop" },
  { value: "restaurant", label: "Restaurant" },
  { value: "salon", label: "Salon" },
  { value: "workshop", label: "Workshop" },
  { value: "office", label: "Office" },
  { value: "other", label: "Other" },
] as const;

export type Eligibility = {
  eligible: boolean;
  problems: string[];
  resident_id: string;
  household_id: string | null;
  is_household_head: boolean;
  land_type: LandType;
};

export type LandApplicationRow = {
  application_reference: string;
  land_type: LandType;
  application_status: "pending" | "approved" | "declined" | "allocated";
  submitted_at: string;
  decline_reason: string | null;
};

export type LandAllocationRow = {
  allocation_reference: string;
  land_type: LandType;
  site_code: string;
  street_address: string;
  village_section: string | null;
  allocation_status: string;
  allocation_date: string;
  burial_status: string | null;
};

export type PtoRow = {
  pto_id: string;
  pto_number: string;
  land_type: LandType;
  site_code: string;
  issue_date: string;
  expiry_date: string | null;
  perpetual: boolean;
  effective_status: "active" | "expired" | "renewed" | "revoked" | "superseded";
  verification_token: string;
  renewable: boolean;
  renewal_pending: boolean;
};

export type ResidentLandPortal = {
  resident_id: string;
  household_id: string | null;
  is_household_head: boolean;
  eligibility: Record<LandType, Eligibility>;
  applications: LandApplicationRow[];
  allocations: LandAllocationRow[];
  ptos: PtoRow[];
};

export type PtoDocument = {
  pto_number: string;
  land_type: LandType;
  holder_name: string;
  household_code: string | null;
  site_code: string;
  stand_number: string | null;
  street_address: string;
  village_section: string | null;
  village_name: string | null;
  issue_date: string;
  expiry_date: string | null;
  perpetual: boolean;
  effective_status: string;
  verification_token: string;
};

export type PtoVerification =
  | { found: false }
  | {
    found: true;
    pto_number: string;
    land_type: LandType;
    holder_name: string;
    site_code: string;
    village_section: string | null;
    village_name: string | null;
    issue_date: string;
    expiry_date: string | null;
    perpetual: boolean;
    status: string;
  };

// ---- the Land Officer's side ----------------------------------------

export type OfficerApplicationRow = {
  application_id: string;
  application_reference: string;
  land_type: LandType;
  application_status: string;
  applicant_name: string;
  applicant_id_number: string;
  applicant_age: number;
  household_code: string;
  submitted_at: string;
  reviewed_at: string | null;
  decline_reason: string | null;
  allocated_site_code: string | null;
};

export type OfficerApplication = {
  application_id: string;
  application_reference: string;
  land_type: LandType;
  application_status: string;
  reason_for_application: string;
  intended_use: string | null;
  lives_with_household: boolean | null;
  farming_type: string | null;
  farming_activity: string | null;
  business_name: string | null;
  business_type: string | null;
  business_description: string | null;
  submitted_at: string;
  reviewed_at: string | null;
  decline_reason: string | null;
  applicant: {
    resident_id: string; full_name: string; id_number: string; date_of_birth: string;
    age: number; gender: string; resident_status: string; account_status: string | null;
  };
  household: {
    household_id: string; household_code: string; household_status: string;
    head_full_name: string | null; is_head: boolean;
    members: { full_name: string; resident_status: string; age: number }[];
  };
  family: { relationship_type: string; related_full_name: string; relationship_status: string }[];
  land_held: {
    allocation_reference: string; land_type: string; site_code: string;
    allocation_status: string; burial_status: string | null; held_by: string;
  }[];
  earlier_applications: {
    application_reference: string; land_type: string; application_status: string;
    submitted_at: string; decline_reason: string | null;
  }[];
  eligibility: Eligibility;
};

export type OfficerSiteRow = {
  site_id: string; site_code: string; site_type: LandType; site_status: string;
  burial_status: string | null; stand_number: string | null; street_address: string;
  village_section: string | null; village_name: string | null;
  current_holder: string | null; allocation_count: number;
};

export type AvailableSiteRow = {
  site_id: string; site_code: string; stand_number: string | null;
  street_address: string; village_section: string | null; village_name: string | null;
};

export type OfficerPtoRow = {
  pto_id: string; pto_number: string; land_type: LandType; site_code: string;
  holder_name: string | null; household_code: string | null;
  issue_date: string; expiry_date: string | null;
  stored_status: string; effective_status: string;
  allocation_id: string; allocation_status: string;
};

export type RenewalRow = {
  renewal_request_id: string; pto_number: string; land_type: LandType; site_code: string;
  holder_name: string | null; household_code: string | null; expiry_date: string | null;
  effective_status: string; requested_at: string; request_status: string;
  reason: string | null; decline_reason: string | null;
};

export type SuccessionCandidate = {
  resident_id: string; full_name: string; id_number: string; date_of_birth: string;
  age: number; relationship: string | null; eligible: boolean; problems: string[];
};

export type SiteHistory = {
  site_id: string; site_code: string; site_type: LandType; site_status: string;
  burial_status: string | null; stand_number: string | null; street_address: string;
  village_section: string | null; village_name: string | null;
  allocations: {
    allocation_id: string; allocation_reference: string; land_type: string;
    allocation_status: string; allocation_date: string; ended_at: string | null;
    end_reason: string | null; holder: string; household_code: string | null;
    application_reference: string | null; succeeds: string | null;
    ptos: {
      pto_number: string; issue_date: string; expiry_date: string | null;
      stored_status: string; effective_status: string; revocation_reason: string | null;
    }[];
  }[];
};

export type OfficerDashboard = {
  pending_applications: number; awaiting_allocation: number; available_sites: number;
  active_allocations: number; succession_pending: number; active_ptos: number;
  expired_ptos: number; pending_renewals: number; burial_plots_usable: number;
};

export type OfficerAllocationRow = {
  allocation_id: string; allocation_reference: string; land_type: LandType;
  site_id: string; site_code: string; street_address: string; village_section: string | null;
  burial_status: string | null; holder_resident_id: string | null; holder_name: string | null;
  household_id: string | null; household_code: string | null;
  allocation_status: string; allocation_date: string; ended_at: string | null; end_reason: string | null;
  pto_id: string | null; pto_number: string | null; pto_expiry_date: string | null;
  pto_effective_status: string | null;
};
