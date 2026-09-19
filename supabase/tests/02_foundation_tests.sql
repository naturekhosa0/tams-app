-- =====================================================================
-- TAMS foundation — database test suite
--
-- Covers the whole of this step's security surface:
--   * the one-time first Council Administrator bootstrap
--   * staff creation, and everything it must refuse
--   * Row Level Security for administrators, staff and signed-out users
--   * account_status as the single source of truth for access
-- =====================================================================

-- ---- Fixtures: the auth users that Supabase Auth would have created --
insert into auth.users (email, last_sign_in_at) values
  ('admin@ta.example',     now()),   -- created by hand before bootstrap
  ('clerk@ta.example',     now()),
  ('officer@ta.example',   now()),
  ('secretary@ta.example', now()),
  ('invited@ta.example',   null),    -- invited, has not signed in yet
  ('stranger@ta.example',  now());   -- an auth user with no staff record


-- =====================================================================
-- 1. First Council Administrator bootstrap
-- =====================================================================

select tams_test.check(
  '01 bootstrap creates the first Council Administrator',
  tams_test.run_as('service_role', null, $sql$
    select public.bootstrap_council_administrator(
      (select id from auth.users where email = 'admin@ta.example'),
      '2026011', 'Nature', 'Khosa', 'Admin@TA.example', '0728217377')
  $sql$) = 'OK'
);

select tams_test.check(
  '02 the administrator has a staff record with the Council Administrator role',
  (select count(*) = 1
     from public.staff s
     join public.roles r on r.id = s.role_id
    where s.employee_number = '2026011'
      and r.role_name = 'Council Administrator')
);

select tams_test.check(
  '03 the administrator has an active staff user account linked to the staff record',
  (select count(*) = 1
     from public.user_accounts ua
     join public.staff s on s.id = ua.staff_id
    where s.employee_number = '2026011'
      and ua.account_type = 'staff'
      and ua.account_status = 'active'
      and ua.auth_user_id = tams_test.uid_of('admin@ta.example'))
);

select tams_test.check(
  '04 the email address was normalised to lower case',
  (select email = 'admin@ta.example' from public.staff where employee_number = '2026011')
);

select tams_test.check(
  '05 bootstrap refuses to create a second Council Administrator',
  tams_test.run_as('service_role', null, $sql$
    select public.bootstrap_council_administrator(
      (select id from auth.users where email = 'stranger@ta.example'),
      '2026099', 'Second', 'Admin', 'stranger@ta.example', '0728217300')
  $sql$) = 'TA001'
);

select tams_test.check(
  '06 a second Council Administrator cannot be inserted directly either',
  tams_test.run_as('service_role', null, $sql$
    insert into public.staff (employee_number, first_name, last_name, email, contact_number, role_id)
    values ('2026098', 'Sneaky', 'Admin', 'sneaky@ta.example', '0728217301',
            (select id from public.roles where role_name = 'Council Administrator'))
  $sql$) = 'TA001'
);

select tams_test.check(
  '07 an ordinary staff member cannot run the bootstrap process',
  tams_test.run_as('authenticated', tams_test.uid_of('admin@ta.example'), $sql$
    select public.bootstrap_council_administrator(
      (select id from auth.users where email = 'stranger@ta.example'),
      '2026097', 'No', 'Way', 'stranger@ta.example', '0728217302')
  $sql$) = '42501'
);


-- =====================================================================
-- 2. Create Staff Account
-- =====================================================================

select tams_test.check(
  '08 a Registry Clerk can be created',
  tams_test.run_as('service_role', null, $sql$
    select public.create_staff_with_account(
      (select id from auth.users where email = 'clerk@ta.example'),
      '2026022', 'Jane', 'Doe', 'clerk@ta.example', '0728217377',
      (select id from public.roles where role_name = 'Registry Clerk'))
  $sql$) = 'OK'
);

select tams_test.check(
  '09 a Land Officer can be created',
  tams_test.run_as('service_role', null, $sql$
    select public.create_staff_with_account(
      (select id from auth.users where email = 'officer@ta.example'),
      '2026023', 'John', 'Mabaso', 'officer@ta.example', '0728217378',
      (select id from public.roles where role_name = 'Land Officer'))
  $sql$) = 'OK'
);

select tams_test.check(
  '10 a Council Secretary can be created',
  tams_test.run_as('service_role', null, $sql$
    select public.create_staff_with_account(
      (select id from auth.users where email = 'secretary@ta.example'),
      '2026024', 'Thandi', 'Ngcobo', 'secretary@ta.example', '0728217379',
      (select id from public.roles where role_name = 'Council Secretary'))
  $sql$) = 'OK'
);

