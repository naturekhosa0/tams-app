-- =====================================================================
-- TAMS — land applications, allocation, permission to occupy,
-- renewal, revocation, succession and burial plots.
-- =====================================================================

create function tams_test.officer() returns uuid language sql stable as $$
  select tams_test.uid_of('landofficer2@ta.example');
$$;

-- A verified resident account for someone already on the register —
-- what the Registry Clerk's approval produces.
create function tams_test.give_resident_account(p_id_number text)
returns uuid language plpgsql volatile security definer as $$
declare v_uid uuid; v_resident uuid;
begin
  select id into v_resident from public.residents where id_number = p_id_number;
  insert into auth.users (email, last_sign_in_at)
  values (lower(p_id_number) || '@village.example', now()) returning id into v_uid;
  insert into public.user_accounts (auth_user_id, email, account_type, account_status, resident_id)
  values (v_uid, lower(p_id_number) || '@village.example', 'resident', 'active', v_resident);
  return v_uid;
end; $$;

create function tams_test.resident_uid(p_id_number text) returns uuid
language sql stable security definer as $$
  select auth_user_id from public.user_accounts where email = lower(p_id_number) || '@village.example';
$$;

create function tams_test.application_id(p_reference text) returns uuid
language sql stable security definer as $$
  select id from public.land_applications where application_reference = p_reference;
$$;

create function tams_test.latest_application(p_id_number text) returns uuid
language sql stable security definer as $$
  select a.id from public.land_applications a
  join public.residents r on r.id = a.applicant_resident_id
  where r.id_number = p_id_number order by a.submitted_at desc limit 1;
$$;

create function tams_test.allocation_id(p_reference text) returns uuid
language sql stable security definer as $$
  select id from public.land_allocations where allocation_reference = p_reference;
$$;

create function tams_test.pto_id(p_number text) returns uuid
language sql stable security definer as $$
  select id from public.ptos where pto_number = p_number;
$$;

-- Resolved as the definer, so a test can hand a function a real id even
-- when the caller being tested would not be allowed to look it up.
create function tams_test.pto_for_site(p_site_code text, p_status text default 'active')
returns uuid language sql stable security definer as $$
  select p.id from public.ptos p
  join public.land_allocations a on a.id = p.land_allocation_id
  join public.land_sites s on s.id = a.land_site_id
  where s.site_code = p_site_code and (p_status is null or p.pto_status = p_status)
  order by p.issue_date desc limit 1;
$$;

create function tams_test.allocation_for_site(p_site_code text, p_status text default 'active')
returns uuid language sql stable security definer as $$
  select a.id from public.land_allocations a
  join public.land_sites s on s.id = a.land_site_id
  where s.site_code = p_site_code and (p_status is null or a.allocation_status = p_status)
  order by a.allocation_date desc limit 1;
$$;

create function tams_test.site_status_of(p_code text) returns text
language sql stable security definer as $$
  select site_status from public.land_sites where site_code = p_code;
$$;

-- ---- people to act as ------------------------------------------------
-- Heads of households that the earlier suites leave alone.
select tams_test.give_resident_account('SYN0000000028');   -- head of HH-0009
select tams_test.give_resident_account('SYN0000000030');   -- a member of HH-0009, not its head
select tams_test.give_resident_account('SYN0000000043');   -- head of HH-0013
select tams_test.give_resident_account('SYN0000000054');   -- head of HH-0016

-- Two people whose ages are known exactly, because age is the rule.
select tams_test.run_as('authenticated', tams_test.clerk(), $sql$
  select public.registry_create_resident('SYN0000000800', 'Exactly', 'TwentyOne',
    (current_date - make_interval(years => 21))::date::text, 'Male', 'active')
$sql$);
select tams_test.run_as('authenticated', tams_test.clerk(), $sql$
  select public.registry_create_resident('SYN0000000801', 'Nearly', 'TwentyOne',
    ((current_date - make_interval(years => 21))::date + 1)::text, 'Female', 'active')
$sql$);
select tams_test.run_as('authenticated', tams_test.clerk(), $sql$
  select public.registry_link_resident_to_household(
    tams_test.resident_id_of('SYN0000000800'), tams_test.household_id_of('HH-0016'), true)
$sql$);
select tams_test.run_as('authenticated', tams_test.clerk(), $sql$
  select public.registry_link_resident_to_household(
    tams_test.resident_id_of('SYN0000000801'), tams_test.household_id_of('HH-0016'), true)
$sql$);
select tams_test.give_resident_account('SYN0000000800');
select tams_test.give_resident_account('SYN0000000801');

-- A Land Officer whose account has since been deactivated.
insert into auth.users (email, last_sign_in_at) values ('exofficer@ta.example', now());
select public.create_staff_with_account(
  tams_test.uid_of('exofficer@ta.example'), '2026080', 'Former', 'Officer',
  'exofficer@ta.example', '0728210080', tams_test.role_id_of('Land Officer'));
update public.user_accounts set account_status = 'deactivated' where email = 'exofficer@ta.example';


-- =====================================================================
-- LAND TYPES
-- =====================================================================

select tams_test.check(
  'LAND 1/2 — grazing is not a kind of land TAMS allocates',
  (select not ('grazing' = any (public.allocatable_land_types())))
  and tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_register_site('GRZ-001', 'grazing', 'Common land')
  $sql$) = 'TA064'
);

select tams_test.check(
  'LAND 2a — and the database itself refuses a grazing site',
  tams_test.run_as('service_role', null, $sql$
    insert into public.land_sites (site_code, site_type, street_address, site_status)
    values ('GRZ-002', 'grazing', 'Common land', 'available')
  $sql$) = '23514'
);

