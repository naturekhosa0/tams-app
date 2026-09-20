-- =====================================================================
-- TAMS — Registry Clerk tests
--
-- Runs against the imported village register: 70 residents, 20
-- households, 20 sites, 200 relationships.
-- =====================================================================

-- ---- Staff to act as ------------------------------------------------
insert into auth.users (email, last_sign_in_at) values
  ('registryclerk@ta.example', now()),
  ('landofficer2@ta.example',  now()),
  ('councilsec@ta.example',    now()),
  ('exclerk@ta.example',       now());

select public.create_staff_with_account(
  tams_test.uid_of('registryclerk@ta.example'), '2026070', 'Rita', 'Clerk',
  'registryclerk@ta.example', '0728210070', tams_test.role_id_of('Registry Clerk'));
select public.create_staff_with_account(
  tams_test.uid_of('landofficer2@ta.example'), '2026071', 'Lance', 'Officer',
  'landofficer2@ta.example', '0728210071', tams_test.role_id_of('Land Officer'));
select public.create_staff_with_account(
  tams_test.uid_of('councilsec@ta.example'), '2026072', 'Cynthia', 'Secretary',
  'councilsec@ta.example', '0728210072', tams_test.role_id_of('Council Secretary'));
select public.create_staff_with_account(
  tams_test.uid_of('exclerk@ta.example'), '2026073', 'Eric', 'Former',
  'exclerk@ta.example', '0728210073', tams_test.role_id_of('Registry Clerk'));

-- One Registry Clerk whose account has since been deactivated.
update public.user_accounts set account_status = 'deactivated'
where email = 'exclerk@ta.example';

create function tams_test.clerk() returns uuid language sql stable as $$
  select tams_test.uid_of('registryclerk@ta.example');
$$;

create function tams_test.resident_id_of(p_id_number text) returns uuid
language sql stable security definer as $$
  select id from public.residents where id_number = p_id_number;
$$;

create function tams_test.household_id_of(p_code text) returns uuid
language sql stable security definer as $$
  select id from public.households where household_code = p_code;
$$;

create function tams_test.site_id_of(p_code text) returns uuid
language sql stable security definer as $$
  select id from public.land_sites where site_code = p_code;
$$;

create function tams_test.resident_household(p_id_number text) returns text
language sql stable security definer as $$
  select h.household_code from public.residents r
  left join public.households h on h.id = r.household_id
  where r.id_number = p_id_number;
$$;


-- =====================================================================
-- SEARCH AND VIEW
-- =====================================================================

select tams_test.check(
  'SEARCH 4 — the imported residents are all there',
  tams_test.query_as('authenticated', tams_test.clerk(),
    'select count(*)::text from public.registry_search_residents(null)') = '70'
);

select tams_test.check(
  'SEARCH 1 — a resident is found by identity number',
  tams_test.query_as('authenticated', tams_test.clerk(),
    $sql$select full_name from public.registry_search_residents('SYN0000000001')$sql$) = 'Samuel Rachidi'
);

select tams_test.check(
  'SEARCH 2 — residents are found by surname, whatever the casing',
  tams_test.query_as('authenticated', tams_test.clerk(),
    $sql$select count(*)::text from public.registry_search_residents('rachidi')$sql$)
  = tams_test.query_as('authenticated', tams_test.clerk(),
    $sql$select count(*)::text from public.residents where last_name = 'Rachidi'$sql$)
);

select tams_test.check(
  'SEARCH 3 — residents are found by household code',
  tams_test.query_as('authenticated', tams_test.clerk(),
    $sql$select count(*)::text from public.registry_search_residents('HH-0001')$sql$) = '6'
);

select tams_test.check(
  'SEARCH 3a — residents are found by site code and by street address',
  tams_test.query_as('authenticated', tams_test.clerk(),
    $sql$select count(*)::text from public.registry_search_residents('RES-0001')$sql$) = '6'
  and tams_test.query_as('authenticated', tams_test.clerk(),
    $sql$select count(*)::text from public.registry_search_residents('marula')$sql$) = '6'
);

select tams_test.check(
  'SEARCH 3b — a search term is matched literally, never as a wildcard',
  tams_test.query_as('authenticated', tams_test.clerk(),
    $sql$select count(*)::text from public.registry_search_residents('%')$sql$) = '0'
);

