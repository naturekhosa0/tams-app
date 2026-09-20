-- =====================================================================
-- TAMS — Council Administrator staff management tests
--
--   US-CA02  Change Staff Role
--   US-CA03  Deactivate Staff Account
--            Reactivate Staff Account
--
-- Runs after 02_foundation_tests.sql and uses the staff it created:
--   2026011 Nature Khosa    Council Administrator  active
--   2026022 Jane Doe        Registry Clerk         active
--   2026023 John Mabaso     Land Officer           active
--   2026024 Thandi Ngcobo   Council Secretary      active
--   2026025 Sipho Dlamini   Registry Clerk         active
-- =====================================================================

-- Test scaffolding: resolve ids whatever role the test is acting as.
create function tams_test.staff_id_of(p_employee_number text)
returns uuid language sql stable security definer as $$
  select id from public.staff where employee_number = p_employee_number;
$$;

create function tams_test.role_id_of(p_role_name text)
returns uuid language sql stable security definer as $$
  select id from public.roles where role_name = p_role_name;
$$;

create function tams_test.role_of(p_employee_number text)
returns text language sql stable security definer as $$
  select r.role_name from public.staff s join public.roles r on r.id = s.role_id
  where s.employee_number = p_employee_number;
$$;

create function tams_test.status_of(p_employee_number text)
returns text language sql stable security definer as $$
  select ua.account_status from public.user_accounts ua
  join public.staff s on s.id = ua.staff_id
  where s.employee_number = p_employee_number;
$$;

create table tams_test.snapshots (key text primary key, data jsonb);

create function tams_test.snapshot(p_key text, p_employee_number text)
returns void language sql volatile security definer as $$
  insert into tams_test.snapshots (key, data)
  select p_key, jsonb_build_object(
           'staff_id', s.id, 'employee_number', s.employee_number, 'email', s.email,
           'first_name', s.first_name, 'last_name', s.last_name,
           'contact_number', s.contact_number, 'created_at', s.created_at,
           'account_id', ua.id, 'auth_user_id', ua.auth_user_id,
           'account_email', ua.email, 'account_type', ua.account_type,
           'last_login', ua.last_login, 'role_id', s.role_id)
  from public.staff s join public.user_accounts ua on ua.staff_id = s.id
  where s.employee_number = p_employee_number
  on conflict (key) do update set data = excluded.data;
$$;

-- Everything a change of role or status must leave alone.
create function tams_test.unchanged_except_role(p_key text, p_employee_number text)
returns boolean language sql stable security definer as $$
  select (before.data - 'role_id') = (
    select jsonb_build_object(
             'staff_id', s.id, 'employee_number', s.employee_number, 'email', s.email,
             'first_name', s.first_name, 'last_name', s.last_name,
             'contact_number', s.contact_number, 'created_at', s.created_at,
             'account_id', ua.id, 'auth_user_id', ua.auth_user_id,
             'account_email', ua.email, 'account_type', ua.account_type,
             'last_login', ua.last_login)
    from public.staff s join public.user_accounts ua on ua.staff_id = s.id
    where s.employee_number = p_employee_number)
  from tams_test.snapshots before where before.key = p_key;
$$;

\set admin '(select id from auth.users where email = ''admin@ta.example'')'


-- =====================================================================
-- CHANGE STAFF ROLE (US-CA02)
-- =====================================================================

select tams_test.snapshot('2026022', '2026022');

select tams_test.check(
  'CHANGE ROLE 1 — Registry Clerk becomes a Land Officer',
  tams_test.run_as('authenticated', tams_test.uid_of('admin@ta.example'), $sql$
    select public.change_staff_role(
      (select id from public.staff where employee_number = '2026022'),
      (select id from public.roles where role_name = 'Land Officer'))
  $sql$) = 'OK'
);

select tams_test.check(
  'CHANGE ROLE 1a — the new role is the one now stored',
  tams_test.role_of('2026022') = 'Land Officer'
);

select tams_test.check(
  'CHANGE ROLE 1b — only the role changed: same staff record, account and Auth identity',
  tams_test.unchanged_except_role('2026022', '2026022')
);

select tams_test.check(
  'CHANGE ROLE 1c — the account is still active',
  tams_test.status_of('2026022') = 'active'
);

select tams_test.check(
  'CHANGE ROLE 2 — Land Officer becomes a Council Secretary',
  tams_test.run_as('authenticated', tams_test.uid_of('admin@ta.example'), $sql$
    select public.change_staff_role(
      (select id from public.staff where employee_number = '2026023'),
      (select id from public.roles where role_name = 'Council Secretary'))
  $sql$) = 'OK'
);