select tams_test.check(
  'LAND 3 — the four kinds of land are accepted',
  tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_register_site('RES-0101', 'residential', '101 New Street', 'ST-2101', 'Central', 'Mhinga Village')
  $sql$) = 'OK'
  and tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_register_site('FRM-0101', 'farming', 'Farm portion 101', null, 'East', 'Mhinga Village')
  $sql$) = 'OK'
  and tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_register_site('BUS-0101', 'business', '1 Market Street', 'ST-3101', 'Central', 'Mhinga Village')
  $sql$) = 'OK'
  and tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_register_site('BUR-0101', 'burial', 'Burial ground portion 1', null, 'North', 'Mhinga Village')
  $sql$) = 'OK'
);

select tams_test.check(
  'LAND 3a — a new burial plot starts usable, and a new site starts available',
  (select burial_status = 'usable' and site_status = 'available'
     from public.land_sites where site_code = 'BUR-0101')
  and tams_test.site_status_of('RES-0101') = 'available'
);


-- =====================================================================
-- LAND OFFICER AUTHORIZATION
-- =====================================================================

select tams_test.check(
  'AUTH 32 — an active Land Officer is recognised',
  tams_test.query_as('authenticated', tams_test.officer(),
    'select public.is_active_land_officer()::text') = 'true'
);

select tams_test.check(
  'AUTH 33/34 — a Registry Clerk and a Council Secretary are refused',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.land_officer_register_site('RES-9001', 'residential', 'Nowhere')
  $sql$) = '42501'
  and tams_test.query_as('authenticated', tams_test.clerk(),
    'select count(*)::text from public.land_officer_applications()') = 'ERROR:42501'
  and tams_test.run_as('authenticated', tams_test.uid_of('councilsec@ta.example'), $sql$
    select public.land_officer_register_site('RES-9002', 'residential', 'Nowhere')
  $sql$) = '42501'
);

select tams_test.check(
  'AUTH 35 — the Council Administrator is not a Land Officer either',
  tams_test.run_as('authenticated', tams_test.uid_of('admin@ta.example'), $sql$
    select public.land_officer_register_site('RES-9003', 'residential', 'Nowhere')
  $sql$) = '42501'
  and tams_test.query_as('authenticated', tams_test.uid_of('admin@ta.example'),
    'select count(*)::text from public.land_officer_ptos()') = 'ERROR:42501'
);

select tams_test.check(
  'AUTH 36 — a Land Officer whose account was deactivated is refused',
  tams_test.run_as('authenticated', tams_test.uid_of('exofficer@ta.example'), $sql$
    select public.land_officer_register_site('RES-9004', 'residential', 'Nowhere')
  $sql$) = '42501'
);

select tams_test.check(
  'AUTH 37 — a signed-out request is refused',
  tams_test.run_as('authenticated', null, $sql$
    select public.land_officer_register_site('RES-9005', 'residential', 'Nowhere')
  $sql$) = '42501'
  and tams_test.query_as('anon', null, 'select count(*)::text from public.land_applications') = 'ERROR:42501'
);


-- =====================================================================
-- AGE
-- =====================================================================

select tams_test.check(
  'AGE 5 — somebody exactly 21 today is old enough',
  public.is_at_least_age((current_date - make_interval(years => 21))::date, 21)
);

select tams_test.check(
  'AGE 4 — somebody one day short of 21 is not',
  not public.is_at_least_age(((current_date - make_interval(years => 21))::date + 1), 21)
);

select tams_test.check(
  'AGE 4a — a 20 year old is refused when they apply',
  tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000801'), $sql$
    select public.resident_submit_land_application('residential',
      jsonb_build_object('reason_for_application', 'I want my own home',
                         'intended_use', 'Permanent residential home'))
  $sql$) = 'TA060'
);

select tams_test.check(
  'AGE 6 — age comes from the register, not from anything in the form',
  tams_test.query_as('authenticated', tams_test.resident_uid('SYN0000000801'), $sql$
    select (public.resident_land_eligibility('residential') -> 'problems')::text
  $sql$) like '%at least 21 years old%'
);

select tams_test.check(
  'AGE 5a — somebody exactly 21 today may apply',
  tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000800'), $sql$
    select public.resident_submit_land_application('residential',
      jsonb_build_object('reason_for_application', 'Starting my own household',
                         'intended_use', 'Permanent residential home',
                         'lives_with_household', true))
  $sql$) = 'OK'
);


-- =====================================================================
-- RESIDENTIAL
-- =====================================================================

select tams_test.check(
  'RES 9 — the applicant never chooses a site',
  not exists (
    select 1 from information_schema.parameters
    where specific_name in (select specific_name from information_schema.routines
                             where routine_schema = 'public'
                               and routine_name = 'resident_submit_land_application')
      and parameter_name in ('p_site_id', 'p_site_code'))
  and not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'land_applications'
      and column_name in ('site_code', 'land_site_id', 'requested_site_id'))
);

select tams_test.check(
  'APPS 25 — a second open residential application is refused',
  tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000800'), $sql$
    select public.resident_submit_land_application('residential',
      jsonb_build_object('reason_for_application', 'Asking twice'))
  $sql$) = 'TA062'
);

select tams_test.check(
  'RES 7 — the Land Officer approves it, rechecking eligibility',
  tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_approve_application(tams_test.latest_application('SYN0000000800'))
  $sql$) = 'OK'
);

select tams_test.check(
  'SITE 41 — a site of the wrong kind cannot be given to it',
  tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_allocate_site(
      tams_test.latest_application('SYN0000000800'), tams_test.site_id_of('BUS-0101'))
  $sql$) = 'TA070'
);

select tams_test.check(
  'ALLOC 47 — allocating gives the site, marks it and closes the application together',
  tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_allocate_site(
      tams_test.latest_application('SYN0000000800'), tams_test.site_id_of('RES-0101'))
  $sql$) = 'OK'
);

select tams_test.check(
  'ALLOC 47a — the site is allocated and the application says so',
  tams_test.site_status_of('RES-0101') = 'allocated'
  and (select application_status = 'allocated' from public.land_applications
        where id = tams_test.latest_application('SYN0000000800'))
  and (select count(*) = 1 from public.land_allocations a
        where a.land_site_id = tams_test.site_id_of('RES-0101') and a.allocation_status = 'active')
);