select tams_test.check(
  'SEARCH 5 — a household lists exactly its own members',
  tams_test.query_as('authenticated', tams_test.clerk(), $sql$
    select jsonb_array_length(public.registry_household_record(
      (select id from public.households where household_code = 'HH-0001')) -> 'members')::text
  $sql$) = '6'
);

select tams_test.check(
  'SEARCH 6 — a household shows its site code and address',
  tams_test.query_as('authenticated', tams_test.clerk(), $sql$
    select (public.registry_household_record(
      (select id from public.households where household_code = 'HH-0001')) ->> 'site_code') || ' / ' ||
           (public.registry_household_record(
      (select id from public.households where household_code = 'HH-0001')) ->> 'street_address')
  $sql$) = 'RES-0001 / 13 Marula Street'
);

select tams_test.check(
  'SEARCH 6a — a household names its head',
  tams_test.query_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_household_record(
      (select id from public.households where household_code = 'HH-0001')) ->> 'head_full_name'
  $sql$) = 'Samuel Rachidi'
);

select tams_test.check(
  'SEARCH 7 — family relationships come back for a resident',
  tams_test.query_as('authenticated', tams_test.clerk(), $sql$
    select string_agg(relationship_type || ': ' || related_full_name, ' | ' order by relationship_type, related_full_name)
    from public.registry_family_lineage(
      (select id from public.residents where id_number = 'SYN0000000001'))
  $sql$) like '%spouse: Maria Rachidi%'
);

select tams_test.check(
  'SEARCH 7a — the household view shows who holds the land allocation',
  tams_test.query_as('authenticated', tams_test.clerk(), $sql$
    select (public.registry_household_record(
      (select id from public.households where household_code = 'HH-0012')) -> 'allocation' ->> 'holder_full_name')
  $sql$) = 'Nyambeni Mulaudzi'
);

select tams_test.check(
  'SEARCH 7b — and says plainly that the holder is not the head',
  tams_test.query_as('authenticated', tams_test.clerk(), $sql$
    select (public.registry_household_record(
      (select id from public.households where household_code = 'HH-0012')) -> 'allocation' ->> 'holder_is_household_head')
  $sql$) = 'false'
);

select tams_test.check(
  'SEARCH 8 — households are searchable by code, address and member name',
  tams_test.query_as('authenticated', tams_test.clerk(),
    $sql$select count(*)::text from public.registry_search_households('HH-0001')$sql$) = '1'
  and tams_test.query_as('authenticated', tams_test.clerk(),
    $sql$select household_code from public.registry_search_households('Rachidi')$sql$) = 'HH-0001'
);

select tams_test.check(
  'SEARCH 9 — the dashboard counts the register as imported',
  tams_test.query_as('authenticated', tams_test.clerk(), $sql$
    select (public.registry_dashboard_stats() ->> 'residents') || '/' ||
           (public.registry_dashboard_stats() ->> 'households') || '/' ||
           (public.registry_dashboard_stats() ->> 'residents_without_household')
  $sql$) = '70/20/0'
);


-- =====================================================================
-- CREATE RESIDENT
-- =====================================================================

select tams_test.check(
  'CREATE RESIDENT 8 — a valid resident is added to the register',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_create_resident(
      'SYN0000000901', 'Naledi', 'Mokoena', '1994-07-15', 'Female', 'active', '0730000901', 'naledi@example.com')
  $sql$) = 'OK'
);

select tams_test.check(
  'CREATE RESIDENT 8a — they are on the register, with no household yet',
  (select count(*) = 1 from public.residents
    where id_number = 'SYN0000000901' and household_id is null and resident_status = 'active')
);

select tams_test.check(
  'CREATE RESIDENT 9 — a duplicate identity number is refused',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_create_resident(
      'SYN0000000901', 'Copy', 'Cat', '1990-01-01', 'Female', 'active')
  $sql$) = 'TA033'
);

select tams_test.check(
  'CREATE RESIDENT 10 — missing required details are refused',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_create_resident('', '', '', '', '', 'active')
  $sql$) = 'TA034'
);

select tams_test.check(
  'CREATE RESIDENT 10a — an impossible date of birth is refused',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_create_resident(
      'SYN0000000902', 'Bad', 'Date', '1994-02-31', 'Female', 'active')
  $sql$) = 'TA034'
);

select tams_test.check(
  'CREATE RESIDENT 10b — an unrecognised resident status is refused',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_create_resident(
      'SYN0000000903', 'Bad', 'Status', '1994-01-01', 'Female', 'retired')
  $sql$) = 'TA034'
);