-- A separate statement: the update above is only visible to a new snapshot.
select tams_test.check(
  'CHANGE ROLE 2a — the new role is the one now stored',
  tams_test.role_of('2026023') = 'Council Secretary'
);

select tams_test.check(
  'CHANGE ROLE 3 — the role they already hold is refused',
  tams_test.run_as('authenticated', tams_test.uid_of('admin@ta.example'), $sql$
    select public.change_staff_role(
      (select id from public.staff where employee_number = '2026023'),
      (select id from public.roles where role_name = 'Council Secretary'))
  $sql$) = 'TA015'
);

select tams_test.check(
  'CHANGE ROLE 4 — the Council Administrator role is refused even when submitted by hand',
  tams_test.run_as('authenticated', tams_test.uid_of('admin@ta.example'), $sql$
    select public.change_staff_role(
      (select id from public.staff where employee_number = '2026024'),
      (select id from public.roles where role_name = 'Council Administrator'))
  $sql$) = 'TA014'
);

select tams_test.check(
  'CHANGE ROLE 4a — that staff member keeps the role they had',
  tams_test.role_of('2026024') = 'Council Secretary'
);

select tams_test.check(
  'CHANGE ROLE 5 — the Council Administrator''s own role cannot be changed',
  tams_test.run_as('authenticated', tams_test.uid_of('admin@ta.example'), $sql$
    select public.change_staff_role(
      (select id from public.staff where employee_number = '2026011'),
      (select id from public.roles where role_name = 'Registry Clerk'))
  $sql$) = 'TA011'
);

select tams_test.check(
  'CHANGE ROLE 5a — the Council Administrator still holds that role',
  tams_test.role_of('2026011') = 'Council Administrator'
);

-- A deactivated target, for the next check.
select tams_test.run_as('authenticated', tams_test.uid_of('admin@ta.example'), $sql$
  select public.deactivate_staff_account(
    (select id from public.staff where employee_number = '2026025'), 'Temporary, for a test')
$sql$);

select tams_test.check(
  'CHANGE ROLE 6 — a deactivated staff member''s role cannot be changed',
  tams_test.run_as('authenticated', tams_test.uid_of('admin@ta.example'), $sql$
    select public.change_staff_role(
      (select id from public.staff where employee_number = '2026025'),
      (select id from public.roles where role_name = 'Land Officer'))
  $sql$) = 'TA012'
);

select tams_test.check(
  'CHANGE ROLE 7 — an ordinary staff member cannot change anyone''s role',
  tams_test.run_as('authenticated', tams_test.uid_of('clerk@ta.example'), $sql$
    select public.change_staff_role(
      tams_test.staff_id_of('2026024'), tams_test.role_id_of('Land Officer'))
  $sql$) = '42501'
);

select tams_test.check(
  'CHANGE ROLE 7a — a signed-out visitor cannot change anyone''s role',
  tams_test.run_as('authenticated', null, $sql$
    select public.change_staff_role(
      tams_test.staff_id_of('2026024'), tams_test.role_id_of('Land Officer'))
  $sql$) = '42501'
);

select tams_test.check(
  'CHANGE ROLE 7b — the refused attempts changed nothing',
  tams_test.role_of('2026024') = 'Council Secretary'
);

select tams_test.check(
  'CHANGE ROLE 8 — an unknown staff member is refused',
  tams_test.run_as('authenticated', tams_test.uid_of('admin@ta.example'), $sql$
    select public.change_staff_role(
      '00000000-0000-0000-0000-000000000000'::uuid,
      (select id from public.roles where role_name = 'Land Officer'))
  $sql$) = 'TA010'
);

select tams_test.check(
  'CHANGE ROLE 9 — an unknown role is refused',
  tams_test.run_as('authenticated', tams_test.uid_of('admin@ta.example'), $sql$
    select public.change_staff_role(
      (select id from public.staff where employee_number = '2026024'),
      '00000000-0000-0000-0000-000000000000'::uuid)
  $sql$) = 'TA013'
);


-- =====================================================================
-- DEACTIVATE STAFF ACCOUNT (US-CA03)
-- =====================================================================

select tams_test.snapshot('2026022-active', '2026022');