select tams_test.check(
  'SITE 42 — a second allocation of the same site is impossible',
  tams_test.run_as('service_role', null, $sql$
    insert into public.land_allocations (allocation_reference, land_site_id, resident_id,
      land_type, allocation_date, allocation_status)
    values ('ALLOC-RACE', tams_test.site_id_of('RES-0101'),
            tams_test.resident_id_of('SYN0000000028'), 'residential', current_date, 'active')
  $sql$) = '23505'
);

select tams_test.check(
  'SITE 39 — an allocated site cannot simply be marked available',
  tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_update_site(tams_test.site_id_of('RES-0101'), 'residential',
      '101 New Street', 'ST-2101', 'Central', 'Mhinga Village', 'available')
  $sql$) = 'TA068'
);

select tams_test.check(
  'SITE 40 — an allocated site cannot change its kind',
  tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_update_site(tams_test.site_id_of('RES-0101'), 'business',
      '101 New Street', 'ST-2101', 'Central', 'Mhinga Village', 'allocated')
  $sql$) = 'TA067'
);

select tams_test.check(
  'SITE 38 — a duplicate site code is refused',
  tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_register_site('RES-0101', 'residential', 'Somewhere else')
  $sql$) = 'TA065'
);

select tams_test.check(
  'RES 8/43 — a second residential stand for the same person is refused',
  tams_test.query_as('authenticated', tams_test.resident_uid('SYN0000000800'), $sql$
    select (public.resident_land_eligibility('residential') ->> 'eligible')
  $sql$) = 'false'
  and tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000800'), $sql$
    select public.resident_submit_land_application('residential',
      jsonb_build_object('reason_for_application', 'A second stand'))
  $sql$) = 'TA060'
);

select tams_test.check(
  'PTO 50 — the residential permission is perpetual, with no expiry at all',
  tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_issue_pto(
      tams_test.allocation_for_site('RES-0101', 'active'))
  $sql$) = 'OK'
);

select tams_test.check(
  'PTO 50a — expiry_date is null, not a pretend far-future date',
  (select p.expiry_date is null and p.pto_status = 'active' and p.land_type = 'residential'
   from public.ptos p
   join public.land_allocations a on a.id = p.land_allocation_id
   where a.land_site_id = tams_test.site_id_of('RES-0101'))
);

select tams_test.check(
  'PTO 55 — a resident cannot issue their own permission',
  tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000800'), $sql$
    select public.land_officer_issue_pto(
      tams_test.allocation_for_site('RES-0101', null))
  $sql$) = '42501'
);


-- =====================================================================
-- FARMING — the household's land, asked for by whoever heads it
-- =====================================================================

select tams_test.check(
  'FARM 11 — somebody who is not the head of the household is refused',
  tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000030'), $sql$
    select public.resident_submit_land_application('farming',
      jsonb_build_object('reason_for_application', 'I want to farm',
                         'farming_type', 'crop', 'farming_activity', 'Maize'))
  $sql$) = 'TA060'
);

select tams_test.check(
  'FARM 12 — the head of the household, over 21, may apply',
  tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000028'), $sql$
    select public.resident_submit_land_application('farming',
      jsonb_build_object('reason_for_application', 'To feed the household',
                         'farming_type', 'mixed', 'farming_activity', 'Maize and cattle'))
  $sql$) = 'OK'
);

select tams_test.check(
  'APPS 27 — a second open farming application for the household is refused',
  tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000028'), $sql$
    select public.resident_submit_land_application('farming',
      jsonb_build_object('reason_for_application', 'Asking twice', 'farming_type', 'crop'))
  $sql$) = 'TA062'
);

select tams_test.check(
  'FARM 12a — it is approved and given a farming site',
  tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_approve_application(tams_test.latest_application('SYN0000000028'))
  $sql$) = 'OK'
  and tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_allocate_site(
      tams_test.latest_application('SYN0000000028'), tams_test.site_id_of('FRM-0101'))
  $sql$) = 'OK'
);

select tams_test.check(
  'FARM 12b — the land is held by the household, not the person',
  (select a.household_id = tams_test.household_id_of('HH-0009') and a.resident_id is null
   from public.land_allocations a where a.land_site_id = tams_test.site_id_of('FRM-0101'))
);

select tams_test.check(
  'FARM 14 — the farming permission runs for exactly five years',
  tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_issue_pto(
      tams_test.allocation_for_site('FRM-0101', null))
  $sql$) = 'OK'
);

select tams_test.check(
  'FARM 14a — five years to the day, held by the household',
  (select p.expiry_date = (p.issue_date + make_interval(years => 5))::date
          and p.holder_household_id = tams_test.household_id_of('HH-0009')
          and p.holder_resident_id is null
   from public.ptos p
   join public.land_allocations a on a.id = p.land_allocation_id
   where a.land_site_id = tams_test.site_id_of('FRM-0101'))
);

select tams_test.check(
  'FARM 13/45 — a second farming allocation for the household is refused',
  tams_test.query_as('authenticated', tams_test.resident_uid('SYN0000000028'), $sql$
    select (public.resident_land_eligibility('farming') ->> 'eligible')
  $sql$) = 'false'
);


-- =====================================================================
-- BUSINESS
-- =====================================================================

select tams_test.check(
  'BUS 15 — an eligible resident may apply for a business site',
  tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000043'), $sql$
    select public.resident_submit_land_application('business',
      jsonb_build_object('reason_for_application', 'To open a shop',
                         'business_name', 'Mhinga General Dealer', 'business_type', 'shop',
                         'business_description', 'Groceries and household goods'))
  $sql$) = 'OK'
);

select tams_test.check(
  'BUS 15a — the kind of business is required',
  tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000054'), $sql$
    select public.resident_submit_land_application('business',
      jsonb_build_object('reason_for_application', 'A business'))
  $sql$) = 'TA061'
);

