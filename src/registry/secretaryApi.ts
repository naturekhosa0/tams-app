// The Council Secretary's records, and the resident's read-only view.
//
// Every one of these is a database function that establishes its own
// caller from auth.uid() and rechecks the rules for itself. Nothing
// here is trusted; this layer only shapes the calls.

import { supabase } from "../lib/supabaseClient";
import type {
  CommunityUpdates, MeetingDetail, MeetingRow, ProjectDetail, ProjectRow,
  ResolutionRow, SecretaryDashboard, VisibilityChange,
} from "./secretaryTypes";

export type Result<T> = { ok: true; data: T } | { ok: false; code: string; message: string };

function failure(error: { code?: string; message: string }): Result<never> {
  const message = (error.message ?? "Something went wrong.").replace(/^[A-Z0-9]{5}:\s*/, "").trim();
  if (error.code === "42501") {
    return { ok: false, code: "42501", message: "You are not allowed to do that." };
  }
  if (error.code === "PGRST202") {
    return {
      ok: false, code: "PGRST202",
      message: "This part of the system is not installed on the database yet. " +
        "The council migrations need to be applied to the Supabase project.",
    };
  }
  return { ok: false, code: error.code ?? "unknown", message };
}

async function call<T>(name: string, args: Record<string, unknown> = {}): Promise<Result<T>> {
  const { data, error } = await supabase.rpc(name, args);
  if (error) return failure(error);
  return { ok: true, data: data as T };
}

// ---- dashboard --------------------------------------------------------

export const secretaryDashboard = () => call<SecretaryDashboard>("secretary_dashboard");

// ---- meetings ---------------------------------------------------------

export const meetings = (status?: string, type?: string, when?: string, search?: string) =>
  call<MeetingRow[]>("secretary_meetings", {
    p_status: status || null, p_type: type || null,
    p_when: when || null, p_search: search || null,
  });

export const meeting = (meetingId: string) =>
  call<MeetingDetail>("secretary_meeting", { p_meeting_id: meetingId });

export const scheduleMeeting = (form: {
  title: string; meeting_type: string; meeting_date: string;
  start_time: string; venue: string; agenda: string;
}) =>
  call<{ meeting_id: string; meeting_reference: string }>("secretary_schedule_meeting", {
    p_title: form.title, p_meeting_type: form.meeting_type, p_meeting_date: form.meeting_date,
    p_start_time: form.start_time, p_venue: form.venue, p_agenda: form.agenda,
  });

export const updateMeeting = (meetingId: string, form: {
  title: string; meeting_type: string; meeting_date: string;
  start_time: string; venue: string; agenda: string;
}) =>
  call<{ meeting_reference: string }>("secretary_update_meeting", {
    p_meeting_id: meetingId, p_title: form.title, p_meeting_type: form.meeting_type,
    p_meeting_date: form.meeting_date, p_start_time: form.start_time,
    p_venue: form.venue, p_agenda: form.agenda,
  });

export const setMeetingStatus = (meetingId: string, status: string, reason?: string) =>
  call<{ meeting_reference: string; meeting_status: string }>("secretary_set_meeting_status", {
    p_meeting_id: meetingId, p_status: status, p_reason: reason || null,
  });

// ---- attendance -------------------------------------------------------

export const addAttendee = (
  meetingId: string, name: string, capacity: string, status: string,
) =>
  call<{ attendance_id: string; attendee_name: string }>("secretary_add_attendee", {
    p_meeting_id: meetingId, p_attendee_name: name,
    p_role_or_capacity: capacity, p_attendance_status: status,
  });

export const updateAttendee = (
  attendanceId: string, name: string, capacity: string, status: string,
) =>
  call<{ attendance_id: string }>("secretary_update_attendee", {
    p_attendance_id: attendanceId, p_attendee_name: name,
    p_role_or_capacity: capacity, p_attendance_status: status,
  });

// ---- minutes ----------------------------------------------------------

export const saveMinutes = (meetingId: string, content: string) =>
  call<{ minutes_id: string; minutes_status: string }>("secretary_save_minutes", {
    p_meeting_id: meetingId, p_content: content,
  });

export const finalizeMinutes = (meetingId: string) =>
  call<{ minutes_id: string; finalized_at: string }>("secretary_finalize_minutes", {
    p_meeting_id: meetingId,
  });

