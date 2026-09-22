-- =====================================================================
-- TAMS — resetting a password
--
-- The reset itself belongs to Supabase Auth and cannot be exercised
-- here. What can be — and what matters — is the boundary around it: a
-- password changing must move nothing on the TAMS side, and the one
-- line it leaves in the audit trail must carry nothing that could be
-- replayed.
-- =====================================================================

-- ---- helpers ---------------------------------------------------------

create function tams_test.auth_user_of(p_email text) returns uuid
language sql stable security definer as $$
  select ua.auth_user_id from public.user_accounts ua where ua.email = p_email;
$$;

-- What Supabase does when somebody finishes a reset: the hashed
-- password in auth.users changes, and nothing else anywhere.
create function tams_test.change_password(p_email text) returns void
language sql volatile security definer as $$
  update auth.users set encrypted_password = 'hashed-' || gen_random_uuid()::text
  where id = tams_test.auth_user_of(p_email);
$$;

create function tams_test.account_snapshot(p_email text) returns text
language sql stable security definer as $$
  select ua.account_type || '|' || ua.account_status || '|' ||
         coalesce(ua.resident_id::text, '-') || '|' || coalesce(ua.staff_id::text, '-')
  from public.user_accounts ua where ua.email = p_email;
$$;

create function tams_test.audit_rows() returns int
language sql stable security definer as $$
  select count(*)::int from public.audit_logs;
$$;

-- A resident and a staff member whose accounts are known to be active
-- at this point in the suite.
create function tams_test.reset_resident_email() returns text
language sql stable security definer as $$
  select ua.email from public.user_accounts ua
  join public.residents r on r.id = ua.resident_id
  where r.id_number = 'SYN0000000028' and ua.account_type = 'resident';
$$;


-- =====================================================================
-- A PASSWORD CHANGE MOVES NOTHING ELSE
-- =====================================================================

-- Take a picture of everything that must not move.
create table tams_test.before_reset as
  select ua.id, ua.email, ua.account_type, ua.account_status,
         ua.resident_id, ua.staff_id
  from public.user_accounts ua;

create table tams_test.before_reset_staff as
  select s.id, s.employee_number, s.role_id, s.first_name, s.last_name, s.email
  from public.staff s;

create table tams_test.before_reset_residents as
  select r.id, r.id_number, r.household_id, r.resident_status
  from public.residents r;

create table tams_test.before_reset_audit as
  select count(*) as rows from public.audit_logs;

-- Every account in the system resets its password.
do $$
declare v_email text;
begin
  for v_email in select email from public.user_accounts loop
    perform tams_test.change_password(v_email);
  end loop;
end;
$$;

select tams_test.check(
  'PWD 9 — a password change leaves every user_accounts field exactly as it was',
  (select count(*) = 0 from public.user_accounts ua
    join tams_test.before_reset b on b.id = ua.id
    where ua.account_type   is distinct from b.account_type
       or ua.account_status is distinct from b.account_status
       or ua.resident_id    is distinct from b.resident_id
       or ua.staff_id       is distinct from b.staff_id
       or ua.email          is distinct from b.email)
  and (select count(*) from public.user_accounts) = (select count(*) from tams_test.before_reset)
);

select tams_test.check(
  'PWD 10 — a resident''s linkage, household and status are untouched',
  (select count(*) = 0 from public.residents r
    join tams_test.before_reset_residents b on b.id = r.id
    where r.household_id     is distinct from b.household_id
       or r.resident_status  is distinct from b.resident_status
       or r.id_number        is distinct from b.id_number)
  and (select count(*) from public.residents) = (select count(*) from tams_test.before_reset_residents)
);

select tams_test.check(
  'PWD 11 — every staff member holds exactly the role they held before',
  (select count(*) = 0 from public.staff s
    join tams_test.before_reset_staff b on b.id = s.id
    where s.role_id         is distinct from b.role_id
       or s.employee_number is distinct from b.employee_number
       or s.email           is distinct from b.email)
);

select tams_test.check(
  'PWD 12 — a deactivated account is still deactivated, and is still refused',
  tams_test.status_of('2026073') = 'deactivated'
  -- exclerk@ta.example was a Registry Clerk; the new password changes none of that
  and tams_test.role_of('2026073') = 'Registry Clerk'
  and tams_test.run_as('authenticated', tams_test.uid_of('exclerk@ta.example'), $sql$
    select public.registry_search_residents('Ndlovu')
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.uid_of('exclerk@ta.example'), $sql$
    select count(*) from public.staff_messages_list('inbox')
  $sql$) = '42501'
  and tams_test.query_as('authenticated', tams_test.uid_of('exclerk@ta.example'), $sql$
    select public.current_user_account_id() is null
  $sql$) = 'true'
);