select tams_test.check(
  'CREATE RESIDENT 10c — an unknown household is refused',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_create_resident(
      'SYN0000000904', 'No', 'Household', '1994-01-01', 'Female', 'active', null, null,
      '00000000-0000-0000-0000-000000000000'::uuid)
  $sql$) = 'TA032'
);

select tams_test.check(
  'CREATE RESIDENT 11 — creating a resident creates no sign-in account of any kind',
  (select count(*) = 0 from public.user_accounts ua
    where ua.email = 'naledi@example.com' or ua.resident_id is not null)
  and (select count(*) = 0 from auth.users u where u.email = 'naledi@example.com')
);


-- =====================================================================
-- UPDATE RESIDENT
-- =====================================================================

create table tams_test.resident_uuid_before as
  select id as resident_uuid from public.residents where id_number = 'SYN0000000901';

select tams_test.check(
  'UPDATE 12 — a contact number and email address can be corrected',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_update_resident(
      (select id from public.residents where id_number = 'SYN0000000901'),
      'SYN0000000901', 'Naledi', 'Mokoena', '1994-07-15', 'Female', 'active',
      '0730000999', 'Naledi.New@Example.com')
  $sql$) = 'OK'
);

select tams_test.check(
  'UPDATE 12a — the new details are stored, with the email in lower case',
  (select contact_number = '0730000999' and email = 'naledi.new@example.com'
   from public.residents where id_number = 'SYN0000000901')
);

select tams_test.check(
  'UPDATE 15 — the resident keeps the same record; a new one was not made',
  (select count(*) = 1 from public.residents r, tams_test.resident_uuid_before b
    where r.id_number = 'SYN0000000901' and r.id = b.resident_uuid)
  and (select count(*) = 71 from public.residents)
);

select tams_test.check(
  'UPDATE 14 — an identity number already on the register is refused',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_update_resident(
      (select id from public.residents where id_number = 'SYN0000000901'),
      'SYN0000000001', 'Naledi', 'Mokoena', '1994-07-15', 'Female', 'active')
  $sql$) = 'TA033'
);

select tams_test.check(
  'UPDATE 13 — a resident can be recorded as deceased',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_update_resident(
      (select id from public.residents where id_number = 'SYN0000000058'),
      'SYN0000000058', r.first_name, r.last_name, r.date_of_birth::text, r.gender, 'deceased',
      r.contact_number, r.email)
    from public.residents r where r.id_number = 'SYN0000000058'
  $sql$) = 'OK'
);

select tams_test.check(
  'UPDATE 13a — being deceased changes nothing else: household, relationships and land history remain',
  (select resident_status = 'deceased' and household_id is not null
   from public.residents where id_number = 'SYN0000000058')
  and (select count(*) > 0 from public.family_relationships f
        where f.resident_id = tams_test.resident_id_of('SYN0000000058'))
);

select tams_test.check(
  'UPDATE 16 — household membership is not changed through the update function',
  (select count(*) = 0 from information_schema.parameters
    where specific_name in (select specific_name from information_schema.routines
                             where routine_schema = 'public' and routine_name = 'registry_update_resident')
      and parameter_name = 'p_household_id')
);


-- =====================================================================
-- HOUSEHOLDS
-- =====================================================================

select tams_test.check(
  'HOUSEHOLD 16a — the next household code follows the imported ones',
  tams_test.query_as('authenticated', tams_test.clerk(),
    'select public.registry_next_household_code()') = 'HH-0021'
);

select tams_test.check(
  'HOUSEHOLD 19 — a Registry Clerk cannot create a land site',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    insert into public.land_sites (site_code, site_type, street_address, site_status)
    values ('RES-9001', 'residential', '1 New Street', 'allocated')
  $sql$) = '42501'
);

-- A site for the new household: created the only way sites can be, by
-- trusted server-side code. This stands in for the Land Officer
-- function that will own it.
select tams_test.run_as('service_role', null, $sql$
  insert into public.land_sites (site_code, site_type, stand_number, street_address,
                                 village_section, village_name, site_status)
  values ('RES-0021', 'residential', 'ST-1021', '73 Baobab Close', 'Central',
          'Mahlasedi Village (Synthetic)', 'allocated'),
         ('GRAZE-001', 'grazing', null, 'Common grazing land', 'North',
          'Mahlasedi Village (Synthetic)', 'allocated')
$sql$);