select tams_test.check(
  '11 each new staff member has exactly one role and one active account',
  (select count(*) = 3
     from public.staff s
     join public.user_accounts ua on ua.staff_id = s.id
     join public.roles r on r.id = s.role_id
    where s.employee_number in ('2026022', '2026023', '2026024')
      and ua.account_type = 'staff'
      and ua.account_status = 'active'
      and r.role_name in ('Registry Clerk', 'Land Officer', 'Council Secretary'))
);

select tams_test.check(
  '12 a duplicate employee number is rejected',
  tams_test.run_as('service_role', null, $sql$
    select public.create_staff_with_account(
      (select id from auth.users where email = 'invited@ta.example'),
      '2026022', 'Copy', 'Cat', 'copycat@ta.example', '0728217380',
      (select id from public.roles where role_name = 'Registry Clerk'))
  $sql$) = '23505'
);

select tams_test.check(
  '13 a duplicate employee number is rejected regardless of spacing',
  tams_test.run_as('service_role', null, $sql$
    select public.create_staff_with_account(
      (select id from auth.users where email = 'invited@ta.example'),
      '  2026022  ', 'Copy', 'Cat', 'copycat2@ta.example', '0728217380',
      (select id from public.roles where role_name = 'Registry Clerk'))
  $sql$) = '23505'
);

select tams_test.check(
  '14 a duplicate email address is rejected',
  tams_test.run_as('service_role', null, $sql$
    select public.create_staff_with_account(
      (select id from auth.users where email = 'invited@ta.example'),
      '2026030', 'Copy', 'Cat', 'clerk@ta.example', '0728217380',
      (select id from public.roles where role_name = 'Registry Clerk'))
  $sql$) = '23505'
);

select tams_test.check(
  '15 a duplicate email address is rejected in a different case',
  tams_test.run_as('service_role', null, $sql$
    select public.create_staff_with_account(
      (select id from auth.users where email = 'invited@ta.example'),
      '2026031', 'Copy', 'Cat', 'CLERK@TA.example', '0728217380',
      (select id from public.roles where role_name = 'Registry Clerk'))
  $sql$) = '23505'
);

select tams_test.check(
  '16 a failed creation leaves no half-made staff record behind',
  (select count(*) = 0 from public.staff
    where employee_number in ('2026030', '2026031', '  2026022  ')
       or email in ('copycat@ta.example', 'copycat2@ta.example'))
);

select tams_test.check(
  '17 the Council Administrator role is refused by staff creation',
  tams_test.run_as('service_role', null, $sql$
    select public.create_staff_with_account(
      (select id from auth.users where email = 'invited@ta.example'),
      '2026040', 'Wants', 'Power', 'wantspower@ta.example', '0728217381',
      (select id from public.roles where role_name = 'Council Administrator'))
  $sql$) = 'TA002'
);

select tams_test.check(
  '18 nothing was created by the refused administrator attempt',
  (select count(*) = 0 from public.staff where employee_number = '2026040')
);

select tams_test.check(
  '19 an unknown role id is refused',
  tams_test.run_as('service_role', null, $sql$
    select public.create_staff_with_account(
      (select id from auth.users where email = 'invited@ta.example'),
      '2026041', 'Unknown', 'Role', 'unknownrole@ta.example', '0728217382',
      '00000000-0000-0000-0000-000000000000'::uuid)
  $sql$) = 'TA003'
);

select tams_test.check(
  '20 a staff record cannot be created for a non-existent auth user',
  tams_test.run_as('service_role', null, $sql$
    select public.create_staff_with_account(
      '00000000-0000-0000-0000-000000000000'::uuid,
      '2026042', 'No', 'Auth', 'noauth@ta.example', '0728217383',
      (select id from public.roles where role_name = 'Registry Clerk'))
  $sql$) = 'TA004'
);

select tams_test.check(
  '21 an invalid contact number is refused',
  tams_test.run_as('service_role', null, $sql$
    select public.create_staff_with_account(
      (select id from auth.users where email = 'invited@ta.example'),
      '2026043', 'Bad', 'Contact', 'badcontact@ta.example', 'not-a-number',
      (select id from public.roles where role_name = 'Registry Clerk'))
  $sql$) = '23514'
);

select tams_test.check(
  '22 an invalid email address is refused',
  tams_test.run_as('service_role', null, $sql$
    select public.create_staff_with_account(
      (select id from auth.users where email = 'invited@ta.example'),
      '2026044', 'Bad', 'Email', 'not-an-email', '0728217384',
      (select id from public.roles where role_name = 'Registry Clerk'))
  $sql$) = '23514'
);