select tams_test.check(
  'PWD 12a — and a resident whose verification was declined is still declined',
  (select account_status = 'declined' from public.user_accounts
   where email = 'turneddown@village.example')
  and tams_test.run_as('authenticated', tams_test.declined_resident(), $sql$
    select public.resident_community_updates()
  $sql$) = '42501'
);

select tams_test.check(
  'PWD 9a — nothing in TAMS reacts to a password change at all',
  -- No trigger of ours sits on the table Supabase keeps passwords in…
  (select count(*) = 0 from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'auth' and c.relname = 'users' and not t.tgisinternal)
  -- …so all those resets wrote not one line of audit between them.
  and tams_test.audit_rows() = (select rows::int from tams_test.before_reset_audit)
);


-- =====================================================================
-- THE ONE LINE IT DOES LEAVE, WHEN THE PAGE ASKS FOR IT
-- =====================================================================

select tams_test.check(
  'PWD 15 — the page can record that a reset happened, as itself and nobody else',
  tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000028'), $sql$
    select public.record_password_reset()
  $sql$) = 'OK'
);

select tams_test.check(
  'PWD 15a — the record names the caller''s own account, and holds no values at all',
  (select actor_account_type = 'resident'
          and entity_type = 'user_account'
          and entity_reference = tams_test.reset_resident_email()
          and old_values is null
          and new_values is null
          and changed_fields is null
          and reason is null
          and actor_user_id = tams_test.resident_uid('SYN0000000028')
   from tams_test.latest_audit('PASSWORD_RESET_COMPLETED'))
);

select tams_test.check(
  'PWD 15b — no password, token or link is anywhere in the audit trail',
  -- No audited field is even named like one…
  (select count(*) = 0 from public.audit_logs a,
     lateral (select k from jsonb_object_keys(coalesce(a.new_values, '{}'::jsonb)) as k
              union all
              select k from jsonb_object_keys(coalesce(a.old_values, '{}'::jsonb)) as k) as keys
    where keys.k ~* '(password|token|secret|recovery_link)')
  -- …no stored value is one…
  and (select count(*) = 0 from public.audit_logs
        where coalesce(old_values::text, '') || coalesce(new_values::text, '')
              ilike any (array['%encrypted_password%', '%reset_token%',
                               '%access_token%', '%refresh_token%', '%/reset-password#%']))
  -- …and the hashes Supabase keeps never reached it.
  and (select count(*) = 0 from public.audit_logs a, auth.users u
        where u.encrypted_password is not null
          and coalesce(a.old_values::text, '') || coalesce(a.new_values::text, '')
              like '%' || u.encrypted_password || '%')
);

select tams_test.check(
  'PWD 15c — the function takes nothing from its caller, so nothing can be claimed',
  (select count(*) = 0 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'record_password_reset'
      and pg_get_function_arguments(p.oid) <> '')
  -- a signed-out caller gets nowhere
  and tams_test.run_as('anon', null, $sql$
    select public.record_password_reset()
  $sql$) in ('42501', '42883')
  -- and a session with no TAMS account behind it records nothing, and
  -- says nothing about whether such an account exists
  and tams_test.query_as('authenticated', tams_test.uid_of('stranger@ta.example'), $sql$
    select (public.record_password_reset() ->> 'recorded')
  $sql$) = 'false'
);

select tams_test.check(
  'PWD 15d — recording a reset changes nothing whatsoever about the account',
  (select count(*) = 0 from public.user_accounts ua
    join tams_test.before_reset b on b.id = ua.id
    where ua.account_type   is distinct from b.account_type
       or ua.account_status is distinct from b.account_status
       or ua.resident_id    is distinct from b.resident_id
       or ua.staff_id       is distinct from b.staff_id)
);


-- =====================================================================
-- REGRESSION — the flows that were already there
-- =====================================================================

select tams_test.check(
  'PWD 16 — the staff invitation path is untouched: an account is still created the same way',
  (select count(*) > 0 from public.user_accounts where account_type = 'staff')
  and (select count(*) = 0 from public.staff s
        where not exists (select 1 from public.user_accounts ua where ua.staff_id = s.id))
);

select tams_test.check(
  'PWD 17 — resident accounts and their verification still stand',
  (select count(*) > 0 from public.resident_account_requests where request_status = 'approved')
  and tams_test.query_as('authenticated', tams_test.resident_uid('SYN0000000028'), $sql$
    select public.current_user_account_id() is not null
  $sql$) = 'true'
  and tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000028'), $sql$
    select public.resident_community_updates()
  $sql$) = 'OK'
);

select tams_test.check(
  'PWD 18 — and the imported village register is still exactly as it was imported',
  (select count(*) = 20
   from public.land_allocations a join tams_test.imported_allocations i on i.id = a.id
   where a.allocation_reference = i.allocation_reference and a.resident_id = i.resident_id)
  and (select count(*) = 200
       from public.family_relationships f join tams_test.imported_relationships i on i.id = f.id)
);