select tams_test.check(
  'HOUSEHOLD 16 — a household is created on a free residential site',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_create_household('HH-0021', tams_test.site_id_of('RES-0021'), 'active')
  $sql$) = 'OK'
);

select tams_test.check(
  'HOUSEHOLD 16b — it starts with no head and no members',
  (select head_resident_id is null from public.households where household_code = 'HH-0021')
  and (select count(*) = 0 from public.residents where household_id = tams_test.household_id_of('HH-0021'))
);

select tams_test.check(
  'HOUSEHOLD 17 — a household code already in use is refused',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_create_household('HH-0021', tams_test.site_id_of('RES-0021'), 'active')
  $sql$) = 'TA035'
);

select tams_test.check(
  'HOUSEHOLD 18 — a site already lived on by a current household is refused',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_create_household('HH-0099', tams_test.site_id_of('RES-0001'), 'active')
  $sql$) = 'TA037'
);

select tams_test.check(
  'HOUSEHOLD 18a — a site that is not residential is refused',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_create_household('HH-0098', tams_test.site_id_of('GRAZE-001'), 'active')
  $sql$) = 'TA036'
);

select tams_test.check(
  'HOUSEHOLD 18b — an unknown site is refused',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_create_household('HH-0097', '00000000-0000-0000-0000-000000000000'::uuid, 'active')
  $sql$) = 'TA036'
);

select tams_test.check(
  'HOUSEHOLD 18c — an occupied site is not offered as available',
  tams_test.query_as('authenticated', tams_test.clerk(),
    $sql$select count(*)::text from public.registry_available_residential_sites()
         where site_code in ('RES-0001', 'RES-0021', 'GRAZE-001')$sql$) = '0'
);


-- =====================================================================
-- MEMBERSHIP
-- =====================================================================

select tams_test.check(
  'MEMBERSHIP 20 — a resident with no household is linked to one',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_link_resident_to_household(
      tams_test.resident_id_of('SYN0000000901'), tams_test.household_id_of('HH-0021'))
  $sql$) = 'OK'
);

select tams_test.check(
  'MEMBERSHIP 22 — they appear in that household and nowhere else',
  tams_test.resident_household('SYN0000000901') = 'HH-0021'
  and (select count(*) = 1 from public.residents where household_id = tams_test.household_id_of('HH-0021'))
);

select tams_test.check(
  'MEMBERSHIP 21 — moving someone who already has a household needs confirmation',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_link_resident_to_household(
      tams_test.resident_id_of('SYN0000000901'), tams_test.household_id_of('HH-0002'))
  $sql$) = 'TA038'
);

select tams_test.check(
  'MEMBERSHIP 21a — and the unconfirmed attempt moved nobody',
  tams_test.resident_household('SYN0000000901') = 'HH-0021'
);

select tams_test.check(
  'MEMBERSHIP 21b — with confirmation the move is made',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_link_resident_to_household(
      tams_test.resident_id_of('SYN0000000901'), tams_test.household_id_of('HH-0002'), true)
  $sql$) = 'OK'
);

select tams_test.check(
  'MEMBERSHIP 21c — they are in the new household and no longer in the old one',
  tams_test.resident_household('SYN0000000901') = 'HH-0002'
  and (select count(*) = 0 from public.residents where household_id = tams_test.household_id_of('HH-0021'))
);

select tams_test.check(
  'MEMBERSHIP 20a — linking someone to the household they are already in is refused',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_link_resident_to_household(
      tams_test.resident_id_of('SYN0000000901'), tams_test.household_id_of('HH-0002'), true)
  $sql$) = 'TA038'
);

select tams_test.check(
  'MEMBERSHIP 20b — a head of household cannot be moved out from under their household',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_link_resident_to_household(
      tams_test.resident_id_of('SYN0000000001'), tams_test.household_id_of('HH-0021'), true)
  $sql$) = 'TA045'
);

select tams_test.check(
  'MEMBERSHIP 20c — an unknown resident and an unknown household are both refused',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_link_resident_to_household(
      '00000000-0000-0000-0000-000000000000'::uuid, tams_test.household_id_of('HH-0021'))
  $sql$) = 'TA031'
  and tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_link_resident_to_household(
      tams_test.resident_id_of('SYN0000000901'), '00000000-0000-0000-0000-000000000000'::uuid)
  $sql$) = 'TA032'
);


