-- =====================================================================
-- READ-ONLY PREVIEW — demonstration reset
--
-- Shows the one Council Administrator that would be kept, every account
-- that would be permanently removed, the current application row counts,
-- and whether the verification-document bucket still contains files.
-- Nothing in this file changes the database.
-- =====================================================================

select
  ua.id as user_account_id,
  ua.auth_user_id,
  ua.email,
  s.id as staff_id,
  s.employee_number,
  s.first_name || ' ' || s.last_name as full_name,
  r.role_name,
  ua.account_status,
  case
    when ua.account_type = 'staff'
      and ua.account_status = 'active'
      and r.role_name = 'Council Administrator'
      then 'KEEP — sole active account after reset'
    else 'PERMANENTLY DELETE — account, Auth user and related data'
  end as planned_action
from public.user_accounts ua
left join public.staff s on s.id = ua.staff_id
left join public.roles r on r.id = s.role_id
order by
  case when r.role_name = 'Council Administrator' and ua.account_status = 'active' then 0 else 1 end,
  ua.email;

select *
from (
  select 'auth.users' as table_name, count(*)::bigint as row_count from auth.users
  union all select 'public.user_accounts', count(*) from public.user_accounts
  union all select 'public.staff', count(*) from public.staff
  union all select 'public.residents', count(*) from public.residents
  union all select 'public.households', count(*) from public.households
  union all select 'public.family_relationships', count(*) from public.family_relationships
  union all select 'public.resident_account_requests', count(*) from public.resident_account_requests
  union all select 'public.resident_request_documents', count(*) from public.resident_request_documents
  union all select 'public.land_sites', count(*) from public.land_sites
  union all select 'public.land_applications', count(*) from public.land_applications
  union all select 'public.land_allocations', count(*) from public.land_allocations
  union all select 'public.ptos', count(*) from public.ptos
  union all select 'public.pto_renewal_requests', count(*) from public.pto_renewal_requests
  union all select 'public.council_meetings', count(*) from public.council_meetings
  union all select 'public.meeting_attendance', count(*) from public.meeting_attendance
  union all select 'public.meeting_minutes', count(*) from public.meeting_minutes
  union all select 'public.meeting_minutes_amendments', count(*) from public.meeting_minutes_amendments
  union all select 'public.council_resolutions', count(*) from public.council_resolutions
  union all select 'public.community_projects', count(*) from public.community_projects
  union all select 'public.project_milestones', count(*) from public.project_milestones
  union all select 'public.visibility_changes', count(*) from public.visibility_changes
  union all select 'public.notifications', count(*) from public.notifications
  union all select 'public.notification_email_deliveries', count(*) from public.notification_email_deliveries
  union all select 'public.pto_expiry_warnings', count(*) from public.pto_expiry_warnings
  union all select 'public.resident_communications', count(*) from public.resident_communications
  union all select 'public.resident_communication_recipients', count(*) from public.resident_communication_recipients
  union all select 'public.staff_messages', count(*) from public.staff_messages
  union all select 'public.staff_message_recipients', count(*) from public.staff_message_recipients
  union all select 'public.audit_logs', count(*) from public.audit_logs
) counts
order by table_name;

select
  count(*)::bigint as verification_files_to_empty_first
from storage.objects
where bucket_id = 'resident-verification-documents';

