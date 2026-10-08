-- =====================================================================
-- DESTRUCTIVE AND IRREVERSIBLE — reset TAMS for a clean demonstration
--
-- Keeps only:
--   * the one active Council Administrator's auth.users row;
--   * that administrator's public.user_accounts row, active;
--   * that administrator's public.staff row;
--   * seeded roles, database structure, functions, policies and jobs;
--   * the empty resident-verification-documents bucket.
--
-- Permanently removes every other Auth user/account/staff record and every
-- operational row, including resident, household, land, council, message,
-- notification and audit-history data.
--
-- BEFORE RUNNING:
--   1. Run preview_demonstration_reset.sql and confirm exactly one row says
--      "KEEP — sole active account after reset".
--   2. In Supabase Storage, empty the resident-verification-documents bucket.
--      This script refuses to run while files remain because deleting Storage
--      metadata with SQL would orphan the physical files.
--   3. On the set_config line below, replace
--      TYPE RESET TAMS FOR DEMONSTRATION
--      with
--      RESET TAMS FOR DEMONSTRATION
-- =====================================================================

begin;

select set_config(
  'tams.demo_reset_confirmation',
  'TYPE RESET TAMS FOR DEMONSTRATION',
  true
);

do $$
declare
  v_confirmation          text := current_setting('tams.demo_reset_confirmation', true);
  v_admin_account_id      uuid;
  v_admin_auth_user_id    uuid;
  v_admin_staff_id        uuid;
  v_admin_count           integer;
  v_storage_object_count  bigint;
  v_remaining             bigint;