select tams_test.check(
  'BUS 17 — the business permission runs for exactly two years',
  tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_approve_application(tams_test.latest_application('SYN0000000043'))
  $sql$) = 'OK'
  and tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_allocate_site(
      tams_test.latest_application('SYN0000000043'), tams_test.site_id_of('BUS-0101'))
  $sql$) = 'OK'
  and tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_issue_pto(
      tams_test.allocation_for_site('BUS-0101', null))
  $sql$) = 'OK'
);

select tams_test.check(
  'BUS 17a — two years to the day',
  (select p.expiry_date = (p.issue_date + make_interval(years => 2))::date
   from public.ptos p
   join public.land_allocations a on a.id = p.land_allocation_id
   where a.land_site_id = tams_test.site_id_of('BUS-0101'))
);

select tams_test.check(
  'BUS 16/44 — a second business site for the same person is refused',
  tams_test.query_as('authenticated', tams_test.resident_uid('SYN0000000043'), $sql$
    select (public.resident_land_eligibility('business') ->> 'eligible')
  $sql$) = 'false'
);

-- A permission that has run out, on an allocation nobody has released.
select tams_test.run_as('service_role', null, $sql$
  update public.ptos set issue_date = current_date - 800, expiry_date = current_date - 70
  where land_allocation_id = (select id from public.land_allocations
                               where land_site_id = tams_test.site_id_of('BUS-0101'))
$sql$);

select tams_test.check(
  'PTO 54 — a permission past its expiry reads as expired, whatever the stored status says',
  (select p.pto_status = 'active'
          and public.pto_effective_status(p.pto_status, p.expiry_date) = 'expired'
   from public.ptos p
   join public.land_allocations a on a.id = p.land_allocation_id
   where a.land_site_id = tams_test.site_id_of('BUS-0101'))
);

select tams_test.check(
  'BUS 18 — an expired permission does not free the site: no second business site',
  tams_test.query_as('authenticated', tams_test.resident_uid('SYN0000000043'), $sql$
    select (public.resident_land_eligibility('business') ->> 'eligible')
  $sql$) = 'false'
  and tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000043'), $sql$
    select public.resident_submit_land_application('business',
      jsonb_build_object('reason_for_application', 'Another shop', 'business_type', 'shop'))
  $sql$) = 'TA060'
);


-- =====================================================================
-- RENEWAL
-- =====================================================================

select tams_test.check(
  'REN 56 — the business holder may ask for a renewal',
  tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000043'), $sql$
    select public.resident_request_pto_renewal(
      tams_test.pto_for_site('BUS-0101', null), 'The shop is doing well')
  $sql$) = 'OK'
);

select tams_test.check(
  'REN 61 — a second open renewal request for the same permission is refused',
  tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000043'), $sql$
    select public.resident_request_pto_renewal(
      tams_test.pto_for_site('BUS-0101', null), 'Asking twice')
  $sql$) = 'TA077'
);

select tams_test.check(
  'REN 58/59 — residential and burial permissions are perpetual and are not renewed',
  tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000800'), $sql$
    select public.resident_request_pto_renewal(
      tams_test.pto_for_site('RES-0101', null))
  $sql$) = 'TA075'
);

select tams_test.check(
  'REN 96 — a resident cannot renew somebody else''s permission',
  tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000054'), $sql$
    select public.resident_request_pto_renewal(
      tams_test.pto_for_site('BUS-0101', null))
  $sql$) = '42501'
);

select tams_test.check(
  'REN 97 — an ordinary household member cannot renew the household''s farming permission',
  tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000030'), $sql$
    select public.resident_request_pto_renewal(
      tams_test.pto_for_site('FRM-0101', null))
  $sql$) = '42501'
);

select tams_test.check(
  'REN 57 — the head of the household may renew the household''s farming permission',
  tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000028'), $sql$
    select public.resident_request_pto_renewal(
      tams_test.pto_for_site('FRM-0101', null), 'Still farming')
  $sql$) = 'OK'
);

select tams_test.check(
  'REN 65 — declining a renewal needs a reason',
  tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_decline_renewal(
      (select q.id from public.pto_renewal_requests q
        join public.ptos p on p.id = q.pto_id where p.land_type = 'farming'
        and q.request_status = 'pending' limit 1), '  ')
  $sql$) = 'TA061'
);

select tams_test.check(
  'REN 62/63 — approving a renewal writes a NEW permission and keeps the old one',
  tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_approve_renewal(
      (select q.id from public.pto_renewal_requests q
        join public.ptos p on p.id = q.pto_id
        where p.land_type = 'business' and q.request_status = 'pending' limit 1))
  $sql$) = 'OK'
);

select tams_test.check(
  'REN 62a — the old permission is kept, marked renewed; the new one is current',
  (select count(*) = 2 from public.ptos p
    join public.land_allocations a on a.id = p.land_allocation_id
    where a.land_site_id = tams_test.site_id_of('BUS-0101'))
  and (select count(*) = 1 from public.ptos p
        join public.land_allocations a on a.id = p.land_allocation_id
        where a.land_site_id = tams_test.site_id_of('BUS-0101') and p.pto_status = 'renewed')
  and (select count(*) = 1 from public.ptos p
        join public.land_allocations a on a.id = p.land_allocation_id
        where a.land_site_id = tams_test.site_id_of('BUS-0101') and p.pto_status = 'active')
);

select tams_test.check(
  'REN 64 — the new permission records which one it came from, and runs two years',
  (select p.renewed_from_pto_id is not null
          and p.expiry_date = (p.issue_date + make_interval(years => 2))::date
   from public.ptos p
   join public.land_allocations a on a.id = p.land_allocation_id
   where a.land_site_id = tams_test.site_id_of('BUS-0101') and p.pto_status = 'active')
);

select tams_test.check(
  'REN 64a — an already renewed permission cannot be renewed again',
  tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000043'), $sql$
    select public.resident_request_pto_renewal(
      tams_test.pto_for_site('BUS-0101', 'renewed'))
  $sql$) = 'TA076'
);


