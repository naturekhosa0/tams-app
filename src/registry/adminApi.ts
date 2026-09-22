// Notifications, official communications, internal staff messaging,
// the audit trail and Administrator Transfer.
//
// Every one of these is a database function that establishes its own
// caller from auth.uid() and rechecks the rules for itself. Nothing
// here is trusted; this layer only shapes the calls.

import { supabase } from "../lib/supabaseClient";

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
        "The notification and audit migrations need to be applied to the Supabase project.",
    };
  }
  return { ok: false, code: error.code ?? "unknown", message };
}

async function call<T>(name: string, args: Record<string, unknown> = {}): Promise<Result<T>> {
  const { data, error } = await supabase.rpc(name, args);
  if (error) return failure(error);
  return { ok: true, data: data as T };
}

// ---- notifications ----------------------------------------------------

export const NOTIFICATION_LABELS: Record<string, string> = {
  account: "Account",
  land_application: "Land application",
  land_allocation: "Allocation",
  pto: "Permission to occupy",
  pto_renewal: "Renewal",
  community: "Community",
  official_notice: "Official notice",
  staff_message: "Message",
  work_request: "Work request",
  administration: "Administration",
};

export type NotificationRow = {
  notification_id: string;
  notification_category: string;
  title: string;
  message: string;
  link_path: string | null;
  source_entity_type: string | null;
  source_reference: string | null;
  created_at: string;
  read_at: string | null;
  archived_at: string | null;
};

export const myNotifications = (scope: "inbox" | "archived" | "all" = "inbox") =>
  call<NotificationRow[]>("my_notifications", { p_scope: scope, p_limit: 200 });

export const unreadCount = () => call<number>("my_unread_notification_count");
export const markRead = (id: string) => call<unknown>("mark_notification_read", { p_notification_id: id });
export const markAllRead = () => call<{ marked_read: number }>("mark_all_notifications_read");
export const archiveNotification = (id: string) =>
  call<unknown>("archive_notification", { p_notification_id: id });

// ---- official communications to residents ------------------------------

export const COMMUNICATION_TYPES = [
  { value: "community_announcement", label: "Community announcement" },
  { value: "individual_notice", label: "Individual notice" },
  { value: "summons", label: "Summons" },
  { value: "general_notice", label: "General notice" },
] as const;

export const AUDIENCE_TYPES = [
  { value: "all_active_residents", label: "All active residents" },
  { value: "one_resident", label: "One resident" },
  { value: "selected_residents", label: "Selected residents" },
] as const;

export const ON_BEHALF_OF = [
  "Chief", "Traditional Council", "Headman", "Headwoman", "Council Secretary",
] as const;

export type ResidentSearchRow = {
  resident_id: string;
  full_name: string;
  id_number: string;
  household_code: string | null;
  street_address: string | null;
  has_account: boolean;
};

export type CommunicationRow = {
  communication_id: string;
  communication_reference: string;
  communication_type: string;
  audience_type: string;
  subject: string;
  message: string;
  issued_on_behalf_of: string | null;
  event_date: string | null;
  event_time: string | null;
  venue: string | null;
  related_reference: string | null;
  recipient_count: number;
  created_at: string;
  sent_by: string;
};

export type CommunicationRecipient = {
  full_name: string;
  id_number: string;
  household_code: string | null;
  read_at: string | null;
};

export const searchResidents = (search: string) =>
  call<ResidentSearchRow[]>("secretary_search_residents", { p_search: search || null });

export const sendCommunication = (form: {
  communication_type: string;
  audience_type: string;
  subject: string;
  message: string;
  resident_ids: string[];
  issued_on_behalf_of: string;
  event_date: string;
  event_time: string;
  venue: string;
  related_entity_type: string;
  related_entity_id: string;
}) =>
  call<{ communication_reference: string; recipient_count: number }>(
    "secretary_send_communication", {
      p_communication_type: form.communication_type,
      p_audience_type: form.audience_type,
      p_subject: form.subject,
      p_message: form.message,
      p_resident_ids: form.resident_ids.length > 0 ? form.resident_ids : null,
      p_issued_on_behalf_of: form.issued_on_behalf_of || null,
      p_event_date: form.event_date || null,
      p_event_time: form.event_time || null,
      p_venue: form.venue || null,
      p_related_entity_type: form.related_entity_type || null,
      p_related_entity_id: form.related_entity_id || null,
    });

export const sentCommunications = (type?: string, search?: string) =>
  call<CommunicationRow[]>("secretary_communications", {
    p_type: type || null, p_search: search || null,
  });

export const communicationRecipients = (id: string) =>
  call<CommunicationRecipient[]>("secretary_communication_recipients", { p_communication_id: id });

// ---- internal staff messaging -------------------------------------------

export const MESSAGE_KINDS = [
  { value: "normal", label: "Normal" },
  { value: "action_required", label: "Action required" },
  { value: "announcement", label: "Announcement" },
] as const;

export const LINKABLE_RECORDS = [
  { value: "", label: "Nothing" },
  { value: "resident", label: "Resident" },
  { value: "household", label: "Household" },
  { value: "resident_account_request", label: "Resident verification request" },
  { value: "land_application", label: "Land application" },
  { value: "land_allocation", label: "Land allocation" },
  { value: "pto", label: "Permission to occupy" },
  { value: "meeting", label: "Meeting" },
  { value: "resolution", label: "Resolution" },
  { value: "project", label: "Project" },
] as const;