select tams_test.check(
  '23 signed-in staff cannot call the staff creation function directly',
  tams_test.run_as('authenticated', tams_test.uid_of('clerk@ta.example'), $sql$
    select public.create_staff_with_account(
      (select id from auth.users where email = 'invited@ta.example'),
      '2026045', 'Self', 'Service', 'selfservice@ta.example', '0728217385',
      (select id from public.roles where role_name = 'Registry Clerk'))
  $sql$) = '42501'
);

select tams_test.check(
  '24 even the Council Administrator cannot call it directly from the browser',
  tams_test.run_as('authenticated', tams_test.uid_of('admin@ta.example'), $sql$
    select public.create_staff_with_account(
      (select id from auth.users where email = 'invited@ta.example'),
      '2026046', 'Direct', 'Call', 'directcall@ta.example', '0728217386',
      (select id from public.roles where role_name = 'Registry Clerk'))
  $sql$) = '42501'
);


-- =====================================================================
-- 3. Authorisation: who the database says you are
-- =====================================================================

select tams_test.check(
  '25 the administrator is recognised as the active Council Administrator',
  tams_test.query_as('authenticated', tams_test.uid_of('admin@ta.example'),
    'select public.is_active_council_administrator()::text') = 'true'
);

select tams_test.check(
  '26 a Registry Clerk is not recognised as the Council Administrator',
  tams_test.query_as('authenticated', tams_test.uid_of('clerk@ta.example'),
    'select public.is_active_council_administrator()::text') = 'false'
);

select tams_test.check(
  '27 a signed-out visitor is not recognised as the Council Administrator',
  tams_test.query_as('authenticated', null,
    'select public.is_active_council_administrator()::text') = 'false'
);

select tams_test.check(
  '28 the roles a Council Administrator may assign are exactly the three staff roles',
  tams_test.query_as('authenticated', tams_test.uid_of('admin@ta.example'),
    $sql$select string_agg(role_name, ', ' order by role_name) from public.assignable_staff_roles()$sql$)
  = 'Council Secretary, Land Officer, Registry Clerk'
);

select tams_test.check(
  '29 an ordinary staff member gets no assignable roles at all',
  tams_test.query_as('authenticated', tams_test.uid_of('clerk@ta.example'),
    'select count(*)::text from public.assignable_staff_roles()') = '0'
);

select tams_test.check(
  '30 the dashboard figures are refused to an ordinary staff member',
  tams_test.query_as('authenticated', tams_test.uid_of('clerk@ta.example'),
    'select public.admin_dashboard_stats()::text') = 'ERROR:42501'
);

select tams_test.check(
  '31 the dashboard figures are correct for the administrator',
  tams_test.query_as('authenticated', tams_test.uid_of('admin@ta.example'), $sql$
    select (public.admin_dashboard_stats() - 'active_by_role')::text
  $sql$) = (select jsonb_build_object(
              'staff_records', 4, 'active_staff', 4, 'deactivated', 0, 'awaiting_setup', 0)::text)
);

select tams_test.check(
  '32 a signed-in user with no staff account gets no context at all',
  tams_test.query_as('authenticated', tams_test.uid_of('stranger@ta.example'),
    'select coalesce(public.current_staff_context()::text, ''null'')') = 'null'
);

select tams_test.check(
  '33 a staff member sees their own name, role and status',
  tams_test.query_as('authenticated', tams_test.uid_of('clerk@ta.example'), $sql$
    select (public.current_staff_context() ->> 'full_name') || ' | ' ||
           (public.current_staff_context() ->> 'role_name') || ' | ' ||
           (public.current_staff_context() ->> 'account_status') || ' | ' ||
           (public.current_staff_context() ->> 'access_granted') || ' | ' ||
           (public.current_staff_context() ->> 'is_council_administrator')
  $sql$) = 'Jane Doe | Registry Clerk | active | true | false'
);


-- =====================================================================
-- 4. Row Level Security
-- =====================================================================

select tams_test.check(
  '34 a signed-out visitor can read nothing from staff',
  tams_test.query_as('anon', null, 'select count(*)::text from public.staff') = 'ERROR:42501'
);

select tams_test.check(
  '35 a signed-out visitor can read nothing from user_accounts',
  tams_test.query_as('anon', null, 'select count(*)::text from public.user_accounts') = 'ERROR:42501'
);

select tams_test.check(
  '36 a signed-out visitor can read nothing from roles',
  tams_test.query_as('anon', null, 'select count(*)::text from public.roles') = 'ERROR:42501'
);