begin
  if v_confirmation <> 'RESET TAMS FOR DEMONSTRATION' then
    raise exception
      'Reset not confirmed. Read the instructions and edit the confirmation line first.';
  end if;

  lock table public.user_accounts, public.staff, auth.users in share row exclusive mode;

  select count(*)
    into v_admin_count
  from public.user_accounts ua
  join public.staff s on s.id = ua.staff_id
  join public.roles r on r.id = s.role_id
  join auth.users au on au.id = ua.auth_user_id
  where ua.account_type = 'staff'
    and ua.account_status = 'active'
    and r.role_name = 'Council Administrator';

  if v_admin_count <> 1 then
    raise exception
      'The reset requires exactly one active Council Administrator with an Auth user; found %.',
      v_admin_count;
  end if;

  select ua.id, ua.auth_user_id, s.id
    into v_admin_account_id, v_admin_auth_user_id, v_admin_staff_id
  from public.user_accounts ua
  join public.staff s on s.id = ua.staff_id
  join public.roles r on r.id = s.role_id
  join auth.users au on au.id = ua.auth_user_id
  where ua.account_type = 'staff'
    and ua.account_status = 'active'
    and r.role_name = 'Council Administrator';

  select count(*)::bigint
    into v_storage_object_count
  from storage.objects
  where bucket_id = 'resident-verification-documents';

  if v_storage_object_count <> 0 then
    raise exception
      'The verification-document bucket still contains % file(s). Empty it through Supabase Storage, then run this script again.',
      v_storage_object_count;
  end if;

  -- Communications, notifications and uploaded-document metadata.
  delete from public.resident_communication_recipients;
  delete from public.staff_message_recipients;
  delete from public.notification_email_deliveries;
  delete from public.pto_expiry_warnings;
  delete from public.notifications;
  delete from public.resident_communications;
  delete from public.staff_messages;
  delete from public.resident_request_documents;
  delete from public.resident_account_requests;

  -- Council record.
  delete from public.meeting_minutes_amendments;
  delete from public.meeting_minutes;
  delete from public.meeting_attendance;
  delete from public.project_milestones;
  delete from public.visibility_changes;
  delete from public.community_projects;
  delete from public.council_resolutions;
  delete from public.council_meetings;

  -- Land record and village relationships.
  delete from public.pto_renewal_requests;
  delete from public.ptos;
  delete from public.land_allocations;
  delete from public.land_applications;
  delete from public.family_relationships;

  -- Old audit rows reference staff who are about to be removed. The
  -- immutable trigger is disabled only inside this transaction; any failure
  -- rolls the data and trigger state back together.
  execute 'alter table public.audit_logs disable trigger audit_logs_immutable';
  delete from public.audit_logs;

  -- Break the staff self-references, then remove every non-administrator
  -- application account before removing its staff record and Auth identity.
  update public.staff
     set last_deactivated_at = null,
         last_deactivated_by_staff_id = null,
         last_deactivation_reason = null,
         last_reactivated_at = null,
         last_reactivated_by_staff_id = null,
         last_reactivation_reason = null;

  delete from public.user_accounts where id <> v_admin_account_id;
  delete from public.staff where id <> v_admin_staff_id;
  delete from auth.users where id <> v_admin_auth_user_id;

  -- Residents and households point at each other. Break that cycle after
  -- their accounts and all operational children have been removed.
  update public.households set head_resident_id = null;
  update public.residents set household_id = null;
  delete from public.residents;
  delete from public.households;
  delete from public.land_sites;

  -- Reset the kept administrator's visible application state while keeping
  -- the identity and password needed for the demonstration.
  update public.user_accounts
     set account_type = 'staff',
         account_status = 'active',
         staff_id = v_admin_staff_id,
         resident_id = null,
         last_login = null
   where id = v_admin_account_id;

  update public.staff
     set last_deactivated_at = null,
         last_deactivated_by_staff_id = null,
         last_deactivation_reason = null,
         last_reactivated_at = null,
         last_reactivated_by_staff_id = null,
         last_reactivation_reason = null
   where id = v_admin_staff_id;

  -- The reset itself should not become the first entry in a clean audit
  -- trail. Remove audit rows produced by the deletion statements, then put
  -- immutability back before committing.
  delete from public.audit_logs;
  execute 'alter table public.audit_logs enable trigger audit_logs_immutable';

  select
      (select count(*) from public.residents)
    + (select count(*) from public.households)
    + (select count(*) from public.family_relationships)
    + (select count(*) from public.resident_account_requests)
    + (select count(*) from public.resident_request_documents)
    + (select count(*) from public.land_sites)
    + (select count(*) from public.land_applications)
    + (select count(*) from public.land_allocations)
    + (select count(*) from public.ptos)
    + (select count(*) from public.pto_renewal_requests)
    + (select count(*) from public.council_meetings)
    + (select count(*) from public.meeting_attendance)
    + (select count(*) from public.meeting_minutes)
    + (select count(*) from public.meeting_minutes_amendments)
    + (select count(*) from public.council_resolutions)
    + (select count(*) from public.community_projects)
    + (select count(*) from public.project_milestones)
    + (select count(*) from public.visibility_changes)
    + (select count(*) from public.notifications)
    + (select count(*) from public.notification_email_deliveries)
    + (select count(*) from public.pto_expiry_warnings)
    + (select count(*) from public.resident_communications)
    + (select count(*) from public.resident_communication_recipients)
    + (select count(*) from public.staff_messages)
    + (select count(*) from public.staff_message_recipients)
    + (select count(*) from public.audit_logs)
    into v_remaining;

  if v_remaining <> 0 then
    raise exception
      'Reset verification found % operational row(s). No changes were committed.',
      v_remaining;
  end if;

  if (select count(*) from public.user_accounts) <> 1
     or (select count(*) from public.staff) <> 1
     or (select count(*) from auth.users) <> 1
     or not exists (
       select 1
       from public.user_accounts ua
       join public.staff s on s.id = ua.staff_id
       join public.roles r on r.id = s.role_id
       where ua.id = v_admin_account_id
         and ua.auth_user_id = v_admin_auth_user_id
         and ua.account_status = 'active'
         and r.role_name = 'Council Administrator'
     )
  then
    raise exception
      'The administrator preservation check failed. No changes were committed.';
  end if;

  raise notice
    'Demonstration reset complete. Council Administrator account kept: %.',
    (select email from public.user_accounts where id = v_admin_account_id);
end;
$$;

-- Remove any reversible-deactivation snapshots from the earlier workflow.
-- This schema is owned by TAMS maintenance scripts and is not application data.
drop schema if exists tams_private cascade;

commit;

select
  ua.email,
  s.employee_number,
  s.first_name || ' ' || s.last_name as full_name,
  r.role_name,
  ua.account_status,
  (select count(*) from public.user_accounts) as remaining_application_accounts,
  (select count(*) from auth.users) as remaining_auth_users,
  (select count(*) from public.audit_logs) as remaining_audit_rows
from public.user_accounts ua
join public.staff s on s.id = ua.staff_id
join public.roles r on r.id = s.role_id;

