/** The one place the application learns anything about the signed-in user. */
export type StaffContext = {
  account_id: string;
  email: string;
  account_type: string;
  account_status: "active" | "deactivated";
  last_login: string | null;
  staff_id: string | null;
  employee_number: string | null;
  first_name: string | null;
  last_name: string | null;
  full_name: string | null;
  contact_number: string | null;
  role_name: string | null;
  is_council_administrator: boolean;
  access_granted: boolean;
};

export type AssignableRole = {
  id: string;
  role_name: string;
  description: string | null;
};

export type DashboardStats = {
  staff_records: number;
  active_staff: number;
  deactivated: number;
  awaiting_setup: number;
  active_by_role: { role_name: string; count: number }[];
};

export type StaffAccountRow = {
  account_id: string;
  email: string;
  account_status: "active" | "deactivated";
  account_created_at: string;
  last_login: string | null;
  staff_id: string;
  employee_number: string;
  first_name: string;
  last_name: string;
  contact_number: string;
  role_id: string;
  role_name: string;
  invitation_completed: boolean;
  is_council_administrator: boolean;
  last_deactivated_at: string | null;
  last_deactivation_reason: string | null;
  last_deactivated_by: string | null;
  last_reactivated_at: string | null;
  last_reactivation_reason: string | null;
  last_reactivated_by: string | null;
};

/** The three things a Council Administrator can do to a staff account. */
export type StaffAction = "change_role" | "deactivate" | "reactivate";