select tams_test.check(
  'DEACTIVATE 8 — an active staff member is deactivated',
  tams_test.run_as('authenticated', tams_test.uid_of('admin@ta.example'), $sql$
    select public.deactivate_staff_account(
      (select id from public.staff where employee_number = '2026022'),
      'Staff member resigned')
  $sql$) = 'OK'
);

select tams_test.check(
  'DEACTIVATE 9 — the account status becomes deactivated',
  tams_test.status_of('2026022') = 'deactivated'
);

select tams_test.check(
  'DEACTIVATE 10 — their role is kept exactly as it was',
  tams_test.role_of('2026022') = 'Land Officer'
);

select tams_test.check(
  'DEACTIVATE 10a — nothing was deleted: staff record, account and Auth identity all remain',
  tams_test.unchanged_except_role('2026022-active', '2026022')
);

select tams_test.check(
  'DEACTIVATE 11 — they are refused their own record immediately',
  tams_test.query_as('authenticated', tams_test.uid_of('clerk@ta.example'),
    'select count(*)::text from public.staff') = '0'
);

select tams_test.check(
  'DEACTIVATE 11a — the system no longer treats them as staff',
  tams_test.query_as('authenticated', tams_test.uid_of('clerk@ta.example'),
    'select public.is_active_staff()::text') = 'false'
);

select tams_test.check(
  'DEACTIVATE 11b — their session is told access is refused, and why',
  tams_test.query_as('authenticated', tams_test.uid_of('clerk@ta.example'),
    $sql$select (public.current_staff_context() ->> 'access_granted') || '/' ||
                (public.current_staff_context() ->> 'account_status')$sql$)
  = 'false/deactivated'
);

select tams_test.check(
  'DEACTIVATE 11c — their old session cannot stamp a login',
  tams_test.query_as('authenticated', tams_test.uid_of('clerk@ta.example'),
    $sql$select coalesce(public.record_login()::text, 'refused')$sql$) = 'refused'
);

select tams_test.check(
  'DEACTIVATE 12 — deactivating the same account again is refused',
  tams_test.run_as('authenticated', tams_test.uid_of('admin@ta.example'), $sql$
    select public.deactivate_staff_account(
      (select id from public.staff where employee_number = '2026022'), 'Again')
  $sql$) = 'TA016'
);

select tams_test.check(
  'DEACTIVATE 13 — the Council Administrator cannot be deactivated',
  tams_test.run_as('authenticated', tams_test.uid_of('admin@ta.example'), $sql$
    select public.deactivate_staff_account(
      (select id from public.staff where employee_number = '2026011'), 'Trying it on')
  $sql$) = 'TA011'
);

select tams_test.check(
  'DEACTIVATE 13a — the Council Administrator is still active',
  tams_test.status_of('2026011') = 'active'
);

select tams_test.check(
  'DEACTIVATE 14 — the reason, the date and the administrator are recorded',
  (select s.last_deactivation_reason = 'Staff member resigned'
          and s.last_deactivated_at is not null
          and s.last_deactivated_by_staff_id = tams_test.staff_id_of('2026011')
   from public.staff s where s.employee_number = '2026022')
);

select tams_test.check(
  'DEACTIVATE 15 — a blank reason is refused',
  tams_test.run_as('authenticated', tams_test.uid_of('admin@ta.example'), $sql$
    select public.deactivate_staff_account(
      (select id from public.staff where employee_number = '2026024'), '   ')
  $sql$) = 'TA018'
);

select tams_test.check(
  'DEACTIVATE 15a — the refused attempt left that account active',
  tams_test.status_of('2026024') = 'active'
);

select tams_test.check(
  'DEACTIVATE 16 — an ordinary staff member cannot deactivate anyone',
  tams_test.run_as('authenticated', tams_test.uid_of('secretary@ta.example'), $sql$
    select public.deactivate_staff_account(tams_test.staff_id_of('2026024'), 'Not allowed')
  $sql$) = '42501'
);


-- =====================================================================
-- REACTIVATE STAFF ACCOUNT
-- =====================================================================

select tams_test.snapshot('2026022-deactivated', '2026022');

select tams_test.check(
  'REACTIVATE 21 — an already active account is refused',
  tams_test.run_as('authenticated', tams_test.uid_of('admin@ta.example'), $sql$
    select public.reactivate_staff_account(
      (select id from public.staff where employee_number = '2026024'), 'Nothing to do')
  $sql$) = 'TA017'
);

select tams_test.check(
  'REACTIVATE 22 — an ordinary staff member cannot reactivate an account',
  tams_test.run_as('authenticated', tams_test.uid_of('secretary@ta.example'), $sql$
    select public.reactivate_staff_account(tams_test.staff_id_of('2026022'), 'Not allowed')
  $sql$) = '42501'
);