select tams_test.check(
  '37 the administrator can see every staff record',
  tams_test.query_as('authenticated', tams_test.uid_of('admin@ta.example'),
    'select count(*)::text from public.staff') = '4'
);

select tams_test.check(
  '38 a Registry Clerk can see only their own staff record',
  tams_test.query_as('authenticated', tams_test.uid_of('clerk@ta.example'),
    $sql$select string_agg(employee_number, ',') from public.staff$sql$) = '2026022'
);

select tams_test.check(
  '39 a Registry Clerk can see only their own user account',
  tams_test.query_as('authenticated', tams_test.uid_of('clerk@ta.example'),
    $sql$select string_agg(email, ',') from public.user_accounts$sql$) = 'clerk@ta.example'
);

select tams_test.check(
  '40 a Registry Clerk cannot add a staff record',
  tams_test.run_as('authenticated', tams_test.uid_of('clerk@ta.example'), $sql$
    insert into public.staff (employee_number, first_name, last_name, email, contact_number, role_id)
    values ('2026050', 'Made', 'Up', 'madeup@ta.example', '0728217387',
            (select id from public.roles where role_name = 'Registry Clerk'))
  $sql$) = '42501'
);

select tams_test.check(
  '41 a Registry Clerk cannot give themselves the Council Administrator role',
  tams_test.run_as('authenticated', tams_test.uid_of('clerk@ta.example'), $sql$
    update public.staff set role_id = (select id from public.roles where role_name = 'Council Administrator')
     where employee_number = '2026022'
  $sql$) = '42501'
);

select tams_test.check(
  '42 a Registry Clerk cannot change their own account status',
  tams_test.run_as('authenticated', tams_test.uid_of('clerk@ta.example'), $sql$
    update public.user_accounts set account_status = 'active' where email = 'clerk@ta.example'
  $sql$) = '42501'
);

select tams_test.check(
  '43 a Registry Clerk cannot delete anything',
  tams_test.run_as('authenticated', tams_test.uid_of('clerk@ta.example'),
    $sql$delete from public.staff where employee_number = '2026023'$sql$) = '42501'
);

select tams_test.check(
  '44 nobody can invent a new role from the browser',
  tams_test.run_as('authenticated', tams_test.uid_of('admin@ta.example'),
    $sql$insert into public.roles (role_name) values ('Super Administrator')$sql$) = '42501'
);


-- =====================================================================
-- 5. account_status is the single source of truth for access
-- =====================================================================

update public.user_accounts set account_status = 'deactivated' where email = 'officer@ta.example';

select tams_test.check(
  '45 a deactivated staff member is refused access',
  tams_test.query_as('authenticated', tams_test.uid_of('officer@ta.example'),
    $sql$select public.current_staff_context() ->> 'access_granted'$sql$) = 'false'
);

select tams_test.check(
  '46 a deactivated staff member is told why',
  tams_test.query_as('authenticated', tams_test.uid_of('officer@ta.example'),
    $sql$select public.current_staff_context() ->> 'account_status'$sql$) = 'deactivated'
);

select tams_test.check(
  '47 a deactivated staff member is no longer active staff',
  tams_test.query_as('authenticated', tams_test.uid_of('officer@ta.example'),
    'select public.is_active_staff()::text') = 'false'
);

select tams_test.check(
  '48 a deactivated staff member can no longer read the staff table',
  tams_test.query_as('authenticated', tams_test.uid_of('officer@ta.example'),
    'select count(*)::text from public.staff') = '0'
);

select tams_test.check(
  '49 a deactivated staff member can no longer read the roles table',
  tams_test.query_as('authenticated', tams_test.uid_of('officer@ta.example'),
    'select count(*)::text from public.roles') = '0'
);

select tams_test.check(
  '50 signing in does not stamp a login for a deactivated account',
  tams_test.query_as('authenticated', tams_test.uid_of('officer@ta.example'),
    $sql$select coalesce(public.record_login()::text, 'no-login')$sql$) = 'no-login'
);

select tams_test.check(
  '51 the dashboard now counts one deactivated account',
  tams_test.query_as('authenticated', tams_test.uid_of('admin@ta.example'),
    $sql$select public.admin_dashboard_stats() ->> 'deactivated'$sql$) = '1'
);

update public.user_accounts set account_status = 'active' where email = 'officer@ta.example';

select tams_test.check(
  '52 reactivating the account restores access immediately',
  tams_test.query_as('authenticated', tams_test.uid_of('officer@ta.example'),
    $sql$select public.current_staff_context() ->> 'access_granted'$sql$) = 'true'
);