-- =====================================================================
-- REVOCATION AND RELEASE
-- =====================================================================

select tams_test.check(
  'REV 66 — revoking needs a reason',
  tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_revoke_pto(
      tams_test.pto_for_site('FRM-0101', 'active'), '')
  $sql$) = 'TA061'
);

select tams_test.check(
  'REV 69 — a resident cannot revoke their own permission',
  tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000028'), $sql$
    select public.land_officer_revoke_pto(
      tams_test.pto_for_site('FRM-0101', 'active'), 'Mine now')
  $sql$) = '42501'
);

select tams_test.check(
  'REV 67 — the permission is revoked',
  tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_revoke_pto(
      tams_test.pto_for_site('FRM-0101', 'active'),
      'Land was not being farmed')
  $sql$) = 'OK'
);

-- A separate statement: the update above is only visible to a new snapshot.
select tams_test.check(
  'REV 68 — the revoked permission is kept with its reason, and the allocation stands',
  (select p.pto_status = 'revoked' and p.revocation_reason = 'Land was not being farmed'
          and p.revoked_by_staff_id is not null and p.revoked_at is not null
   from public.ptos p join public.land_allocations a on a.id = p.land_allocation_id
   where a.land_site_id = tams_test.site_id_of('FRM-0101'))
  and (select count(*) = 1 from public.land_allocations
        where land_site_id = tams_test.site_id_of('FRM-0101') and allocation_status = 'active')
);

select tams_test.check(
  'REN 60 — a revoked permission cannot be renewed',
  tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000028'), $sql$
    select public.resident_request_pto_renewal(
      tams_test.pto_for_site('FRM-0101', 'revoked'))
  $sql$) = 'TA076'
);

select tams_test.check(
  'SITE 39a — releasing an allocation needs a reason, then frees the site',
  tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_release_allocation(
      tams_test.allocation_for_site('FRM-0101', 'active'), '')
  $sql$) = 'TA061'
  and tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_release_allocation(
      tams_test.allocation_for_site('FRM-0101', 'active'), 'Returned after revocation')
  $sql$) = 'OK'
);

select tams_test.check(
  'ALLOC 48 — the released allocation is kept as history and the site is free again',
  tams_test.site_status_of('FRM-0101') = 'available'
  and (select count(*) = 1 from public.land_allocations
        where land_site_id = tams_test.site_id_of('FRM-0101') and allocation_status = 'released')
  and (select end_reason = 'Returned after revocation' and ended_by_staff_id is not null
       from public.land_allocations where land_site_id = tams_test.site_id_of('FRM-0101'))
);

select tams_test.check(
  'FARM 45a — with the site released, the household may farm again',
  tams_test.query_as('authenticated', tams_test.resident_uid('SYN0000000028'), $sql$
    select (public.resident_land_eligibility('farming') ->> 'eligible')
  $sql$) = 'true'
);


-- =====================================================================
-- BURIAL PLOTS
-- =====================================================================

select tams_test.check(
  'BUR 20 — somebody who is not the head of the household is refused',
  tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000030'), $sql$
    select public.resident_submit_land_application('burial',
      jsonb_build_object('reason_for_application', 'For the family'))
  $sql$) = 'TA060'
);

select tams_test.check(
  'BUR 19 — the head of a household with no plot may apply',
  tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000054'), $sql$
    select public.resident_submit_land_application('burial',
      jsonb_build_object('reason_for_application', 'The household has nowhere to bury its dead'))
  $sql$) = 'OK'
);

select tams_test.check(
  'APPS 28 — a second open burial application for the household is refused',
  tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000054'), $sql$
    select public.resident_submit_land_application('burial',
      jsonb_build_object('reason_for_application', 'Asking twice'))
  $sql$) = 'TA062'
);

select tams_test.check(
  'BUR 24 — the burial permission is perpetual and held by the household',
  tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_approve_application(tams_test.latest_application('SYN0000000054'))
  $sql$) = 'OK'
  and tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_allocate_site(
      tams_test.latest_application('SYN0000000054'), tams_test.site_id_of('BUR-0101'))
  $sql$) = 'OK'
  and tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_issue_pto(tams_test.allocation_for_site('BUR-0101', 'active'))
  $sql$) = 'OK'
);

select tams_test.check(
  'BUR 24a — no expiry, and the household holds it',
  (select p.expiry_date is null and p.holder_household_id = tams_test.household_id_of('HH-0016')
          and p.holder_resident_id is null
   from public.ptos p where p.land_allocation_id = tams_test.allocation_for_site('BUR-0101', 'active'))
);

select tams_test.check(
  'BUR 21 — no second plot while the household has one with space in it',
  tams_test.query_as('authenticated', tams_test.resident_uid('SYN0000000054'), $sql$
    select (public.resident_land_eligibility('burial') ->> 'eligible')
  $sql$) = 'false'
  and tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000054'), $sql$
    select public.resident_submit_land_application('burial',
      jsonb_build_object('reason_for_application', 'Another plot'))
  $sql$) = 'TA060'
);

select tams_test.check(
  'BUR 71 — only a burial plot can be marked full',
  tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_set_burial_status(tams_test.site_id_of('RES-0101'), 'full')
  $sql$) = 'TA078'
);

select tams_test.check(
  'BUR 70 — the Land Officer marks the plot full',
  tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_set_burial_status(tams_test.site_id_of('BUR-0101'), 'full')
  $sql$) = 'OK'
);

select tams_test.check(
  'BUR 22 — with every plot full, the household may apply for another',
  tams_test.query_as('authenticated', tams_test.resident_uid('SYN0000000054'), $sql$
    select (public.resident_land_eligibility('burial') ->> 'eligible')
  $sql$) = 'true'
);