export type MessageRow = {
  message_id: string;
  message_reference: string;
  subject: string;
  message_kind: string;
  target_type: string;
  related_entity_type: string | null;
  related_reference: string | null;
  action_status: string | null;
  created_at: string;
  sender_name: string;
  sender_role: string | null;
  read_at: string | null;
  archived_at: string | null;
  recipient_count: number;
  acknowledged_by: string | null;
  resolved_by: string | null;
};

export type MessageDetail = {
  message_id: string;
  message_reference: string;
  subject: string;
  body: string;
  message_kind: string;
  target_type: string;
  created_at: string;
  sender_name: string;
  sender_role: string | null;
  is_sender: boolean;
  target_role: string | null;
  related_entity_type: string | null;
  related_entity_id: string | null;
  related_reference: string | null;
  action_status: string | null;
  acknowledged_by: string | null;
  acknowledged_at: string | null;
  acknowledged_by_me: boolean;
  resolved_by: string | null;
  resolved_at: string | null;
  am_recipient: boolean;
  read_at: string | null;
  archived_at: string | null;
  recipients: { name: string; role: string | null; read_at: string | null }[];
};

export type MessageTargets = {
  may_announce: boolean;
  staff: { staff_id: string; full_name: string; role: string }[];
  roles: { role_id: string; role_name: string; active_members: number }[];
};

export const messageList = (box: "inbox" | "sent" | "archived") =>
  call<MessageRow[]>("staff_messages_list", { p_box: box });

export const messageDetail = (id: string) => call<MessageDetail>("staff_message", { p_message_id: id });

export const messageTargets = () => call<MessageTargets>("staff_message_targets");

export const sendMessage = (form: {
  subject: string;
  body: string;
  target_type: string;
  message_kind: string;
  target_staff_id: string;
  target_role_id: string;
  related_entity_type: string;
  related_entity_id: string;
}) =>
  call<{ message_id: string; message_reference: string; recipient_count: number }>(
    "staff_send_message", {
      p_subject: form.subject,
      p_body: form.body,
      p_target_type: form.target_type,
      p_message_kind: form.message_kind,
      p_target_staff_id: form.target_staff_id || null,
      p_target_role_id: form.target_role_id || null,
      p_related_entity_type: form.related_entity_type || null,
      p_related_entity_id: form.related_entity_id || null,
    });

export const acknowledgeRequest = (id: string) =>
  call<{ message_reference: string }>("staff_acknowledge_request", { p_message_id: id });
export const resolveRequest = (id: string) =>
  call<{ message_reference: string }>("staff_resolve_request", { p_message_id: id });
export const markMessageRead = (id: string) =>
  call<unknown>("staff_mark_message_read", { p_message_id: id });
export const archiveMessage = (id: string, archived = true) =>
  call<unknown>("staff_archive_message", { p_message_id: id, p_archived: archived });

// ---- the audit trail -----------------------------------------------------

export type AuditRow = {
  audit_id: string;
  created_at: string;
  actor_label: string | null;
  actor_role: string | null;
  action: string;
  entity_type: string;
  entity_id: string | null;
  entity_reference: string | null;
  changed_fields: string[] | null;
  reason: string | null;
  event_group_id: string | null;
};

export type AuditDetail = {
  audit_id: string;
  created_at: string;
  actor_label: string | null;
  actor_role: string | null;
  actor_account_type: string | null;
  actor_employee_number: string | null;
  action: string;
  entity_type: string;
  entity_id: string | null;
  entity_reference: string | null;
  old_values: Record<string, unknown> | null;
  new_values: Record<string, unknown> | null;
  changed_fields: string[] | null;
  reason: string | null;
  event_group_id: string | null;
  related: { audit_id: string; action: string; entity_type: string; entity_reference: string | null }[];
};

export type AuditFilters = {
  actions: string[];
  entity_types: string[];
  actor_roles: string[];
  total: number;
};

export const auditLogs = (filters: {
  from?: string; to?: string; actor?: string; actorRole?: string;
  action?: string; entityType?: string; reference?: string; limit?: number;
}) =>
  call<AuditRow[]>("admin_audit_logs", {
    p_from: filters.from || null,
    p_to: filters.to || null,
    p_actor: filters.actor || null,
    p_actor_role: filters.actorRole || null,
    p_action: filters.action || null,
    p_entity_type: filters.entityType || null,
    p_reference: filters.reference || null,
    p_limit: filters.limit ?? 200,
  });

export const auditLog = (id: string) => call<AuditDetail>("admin_audit_log", { p_audit_id: id });
export const auditFilterValues = () => call<AuditFilters>("admin_audit_filters");

// ---- Administrator Transfer ----------------------------------------------

export type TransferCandidate = {
  staff_id: string;
  employee_number: string;
  full_name: string;
  email: string;
  role_name: string;
  account_status: string;
};

export const transferCandidates = () => call<TransferCandidate[]>("admin_transfer_candidates");

export const transferAdministrator = (
  incomingStaffId: string,
  outcome: "remain_staff" | "deactivate",
  reason: string,
  outgoingRoleId: string | null,
) =>
  call<{
    outgoing_name: string; outgoing_outcome: string; outgoing_new_role: string | null;
    incoming_name: string; incoming_previous_role: string; active_administrators: number;
  }>("transfer_council_administrator", {
    p_incoming_staff_id: incomingStaffId,
    p_outgoing_outcome: outcome,
    p_reason: reason,
    p_outgoing_role_id: outgoingRoleId,
  });