-- =====================================================================
-- HEAD OF HOUSEHOLD
-- =====================================================================

select tams_test.check(
  'HEAD 24 — someone from another household cannot be made head',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_designate_household_head(
      tams_test.household_id_of('HH-0021'), tams_test.resident_id_of('SYN0000000001'))
  $sql$) = 'TA039'
);

-- Put a member into the new household so it can have a head.
select tams_test.run_as('authenticated', tams_test.clerk(), $sql$
  select public.registry_link_resident_to_household(
    tams_test.resident_id_of('SYN0000000901'), tams_test.household_id_of('HH-0021'), true)
$sql$);

select tams_test.check(
  'HEAD 23 — a member of the household is designated its head',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_designate_household_head(
      tams_test.household_id_of('HH-0021'), tams_test.resident_id_of('SYN0000000901'))
  $sql$) = 'OK'
);

select tams_test.check(
  'HEAD 23a — the household now records that head, and only that head',
  (select h.head_resident_id = tams_test.resident_id_of('SYN0000000901')
   from public.households h where h.household_code = 'HH-0021')
  and (select count(*) = 21 from public.households)
);

select tams_test.check(
  'HEAD 25 — a resident recorded as deceased cannot be made head',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_designate_household_head(
      (select household_id from public.residents where id_number = 'SYN0000000058'),
      tams_test.resident_id_of('SYN0000000058'), true)
  $sql$) = 'TA040'
);

select tams_test.check(
  'HEAD 26 — replacing an existing head needs confirmation',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_designate_household_head(
      tams_test.household_id_of('HH-0001'), tams_test.resident_id_of('SYN0000000002'))
  $sql$) = 'TA041'
);

select tams_test.check(
  'HEAD 26a — the unconfirmed attempt left the head alone',
  (select h.head_resident_id = tams_test.resident_id_of('SYN0000000001')
   from public.households h where h.household_code = 'HH-0001')
);

select tams_test.check(
  'HEAD 26b — with confirmation the head is replaced, not added to',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_designate_household_head(
      tams_test.household_id_of('HH-0001'), tams_test.resident_id_of('SYN0000000002'), true)
  $sql$) = 'OK'
);

select tams_test.check(
  'HEAD 26c — HH-0001 has one head, and it is the new one',
  (select h.head_resident_id = tams_test.resident_id_of('SYN0000000002')
   from public.households h where h.household_code = 'HH-0001')
  and (select count(*) = 6 from public.residents where household_id = tams_test.household_id_of('HH-0001'))
);

select tams_test.check(
  'HEAD 26d — designating the head who already holds the post is refused',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_designate_household_head(
      tams_test.household_id_of('HH-0001'), tams_test.resident_id_of('SYN0000000002'), true)
  $sql$) = 'TA041'
);


-- =====================================================================
-- FAMILY RELATIONSHIPS
-- =====================================================================

select tams_test.check(
  'FAMILY 27 — a parent relationship is recorded',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_record_family_relationship(
      tams_test.resident_id_of('SYN0000000901'), tams_test.resident_id_of('SYN0000000009'), 'parent')
  $sql$) = 'OK'
);

select tams_test.check(
  'FAMILY 28 — the child relationship was created the other way round',
  (select count(*) = 1 from public.family_relationships f
    where f.resident_id = tams_test.resident_id_of('SYN0000000009')
      and f.related_resident_id = tams_test.resident_id_of('SYN0000000901')
      and f.relationship_type = 'child'
      and f.relationship_status = 'active')
);

select tams_test.check(
  'FAMILY 33 — relatives do not have to share a household',
  (select r1.household_id is distinct from r2.household_id
   from public.residents r1, public.residents r2
   where r1.id_number = 'SYN0000000901' and r2.id_number = 'SYN0000000009')
);

select tams_test.check(
  'FAMILY 29 — a spouse relationship creates a spouse relationship back',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_record_family_relationship(
      tams_test.resident_id_of('SYN0000000901'), tams_test.resident_id_of('SYN0000000014'), 'spouse')
  $sql$) = 'OK'
);

select tams_test.check(
  'FAMILY 29a — and it is there',
  (select count(*) = 1 from public.family_relationships f
    where f.resident_id = tams_test.resident_id_of('SYN0000000014')
      and f.related_resident_id = tams_test.resident_id_of('SYN0000000901')
      and f.relationship_type = 'spouse')
);

