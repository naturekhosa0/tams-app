/** The Council Secretary's records, and what a resident sees of them. */

export const MEETING_TYPES = ["ordinary", "special", "emergency"] as const;
export type MeetingType = typeof MEETING_TYPES[number];

export const MEETING_TYPE_LABELS: Record<MeetingType, string> = {
  ordinary: "Ordinary",
  special: "Special",
  emergency: "Emergency",
};

export const MEETING_STATUSES = ["scheduled", "held", "cancelled"] as const;
export type MeetingStatus = typeof MEETING_STATUSES[number];

export const ATTENDANCE_STATUSES = [
  { value: "present", label: "Present" },
  { value: "absent", label: "Absent" },
  { value: "apology", label: "Apology" },
] as const;

export const RESOLUTION_STATUSES = ["active", "implemented", "withdrawn"] as const;
export const PROJECT_STATUSES = ["planned", "active", "completed", "cancelled"] as const;

/** Only three are ever stored. "Overdue" is worked out, never chosen. */
export const MILESTONE_STATUSES = [
  { value: "pending", label: "Pending" },
  { value: "in_progress", label: "In progress" },
  { value: "completed", label: "Completed" },
] as const;

export type EffectiveMilestoneStatus = "pending" | "in_progress" | "completed" | "overdue";

export const MILESTONE_LABELS: Record<EffectiveMilestoneStatus, string> = {
  pending: "Pending",
  in_progress: "In progress",
  completed: "Completed",
  overdue: "Overdue",
};

export type Visibility = "internal" | "public";

// ---- the Secretary's side --------------------------------------------

export type MeetingRow = {
  meeting_id: string;
  meeting_reference: string;
  title: string;
  meeting_type: MeetingType;
  meeting_date: string;
  start_time: string;
  venue: string;
  meeting_status: MeetingStatus;
  cancellation_reason: string | null;
  minutes_status: "draft" | "final" | null;
  resolution_count: number;
  attendee_count: number;
  present_count: number;
};

export type AttendanceRow = {
  attendance_id: string;
  attendee_name: string;
  role_or_capacity: string;
  attendance_status: "present" | "absent" | "apology";
};

export type AmendmentRow = {
  amendment_id: string;
  amendment_reference: string;
  amendment_text: string;
  reason: string;
  created_at: string;
  created_by: string | null;
};

export type MinutesRecord = {
  minutes_id: string;
  minutes_content: string;
  minutes_status: "draft" | "final";
  finalized_at: string | null;
  finalized_by: string | null;
  amendments: AmendmentRow[];
};

export type MeetingResolution = {
  resolution_id: string;
  resolution_reference: string;
  resolution_text: string;
  decision_date: string;
  resolution_status: string;
  visibility: Visibility;
  withdrawal_reason: string | null;
};

export type MeetingDetail = {
  meeting_id: string;
  meeting_reference: string;
  title: string;
  meeting_type: MeetingType;
  meeting_date: string;
  start_time: string;
  venue: string;
  agenda: string;
  meeting_status: MeetingStatus;
  cancellation_reason: string | null;
  created_by: string | null;
  created_at: string;
  attendance: AttendanceRow[];
  minutes: MinutesRecord | null;
  resolutions: MeetingResolution[];
};

export type ResolutionRow = {
  resolution_id: string;
  resolution_reference: string;
  resolution_text: string;
  decision_date: string;
  resolution_status: string;
  visibility: Visibility;
  withdrawal_reason: string | null;
  meeting_id: string;
  meeting_reference: string;
  meeting_title: string;
  minutes_status: "draft" | "final" | null;
  visible_to_residents: boolean;
  project_count: number;
};

export type ProjectRow = {
  project_id: string;
  project_reference: string;
  project_name: string;
  description: string;
  start_date: string;
  target_completion_date: string | null;
  project_status: string;
  visibility: Visibility;
  cancellation_reason: string | null;
  completed_on: string | null;
  resolution_id: string | null;
  resolution_reference: string | null;
  resolution_visibility: Visibility | null;
  milestone_count: number;
  completed_milestones: number;
  overdue_milestones: number;
};

export type MilestoneRecord = {
  milestone_id: string;
  title: string;
  description: string | null;
  due_date: string;
  milestone_status: "pending" | "in_progress" | "completed";
  effective_status: EffectiveMilestoneStatus;
  completed_at: string | null;
};

export type VisibilityChange = {
  from_visibility: Visibility;
  to_visibility: Visibility;
  reason: string | null;
  changed_at: string;
  changed_by: string | null;
};

export type ProjectDetail = {
  project_id: string;
  project_reference: string;
  project_name: string;
  description: string;
  start_date: string;
  target_completion_date: string | null;
  project_status: string;
  visibility: Visibility;
  cancellation_reason: string | null;
  completed_on: string | null;
  created_by: string | null;
  created_at: string;
  resolution: {
    resolution_id: string;
    resolution_reference: string;
    resolution_text: string;
    visibility: Visibility;
    resolution_status: string;
    meeting_reference: string;
  } | null;
  milestones: MilestoneRecord[];
  visibility_history: VisibilityChange[];
};

export type SecretaryDashboard = {
  upcoming_meetings: number;
  meetings_awaiting_minutes: number;
  draft_minutes: number;
  final_minutes: number;
  active_resolutions: number;
  public_resolutions: number;
  active_projects: number;
  planned_projects: number;
  public_projects: number;
  overdue_milestones: number;
  next_meeting: {
    meeting_id: string;
    meeting_reference: string;
    title: string;
    meeting_date: string;
    start_time: string;
    venue: string;
  } | null;
};

// ---- what a resident is given -----------------------------------------
//
// Deliberately small. These are the only shapes the database will hand a
// resident, and nothing is filtered out in the browser.

export type PublicResolution = {
  resolution_reference: string;
  resolution_text: string;
  decision_date: string;
  resolution_status: string;
};

export type PublicMilestone = {
  title: string;
  description: string | null;
  due_date: string;
  effective_status: EffectiveMilestoneStatus;
};

export type PublicProject = {
  project_reference: string;
  project_name: string;
  description: string;
  start_date: string;
  target_completion_date: string | null;
  project_status: string;
  resolution_reference: string | null;
  milestones: PublicMilestone[];
};

export type CommunityUpdates = {
  resolutions: PublicResolution[];
  projects: PublicProject[];
};