select tams_test.check(
  'BUR 73 — and it is given a second plot, while the full one stays theirs',
  tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_register_site('BUR-0102', 'burial', 'Burial ground portion 2', null, 'North', 'Mhinga Village')
  $sql$) = 'OK'
  and tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000054'), $sql$
    select public.resident_submit_land_application('burial',
      jsonb_build_object('reason_for_application', 'The first plot is full'))
  $sql$) = 'OK'
);

select tams_test.check(
  'BUR 73a — approved, allocated, and the household now holds two plots',
  tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_approve_application(tams_test.latest_application('SYN0000000054'))
  $sql$) = 'OK'
  and tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_allocate_site(
      tams_test.latest_application('SYN0000000054'), tams_test.site_id_of('BUR-0102'))
  $sql$) = 'OK'
);

select tams_test.check(
  'BUR 23/72 — the full plot is still the household''s and is not free for anyone else',
  (select count(*) = 2 from public.land_allocations a
    where a.household_id = tams_test.household_id_of('HH-0016')
      and a.land_type = 'burial' and a.allocation_status = 'active')
  and tams_test.site_status_of('BUR-0101') = 'allocated'
  and tams_test.query_as('authenticated', tams_test.officer(),
        $sql$select count(*)::text from public.land_officer_available_sites('burial')
             where site_code = 'BUR-0101'$sql$) = '0'
);

select tams_test.check(
  'BUR 72a — a full plot cannot be allocated to another household',
  tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_allocate_site(
      tams_test.latest_application('SYN0000000054'), tams_test.site_id_of('BUR-0101'))
  $sql$) in ('TA069', 'TA071')
);


-- =====================================================================
-- RESIDENTIAL SUCCESSION
-- =====================================================================

select tams_test.check(
  'SUC 74 — when the holder dies the site is flagged for succession',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_update_resident(
      tams_test.resident_id_of('SYN0000000800'), 'SYN0000000800', 'Exactly', 'TwentyOne',
      r.date_of_birth::text, r.gender, 'deceased')
    from public.residents r where r.id_number = 'SYN0000000800'
  $sql$) = 'OK'
);

select tams_test.check(
  'SUC 74a — the allocation is waiting for succession, not deleted or freed',
  (select allocation_status = 'succession_pending'
   from public.land_allocations where land_site_id = tams_test.site_id_of('RES-0101'))
  and tams_test.site_status_of('RES-0101') = 'allocated'
);

select tams_test.check(
  'SUC 75 — the site is not offered to anybody else while that is unresolved',
  tams_test.query_as('authenticated', tams_test.officer(),
    $sql$select count(*)::text from public.land_officer_available_sites('residential')
         where site_code = 'RES-0101'$sql$) = '0'
);

select tams_test.check(
  'SUC 80 — TAMS names no heir: it lists the household and says who is eligible',
  tams_test.query_as('authenticated', tams_test.officer(), $sql$
    select count(*)::text from public.land_officer_succession_candidates(
      tams_test.allocation_for_site('RES-0101', 'succession_pending'))
  $sql$)::int >= 1
  and not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and column_name in ('heir_rank', 'inheritance_order', 'automatic_successor_id'))
);

select tams_test.check(
  'SUC 76 — a successor under 21 is refused',
  tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_record_succession(
      tams_test.allocation_for_site('RES-0101', 'succession_pending'),
      tams_test.resident_id_of('SYN0000000801'), 'Chosen by the family')
  $sql$) = 'TA060'
);

select tams_test.check(
  'SUC 78 — a successor from another household is refused',
  tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_record_succession(
      tams_test.allocation_for_site('RES-0101', 'succession_pending'),
      tams_test.resident_id_of('SYN0000000028'), 'Chosen by the family')
  $sql$) = 'TA080'
);

select tams_test.check(
  'SUC 79 — a successor who already holds a residential stand is refused',
  tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_record_succession(
      tams_test.allocation_for_site('RES-0101', 'succession_pending'),
      tams_test.resident_id_of('SYN0000000054'), 'Chosen by the family')
  $sql$) in ('TA080', 'TA060')
);

select tams_test.check(
  'SUC 86 — with nobody eligible the site simply stays waiting',
  (select allocation_status = 'succession_pending'
   from public.land_allocations where land_site_id = tams_test.site_id_of('RES-0101'))
  and tams_test.site_status_of('RES-0101') = 'allocated'
);

-- Someone of the same household, of age, without land of their own.
select tams_test.run_as('authenticated', tams_test.clerk(), $sql$
  select public.registry_create_resident('SYN0000000802', 'Rightful', 'Successor',
    (current_date - make_interval(years => 30))::date::text, 'Female', 'active')
$sql$);
select tams_test.run_as('authenticated', tams_test.clerk(), $sql$
  select public.registry_link_resident_to_household(
    tams_test.resident_id_of('SYN0000000802'), tams_test.household_id_of('HH-0016'), true)
$sql$);
select tams_test.give_resident_account('SYN0000000802');

select tams_test.check(
  'SUC 77/82 — the officer records the successor the family chose',
  tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_record_succession(
      tams_test.allocation_for_site('RES-0101', 'succession_pending'),
      tams_test.resident_id_of('SYN0000000802'), 'Recorded after the family meeting')
  $sql$) = 'OK'
);

select tams_test.check(
  'SUC 81 — the old allocation and the old permission are both kept',
  (select count(*) = 1 from public.land_allocations
    where land_site_id = tams_test.site_id_of('RES-0101') and allocation_status = 'superseded')
  and (select count(*) = 1 from public.ptos p
        join public.land_allocations a on a.id = p.land_allocation_id
        where a.land_site_id = tams_test.site_id_of('RES-0101') and p.pto_status = 'superseded')
);

select tams_test.check(
  'SUC 82a/83/84 — a new permission, the same site, the same household',
  (select a.resident_id = tams_test.resident_id_of('SYN0000000802')
          and a.household_id = tams_test.household_id_of('HH-0016')
          and a.succeeds_allocation_id is not null
   from public.land_allocations a
   where a.land_site_id = tams_test.site_id_of('RES-0101') and a.allocation_status = 'active')
  and (select p.expiry_date is null and p.pto_status = 'active'
       from public.ptos p join public.land_allocations a on a.id = p.land_allocation_id
       where a.land_site_id = tams_test.site_id_of('RES-0101') and a.allocation_status = 'active')
);