export const addAmendment = (minutesId: string, text: string, reason: string) =>
  call<{ amendment_reference: string }>("secretary_add_amendment", {
    p_minutes_id: minutesId, p_amendment_text: text, p_reason: reason,
  });

// ---- resolutions ------------------------------------------------------

export const resolutions = (status?: string, visibility?: string, search?: string) =>
  call<ResolutionRow[]>("secretary_resolutions", {
    p_status: status || null, p_visibility: visibility || null, p_search: search || null,
  });

// The decision date is not a parameter: it comes from the meeting.
export const recordResolution = (meetingId: string, text: string, visibility: string) =>
  call<{ resolution_reference: string; decision_date: string }>("secretary_record_resolution", {
    p_meeting_id: meetingId, p_resolution_text: text, p_visibility: visibility,
  });

export const updateResolution = (resolutionId: string, text: string) =>
  call<{ resolution_reference: string }>("secretary_update_resolution", {
    p_resolution_id: resolutionId, p_resolution_text: text,
  });

export const setResolutionStatus = (resolutionId: string, status: string, reason?: string) =>
  call<{ resolution_reference: string; resolution_status: string }>(
    "secretary_set_resolution_status",
    { p_resolution_id: resolutionId, p_status: status, p_reason: reason || null });

export const setResolutionVisibility = (
  resolutionId: string, visibility: string, reason?: string,
) =>
  call<{ resolution_reference: string; visibility: string }>(
    "secretary_set_resolution_visibility",
    { p_resolution_id: resolutionId, p_visibility: visibility, p_reason: reason || null });

export const resolutionVisibilityHistory = (resolutionId: string) =>
  call<VisibilityChange[]>("secretary_resolution_visibility_history", {
    p_resolution_id: resolutionId,
  });

// ---- projects ---------------------------------------------------------

export const projects = (status?: string, visibility?: string, search?: string) =>
  call<ProjectRow[]>("secretary_projects", {
    p_status: status || null, p_visibility: visibility || null, p_search: search || null,
  });

export const project = (projectId: string) =>
  call<ProjectDetail>("secretary_project", { p_project_id: projectId });

export const createProject = (form: {
  project_name: string; description: string; start_date: string;
  target_completion_date: string; resolution_id: string; visibility: string;
}) =>
  call<{ project_id: string; project_reference: string }>("secretary_create_project", {
    p_project_name: form.project_name, p_description: form.description,
    p_start_date: form.start_date,
    p_target_completion_date: form.target_completion_date || null,
    p_resolution_id: form.resolution_id || null, p_visibility: form.visibility,
  });

export const updateProject = (projectId: string, form: {
  project_name: string; description: string; start_date: string;
  target_completion_date: string; resolution_id: string;
}) =>
  call<{ project_reference: string }>("secretary_update_project", {
    p_project_id: projectId, p_project_name: form.project_name,
    p_description: form.description, p_start_date: form.start_date,
    p_target_completion_date: form.target_completion_date || null,
    p_resolution_id: form.resolution_id || null,
  });

export const setProjectStatus = (projectId: string, status: string, reason?: string) =>
  call<{ project_reference: string; project_status: string }>("secretary_set_project_status", {
    p_project_id: projectId, p_status: status, p_reason: reason || null,
  });

export const setProjectVisibility = (projectId: string, visibility: string, reason?: string) =>
  call<{ project_reference: string; visibility: string }>("secretary_set_project_visibility", {
    p_project_id: projectId, p_visibility: visibility, p_reason: reason || null,
  });

// ---- milestones -------------------------------------------------------

export const addMilestone = (
  projectId: string, title: string, dueDate: string, description: string,
) =>
  call<{ milestone_id: string; title: string }>("secretary_add_milestone", {
    p_project_id: projectId, p_title: title, p_due_date: dueDate,
    p_description: description || null,
  });

export const updateMilestone = (
  milestoneId: string, title: string, dueDate: string, description: string,
) =>
  call<{ milestone_id: string }>("secretary_update_milestone", {
    p_milestone_id: milestoneId, p_title: title, p_due_date: dueDate,
    p_description: description || null,
  });

export const setMilestoneStatus = (milestoneId: string, status: string) =>
  call<{ milestone_status: string; effective_status: string }>("secretary_set_milestone_status", {
    p_milestone_id: milestoneId, p_status: status,
  });

// ---- what a resident may read -----------------------------------------

export const communityUpdates = () => call<CommunityUpdates>("resident_community_updates");