select tams_test.check(
  'FAMILY 30 — a sibling relationship is recorded',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_record_family_relationship(
      tams_test.resident_id_of('SYN0000000901'), tams_test.resident_id_of('SYN0000000015'), 'sibling')
  $sql$) = 'OK'
);

-- A separate statement: the insert above is only visible to a new snapshot.
select tams_test.check(
  'FAMILY 30a — and a sibling relationship was created back the other way',
  (select count(*) = 1 from public.family_relationships f
    where f.resident_id = tams_test.resident_id_of('SYN0000000015')
      and f.related_resident_id = tams_test.resident_id_of('SYN0000000901')
      and f.relationship_type = 'sibling')
);

select tams_test.check(
  'FAMILY 30b — a guardian relationship is recorded',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_record_family_relationship(
      tams_test.resident_id_of('SYN0000000901'), tams_test.resident_id_of('SYN0000000016'), 'guardian')
  $sql$) = 'OK'
);

-- A separate statement: the insert above is only visible to a new snapshot.
select tams_test.check(
  'FAMILY 30c — and the dependant relationship was created back the other way',
  (select count(*) = 1 from public.family_relationships f
    where f.resident_id = tams_test.resident_id_of('SYN0000000016')
      and f.related_resident_id = tams_test.resident_id_of('SYN0000000901')
      and f.relationship_type = 'dependant')
);

select tams_test.check(
  'FAMILY 30d — a grandparent relationship is recorded',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_record_family_relationship(
      tams_test.resident_id_of('SYN0000000901'), tams_test.resident_id_of('SYN0000000017'), 'grandparent')
  $sql$) = 'OK'
);

-- A separate statement: the insert above is only visible to a new snapshot.
select tams_test.check(
  'FAMILY 30e — and the grandchild relationship was created back the other way',
  (select count(*) = 1 from public.family_relationships f
    where f.resident_id = tams_test.resident_id_of('SYN0000000017')
      and f.related_resident_id = tams_test.resident_id_of('SYN0000000901')
      and f.relationship_type = 'grandchild')
);

select tams_test.check(
  'FAMILY 31 — a resident cannot be related to themselves',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_record_family_relationship(
      tams_test.resident_id_of('SYN0000000901'), tams_test.resident_id_of('SYN0000000901'), 'sibling')
  $sql$) = 'TA042'
);

select tams_test.check(
  'FAMILY 32 — the same relationship cannot be recorded twice',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_record_family_relationship(
      tams_test.resident_id_of('SYN0000000901'), tams_test.resident_id_of('SYN0000000009'), 'parent')
  $sql$) = 'TA043'
);

select tams_test.check(
  'FAMILY 32a — a relationship is recorded whose inverse will already exist',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_record_family_relationship(
      tams_test.resident_id_of('SYN0000000003'), tams_test.resident_id_of('SYN0000000001'), 'guardian')
  $sql$) = 'OK'
);

-- A separate statement: the insert above is only visible to a new snapshot.
select tams_test.check(
  'FAMILY 32b — the existing inverse was left alone, not duplicated',
  (select count(*) = 1 from public.family_relationships f
    where f.resident_id = tams_test.resident_id_of('SYN0000000001')
      and f.related_resident_id = tams_test.resident_id_of('SYN0000000003')
      and f.relationship_type = 'dependant')
);

select tams_test.check(
  'FAMILY 32c — an unrecognised relationship type is refused',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_record_family_relationship(
      tams_test.resident_id_of('SYN0000000901'), tams_test.resident_id_of('SYN0000000018'), 'cousin')
  $sql$) = 'TA044'
);

select tams_test.check(
  'FAMILY 34 — a relationship is retired by status, never deleted',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_set_relationship_status(
      (select id from public.family_relationships
        where resident_id = tams_test.resident_id_of('SYN0000000901')
          and related_resident_id = tams_test.resident_id_of('SYN0000000014')
          and relationship_type = 'spouse'), 'inactive')
  $sql$) = 'OK'
);

select tams_test.check(
  'FAMILY 34a — both sides of it are retired together, and both rows remain',
  (select count(*) = 2 from public.family_relationships f
    where ((f.resident_id = tams_test.resident_id_of('SYN0000000901')
            and f.related_resident_id = tams_test.resident_id_of('SYN0000000014'))
        or (f.resident_id = tams_test.resident_id_of('SYN0000000014')
            and f.related_resident_id = tams_test.resident_id_of('SYN0000000901')))
      and f.relationship_status = 'inactive')
);