select tams_test.check(
  'SUC 85 — the head of the household was not quietly changed',
  (select head_resident_id = tams_test.resident_id_of('SYN0000000054')
   from public.households where household_code = 'HH-0016')
);

select tams_test.check(
  'SUC 87/88 — returning a site to the Authority needs a reason and a site actually waiting',
  tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_return_to_authority(
      tams_test.allocation_for_site('RES-0101', 'active'), 'No successor')
  $sql$) = 'TA079'
);

-- A second residential site, so the whole no-successor path can be seen.
select tams_test.run_as('authenticated', tams_test.officer(), $sql$
  select public.land_officer_register_site('RES-0102', 'residential', '102 New Street', 'ST-2102', 'Central', 'Mhinga Village')
$sql$);
select tams_test.run_as('authenticated', tams_test.clerk(), $sql$
  select public.registry_create_resident('SYN0000000803', 'Last', 'OfTheLine',
    (current_date - make_interval(years => 40))::date::text, 'Male', 'active')
$sql$);
select tams_test.run_as('authenticated', tams_test.clerk(), $sql$
  select public.registry_link_resident_to_household(
    tams_test.resident_id_of('SYN0000000803'), tams_test.household_id_of('HH-0013'), true)
$sql$);
select tams_test.give_resident_account('SYN0000000803');
select tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000803'), $sql$
  select public.resident_submit_land_application('residential',
    jsonb_build_object('reason_for_application', 'My own home', 'lives_with_household', true))
$sql$);
select tams_test.run_as('authenticated', tams_test.officer(), $sql$
  select public.land_officer_approve_application(tams_test.latest_application('SYN0000000803'))
$sql$);
select tams_test.run_as('authenticated', tams_test.officer(), $sql$
  select public.land_officer_allocate_site(
    tams_test.latest_application('SYN0000000803'), tams_test.site_id_of('RES-0102'))
$sql$);
select tams_test.run_as('authenticated', tams_test.officer(), $sql$
  select public.land_officer_issue_pto(tams_test.allocation_for_site('RES-0102', 'active'))
$sql$);
select tams_test.run_as('authenticated', tams_test.clerk(), $sql$
  select public.registry_update_resident(
    tams_test.resident_id_of('SYN0000000803'), 'SYN0000000803', 'Last', 'OfTheLine',
    r.date_of_birth::text, r.gender, 'deceased')
  from public.residents r where r.id_number = 'SYN0000000803'
$sql$);

select tams_test.check(
  'SUC 88a — returning it needs a reason',
  tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_return_to_authority(
      tams_test.allocation_for_site('RES-0102', 'succession_pending'), '   ')
  $sql$) = 'TA061'
);

select tams_test.check(
  'SUC 87a — with a reason, the site goes back and only then becomes available',
  tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_return_to_authority(
      tams_test.allocation_for_site('RES-0102', 'succession_pending'),
      'No eligible successor in the household')
  $sql$) = 'OK'
);

select tams_test.check(
  'SUC 87b — the history is kept and the site is free again',
  tams_test.site_status_of('RES-0102') = 'available'
  and (select allocation_status = 'released' and end_reason = 'No eligible successor in the household'
       from public.land_allocations where land_site_id = tams_test.site_id_of('RES-0102'))
  and (select count(*) = 1 from public.ptos p
        join public.land_allocations a on a.id = p.land_allocation_id
        where a.land_site_id = tams_test.site_id_of('RES-0102'))
);


-- =====================================================================
-- QR VERIFICATION
-- =====================================================================

select tams_test.check(
  'QR 89 — a valid token verifies the permission',
  (select (public.verify_pto(p.verification_token) ->> 'found') = 'true'
          and (public.verify_pto(p.verification_token) ->> 'pto_number') = p.pto_number
          and (public.verify_pto(p.verification_token) ->> 'status') = 'active'
   from public.ptos p
   join public.land_allocations a on a.id = p.land_allocation_id
   where a.land_site_id = tams_test.site_id_of('RES-0101') and p.pto_status = 'active')
);

select tams_test.check(
  'QR 90 — an unknown token verifies nothing',
  (public.verify_pto('not-a-real-token') ->> 'found') = 'false'
  and (public.verify_pto('') ->> 'found') = 'false'
  and (public.verify_pto(null) ->> 'found') = 'false'
);

select tams_test.check(
  'QR 91 — the public answer carries no identity number, birth date or contact details',
  (select not (public.verify_pto(p.verification_token)::text ilike '%id_number%')
          and not (public.verify_pto(p.verification_token)::text ilike '%date_of_birth%')
          and not (public.verify_pto(p.verification_token)::text ilike '%cellphone%')
          and not (public.verify_pto(p.verification_token)::text ilike '%email%')
          and not (public.verify_pto(p.verification_token)::text ilike '%resident_id%')
   from public.ptos p where p.pto_status = 'active' limit 1)
);

select tams_test.check(
  'QR 92 — a revoked permission verifies as revoked',
  (select (public.verify_pto(p.verification_token) ->> 'status') = 'revoked'
   from public.ptos p where p.pto_status = 'revoked' limit 1)
);

-- Put one permission past its expiry so the lapsed case can be seen.
select tams_test.run_as('service_role', null, $sql$
  update public.ptos set issue_date = current_date - 900, expiry_date = current_date - 30
  where id = tams_test.pto_for_site('BUS-0101', 'active')
$sql$);

select tams_test.check(
  'QR 93 — a lapsed permission verifies as expired',
  (select (public.verify_pto(p.verification_token) ->> 'status') = 'expired'
   from public.ptos p
   where p.pto_status = 'active' and p.expiry_date is not null and p.expiry_date < current_date
   limit 1)
);