select tams_test.check(
  '53 an active staff member stamps their own last_login',
  tams_test.query_as('authenticated', tams_test.uid_of('clerk@ta.example'),
    $sql$select public.record_login() is not null$sql$) = 'true'
);

-- A separate statement: the update above is only visible to a new snapshot.
select tams_test.check(
  '53b stamping a login touches nobody else''s account',
  (select count(*) = 1 from public.user_accounts where last_login is not null)
  and (select last_login is not null from public.user_accounts where email = 'clerk@ta.example')
);


-- =====================================================================
-- 6. Invitations that have not been completed
-- =====================================================================

select tams_test.check(
  '54 someone invited but not yet signed in is counted as awaiting setup',
  tams_test.run_as('service_role', null, $sql$
    select public.create_staff_with_account(
      (select id from auth.users where email = 'invited@ta.example'),
      '2026025', 'Sipho', 'Dlamini', 'invited@ta.example', '0728217388',
      (select id from public.roles where role_name = 'Registry Clerk'))
  $sql$) = 'OK'
  and tams_test.query_as('authenticated', tams_test.uid_of('admin@ta.example'),
        $sql$select public.admin_dashboard_stats() ->> 'awaiting_setup'$sql$) = '1'
);

select tams_test.check(
  '55 the active staff counts by role are correct',
  tams_test.query_as('authenticated', tams_test.uid_of('admin@ta.example'), $sql$
    select (public.admin_dashboard_stats() -> 'active_by_role')::text
  $sql$) = '[{"count": 1, "role_name": "Council Administrator"}, '
        || '{"count": 1, "role_name": "Council Secretary"}, '
        || '{"count": 1, "role_name": "Land Officer"}, '
        || '{"count": 2, "role_name": "Registry Clerk"}]'
);


-- =====================================================================
-- 7. The Council Administrator's staff list
-- =====================================================================

select tams_test.check(
  '56 the staff list is refused to an ordinary staff member',
  tams_test.query_as('authenticated', tams_test.uid_of('clerk@ta.example'),
    'select count(*)::text from public.admin_staff_accounts()') = 'ERROR:42501'
);

select tams_test.check(
  '57 the staff list is refused to a signed-out visitor',
  tams_test.query_as('authenticated', null,
    'select count(*)::text from public.admin_staff_accounts()') = 'ERROR:42501'
);

select tams_test.check(
  '58 the administrator sees every staff account with its single role',
  tams_test.query_as('authenticated', tams_test.uid_of('admin@ta.example'), $sql$
    select string_agg(employee_number || '=' || role_name || '/' || account_status, ' ' order by employee_number)
    from public.admin_staff_accounts()
  $sql$) = '2026011=Council Administrator/active '
        || '2026022=Registry Clerk/active '
        || '2026023=Land Officer/active '
        || '2026024=Council Secretary/active '
        || '2026025=Registry Clerk/active'
);

select tams_test.check(
  '59 the staff list shows who has not completed their invitation yet',
  tams_test.query_as('authenticated', tams_test.uid_of('admin@ta.example'), $sql$
    select string_agg(employee_number, ',' order by employee_number)
    from public.admin_staff_accounts() where not invitation_completed
  $sql$) = '2026025'
);

-- =====================================================================
-- 8. No half-made people
-- =====================================================================

do $$
declare
  v_outcome text;
begin
  begin
    -- A staff record on its own, with no user account behind it.
    insert into public.staff (employee_number, first_name, last_name, email, contact_number, role_id)
    values ('2026060', 'Orphan', 'Record', 'orphan@ta.example', '0728217390',
            (select id from public.roles where role_name = 'Registry Clerk'));
    execute 'set constraints all immediate';
    v_outcome := 'OK';
  exception when others then
    v_outcome := sqlstate;
  end;
  perform tams_test.check(
    '60 a staff record cannot be committed without its user account', v_outcome = 'TA005', v_outcome);
end;
$$;

select tams_test.check(
  '61 the refused staff record left nothing behind',
  (select count(*) = 0 from public.staff where employee_number = '2026060')
);

-- ---- Report ---------------------------------------------------------

\echo ''
\echo '================ TAMS foundation database tests ================'
select name, case when passed then 'PASS' else 'FAIL' end as result
from tams_test.results order by id;

select count(*) filter (where passed) as passed,
       count(*) filter (where not passed) as failed,
       count(*) as total
from tams_test.results;

-- Fail the run if anything failed.
do $$
declare
  v_failed int;
begin
  select count(*) into v_failed from tams_test.results where not passed;
  if v_failed > 0 then
    raise exception '% test(s) failed', v_failed;
  end if;
  raise notice 'All % tests passed.', (select count(*) from tams_test.results);
end;
$$;