-- =====================================================================
-- SECURITY
-- =====================================================================

select tams_test.check(
  'SECURITY 34 — an active Registry Clerk is recognised as one',
  tams_test.query_as('authenticated', tams_test.clerk(),
    'select public.is_active_registry_clerk()::text') = 'true'
);

select tams_test.check(
  'SECURITY 35 — a Land Officer cannot read or write the register',
  tams_test.query_as('authenticated', tams_test.uid_of('landofficer2@ta.example'),
    'select count(*)::text from public.registry_search_residents(null)') = 'ERROR:42501'
  and tams_test.run_as('authenticated', tams_test.uid_of('landofficer2@ta.example'), $sql$
    select public.registry_create_resident('SYN0000000910', 'Not', 'Allowed', '1990-01-01', 'Female', 'active')
  $sql$) = '42501'
);

select tams_test.check(
  'SECURITY 36 — a Council Secretary cannot read or write the register',
  tams_test.query_as('authenticated', tams_test.uid_of('councilsec@ta.example'),
    'select count(*)::text from public.registry_search_residents(null)') = 'ERROR:42501'
  and tams_test.run_as('authenticated', tams_test.uid_of('councilsec@ta.example'), $sql$
    select public.registry_create_household('HH-0096', tams_test.site_id_of('RES-0021'), 'active')
  $sql$) = '42501'
);

select tams_test.check(
  'SECURITY 36a — the Council Administrator cannot write the register either',
  tams_test.run_as('authenticated', tams_test.uid_of('admin@ta.example'), $sql$
    select public.registry_create_resident('SYN0000000911', 'Not', 'Allowed', '1990-01-01', 'Female', 'active')
  $sql$) = '42501'
);

select tams_test.check(
  'SECURITY 37 — a signed-out visitor is refused',
  tams_test.query_as('authenticated', null,
    'select count(*)::text from public.registry_search_residents(null)') = 'ERROR:42501'
  and tams_test.query_as('anon', null,
    'select count(*)::text from public.residents') = 'ERROR:42501'
);

select tams_test.check(
  'SECURITY 38 — a Registry Clerk whose account was deactivated is refused',
  tams_test.query_as('authenticated', tams_test.uid_of('exclerk@ta.example'),
    'select count(*)::text from public.registry_search_residents(null)') = 'ERROR:42501'
  and tams_test.run_as('authenticated', tams_test.uid_of('exclerk@ta.example'), $sql$
    select public.registry_create_resident('SYN0000000912', 'Not', 'Allowed', '1990-01-01', 'Female', 'active')
  $sql$) = '42501'
  and tams_test.query_as('authenticated', tams_test.uid_of('exclerk@ta.example'),
    'select count(*)::text from public.residents') = '0'
);

select tams_test.check(
  'SECURITY 39 — a Registry Clerk cannot touch land sites or land allocations',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    update public.land_sites set street_address = 'moved' where site_code = 'RES-0001'
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    insert into public.land_allocations (allocation_reference, land_site_id, resident_id, allocation_date, allocation_status)
    values ('ALLOC-9999', tams_test.site_id_of('RES-0021'), tams_test.resident_id_of('SYN0000000901'), '2026-01-01', 'active')
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    update public.land_allocations set allocation_date = '2000-01-01'
  $sql$) = '42501'
);

select tams_test.check(
  'SECURITY 40 — a Registry Clerk cannot write the register directly, only through these functions',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    insert into public.residents (id_number, first_name, last_name, date_of_birth, gender, resident_status)
    values ('SYN0000000913', 'Direct', 'Write', '1990-01-01', 'Female', 'active')
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    update public.residents set household_id = null
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    delete from public.family_relationships
  $sql$) = '42501'
);

select tams_test.check(
  'SECURITY 41 — a Registry Clerk cannot manage staff',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.change_staff_role(tams_test.staff_id_of('2026024'), tams_test.role_id_of('Land Officer'))
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.deactivate_staff_account(tams_test.staff_id_of('2026024'), 'Not allowed')
  $sql$) = '42501'
  and tams_test.query_as('authenticated', tams_test.clerk(),
    'select count(*)::text from public.admin_staff_accounts()') = 'ERROR:42501'
);