create function tams_test.any_pto_token(p_status text default 'active')
returns text language sql stable security definer as $$
  select verification_token from public.ptos where pto_status = p_status limit 1;
$$;

select tams_test.check(
  'QR 89a — verification works for somebody who is not signed in at all',
  tams_test.query_as('anon', null,
    format($sql$select public.verify_pto(%L) ->> 'found'$sql$, tams_test.any_pto_token())) = 'true'
);

select tams_test.check(
  'PTO 49 — every permission number is unique',
  (select count(*) = count(distinct pto_number) from public.ptos)
  and (select count(*) = count(distinct verification_token) from public.ptos)
);


-- =====================================================================
-- WHAT A RESIDENT MAY SEE
-- =====================================================================

select tams_test.check(
  'ACC 94 — a resident sees their own land and permissions',
  tams_test.query_as('authenticated', tams_test.resident_uid('SYN0000000802'), $sql$
    select jsonb_array_length(public.resident_land_portal() -> 'ptos')::text
  $sql$) = '1'
);

select tams_test.check(
  'ACC 95 — and nobody else''s',
  tams_test.query_as('authenticated', tams_test.resident_uid('SYN0000000030'), $sql$
    select jsonb_array_length(public.resident_land_portal() -> 'ptos')::text
  $sql$) = '0'
  and tams_test.query_as('authenticated', tams_test.resident_uid('SYN0000000030'),
    'select count(*)::text from public.ptos') = '0'
);

select tams_test.check(
  'ACC 96 — the head of a household sees the household''s farming and burial records',
  tams_test.query_as('authenticated', tams_test.resident_uid('SYN0000000054'), $sql$
    select count(*)::text from public.ptos where holder_household_id = tams_test.household_id_of('HH-0016')
  $sql$)::int >= 1
);

select tams_test.check(
  'ACC 94a — a resident cannot approve, allocate or issue anything',
  tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000802'), $sql$
    select public.land_officer_approve_application(tams_test.latest_application('SYN0000000043'))
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000802'), $sql$
    select public.land_officer_set_burial_status(tams_test.site_id_of('BUR-0102'), 'full')
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000802'), $sql$
    update public.land_applications set application_status = 'approved'
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000802'), $sql$
    update public.ptos set expiry_date = null
  $sql$) = '42501'
);

select tams_test.check(
  'APPS 29/30/31 — declining needs a reason, keeps the application, and the applicant is told why',
  tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000054'), $sql$
    select public.resident_submit_land_application('farming',
      jsonb_build_object('reason_for_application', 'To farm', 'farming_type', 'crop'))
  $sql$) = 'OK'
  and tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_decline_application(tams_test.latest_application('SYN0000000054'), '   ')
  $sql$) = 'TA061'
  and tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_decline_application(
      tams_test.latest_application('SYN0000000054'), 'No farming land is available this season')
  $sql$) = 'OK'
);

select tams_test.check(
  'APPS 30a — the declined application is kept, and says why',
  (select application_status = 'declined'
          and decline_reason = 'No farming land is available this season'
          and reviewed_by_staff_id is not null
   from public.land_applications where id = tams_test.latest_application('SYN0000000054'))
);

select tams_test.check(
  'APPS 31a — the applicant can read that reason themselves',
  tams_test.query_as('authenticated', tams_test.resident_uid('SYN0000000054'), $sql$
    select decline_reason from public.land_applications
    where application_status = 'declined' order by reviewed_at desc limit 1
  $sql$) = 'No farming land is available this season'
);


-- =====================================================================
-- THE OFFICER'S LISTS
-- =====================================================================

select tams_test.check(
  'LIST 98 — the Land Officer can list allocations, filtered by status',
  tams_test.query_as('authenticated', tams_test.officer(), $sql$
    select count(*) > 0 from public.land_officer_allocations('active', null, null)
  $sql$) = 'true'
  and tams_test.query_as('authenticated', tams_test.officer(), $sql$
    select bool_and(allocation_status = 'active')
    from public.land_officer_allocations('active', null, null)
  $sql$) = 'true'
);

select tams_test.check(
  'LIST 99 — the list carries the current permission and its effective status',
  tams_test.query_as('authenticated', tams_test.officer(), $sql$
    select bool_and(pto_effective_status is null
                    or pto_effective_status in ('active', 'expired', 'renewed', 'revoked', 'superseded'))
    from public.land_officer_allocations(null, null, null)
  $sql$) = 'true'
  -- Exactly one row per allocation, however many permissions it has had.
  and tams_test.query_as('authenticated', tams_test.officer(), $sql$
    select count(*) = (select count(*) from public.land_allocations)
    from public.land_officer_allocations(null, null, null)
  $sql$) = 'true'
);

select tams_test.check(
  'LIST 100 — nobody but a Land Officer may read that list',
  tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000802'), $sql$
    select count(*) from public.land_officer_allocations('active', null, null)
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select count(*) from public.land_officer_allocations('active', null, null)
  $sql$) = '42501'
);

-- =====================================================================
-- REGRESSION
-- =====================================================================

select tams_test.check(
  'REG 101 — every imported allocation is still there, still current, still the same',
  (select count(*) = 20 from tams_test.imported_allocations)
  and (select count(*) = 20
       from public.land_allocations a join tams_test.imported_allocations i on i.id = a.id
       where a.allocation_reference = i.allocation_reference
         and a.land_site_id = i.land_site_id
         and a.resident_id = i.resident_id
         and a.allocation_date = i.allocation_date
         and a.allocation_status = 'active'
         and a.land_type = 'residential')
);

select tams_test.check(
  'REG 101a — and the imported sites kept their codes, kinds and addresses',
  (select count(*) = 20
   from public.land_sites s join tams_test.imported_sites i on i.id = s.id
   where s.site_code = i.site_code and s.site_type = i.site_type
     and s.street_address = i.street_address)
);