select tams_test.check(
  'REACTIVATE 22a — the refused attempt left the account deactivated',
  tams_test.status_of('2026022') = 'deactivated'
);

select tams_test.check(
  'REACTIVATE 15 — a deactivated staff member is made active again',
  tams_test.run_as('authenticated', tams_test.uid_of('admin@ta.example'), $sql$
    select public.reactivate_staff_account(
      (select id from public.staff where employee_number = '2026022'),
      'Returned from leave')
  $sql$) = 'OK'
);

select tams_test.check(
  'REACTIVATE 15a — the account status is active again',
  tams_test.status_of('2026022') = 'active'
);

select tams_test.check(
  'REACTIVATE 16 — the same staff record, user account and Auth identity are kept',
  tams_test.unchanged_except_role('2026022-deactivated', '2026022')
);

select tams_test.check(
  'REACTIVATE 17 — their role is unchanged',
  tams_test.role_of('2026022') = 'Land Officer'
);

select tams_test.check(
  'REACTIVATE 18 — the reason, the date and the administrator are recorded',
  (select s.last_reactivation_reason = 'Returned from leave'
          and s.last_reactivated_at is not null
          and s.last_reactivated_by_staff_id = tams_test.staff_id_of('2026011')
   from public.staff s where s.employee_number = '2026022')
);

select tams_test.check(
  'REACTIVATE 18a — the earlier deactivation is still on record',
  (select s.last_deactivation_reason = 'Staff member resigned'
   from public.staff s where s.employee_number = '2026022')
);

select tams_test.check(
  'REACTIVATE 20 — they can use their account again straight away',
  tams_test.query_as('authenticated', tams_test.uid_of('clerk@ta.example'),
    $sql$select (public.current_staff_context() ->> 'access_granted') || '/' ||
                (public.current_staff_context() ->> 'role_name')$sql$)
  = 'true/Land Officer'
  and tams_test.query_as('authenticated', tams_test.uid_of('clerk@ta.example'),
        'select public.is_active_staff()::text') = 'true'
);

select tams_test.check(
  'REACTIVATE 20a — they can read their own staff record again',
  tams_test.query_as('authenticated', tams_test.uid_of('clerk@ta.example'),
    $sql$select string_agg(employee_number, ',') from public.staff$sql$) = '2026022'
);

select tams_test.check(
  'REACTIVATE 23 — a blank reason is refused',
  tams_test.run_as('authenticated', tams_test.uid_of('admin@ta.example'), $sql$
    select public.reactivate_staff_account(
      (select id from public.staff where employee_number = '2026025'), '')
  $sql$) = 'TA018'
);

select tams_test.check(
  'REACTIVATE 24 — the Council Administrator is not managed here',
  tams_test.run_as('authenticated', tams_test.uid_of('admin@ta.example'), $sql$
    select public.reactivate_staff_account(
      (select id from public.staff where employee_number = '2026011'), 'Trying it on')
  $sql$) = 'TA011'
);


-- =====================================================================
-- The staff list the administrator works from
-- =====================================================================

select tams_test.check(
  'STAFF LIST — the administrator row is marked as the Council Administrator',
  tams_test.query_as('authenticated', tams_test.uid_of('admin@ta.example'), $sql$
    select string_agg(employee_number, ',' order by employee_number)
    from public.admin_staff_accounts() where is_council_administrator
  $sql$) = '2026011'
);

select tams_test.check(
  'STAFF LIST — current roles and statuses are the ones just set',
  tams_test.query_as('authenticated', tams_test.uid_of('admin@ta.example'), $sql$
    select string_agg(employee_number || '=' || role_name || '/' || account_status, ' ' order by employee_number)
    from public.admin_staff_accounts()
  $sql$) = '2026011=Council Administrator/active '
        || '2026022=Land Officer/active '
        || '2026023=Council Secretary/active '
        || '2026024=Council Secretary/active '
        || '2026025=Registry Clerk/deactivated'
);

select tams_test.check(
  'STAFF LIST — the deactivation reason and who did it are shown',
  tams_test.query_as('authenticated', tams_test.uid_of('admin@ta.example'), $sql$
    select last_deactivation_reason || ' — ' || last_deactivated_by
    from public.admin_staff_accounts() where employee_number = '2026025'
  $sql$) = 'Temporary, for a test — Nature Khosa'
);
