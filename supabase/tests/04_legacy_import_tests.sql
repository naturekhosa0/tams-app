-- =====================================================================
-- TAMS — legacy village data import tests
--
-- Runs in three parts:
--   1. validation and rollback, against empty tables;
--   2. the real import, from the real CSV payload;
--   3. the database's own rules, against the imported data.
-- =====================================================================

create function tams_test.try_import(p_payload jsonb)
returns text language plpgsql as $$
begin
  perform public.import_legacy_village_data(p_payload);
  return 'OK';
exception when others then
  return sqlstate;
end;
$$;

create function tams_test.import_problem(p_payload jsonb)
returns text language plpgsql as $$
begin
  perform public.import_legacy_village_data(p_payload);
  return 'no problem reported';
exception when others then
  return sqlerrm;
end;
$$;

create function tams_test.village_is_empty()
returns boolean language sql stable as $$
  select not exists (select 1 from public.land_sites)
     and not exists (select 1 from public.residents)
     and not exists (select 1 from public.households)
     and not exists (select 1 from public.family_relationships)
     and not exists (select 1 from public.land_allocations);
$$;

-- A small, entirely valid dataset. Each test below breaks exactly one
-- thing about it, so what is being tested is never in doubt.
-- Note that the allocation holder (R-2) is not the head of the
-- household (R-1) — as in the real data.
create function tams_test.mini_payload()
returns jsonb language sql immutable as $$
  select jsonb_build_object(
    'land_sites', jsonb_build_array(
      jsonb_build_object('site_code', 'S-1', 'site_type', 'residential', 'stand_number', 'ST-1',
                         'street_address', '1 Main Street', 'village_section', 'A',
                         'village_name', 'Testville', 'site_status', 'allocated'),
      jsonb_build_object('site_code', 'S-2', 'site_type', 'residential', 'stand_number', 'ST-2',
                         'street_address', '2 Main Street', 'village_section', 'A',
                         'village_name', 'Testville', 'site_status', 'allocated')),
    'residents', jsonb_build_array(
      jsonb_build_object('resident_code', 'R-1', 'id_number', '6001010001081', 'first_name', 'Ada',
                         'last_name', 'Khoza', 'date_of_birth', '1960-01-01', 'gender', 'female',
                         'contact_number', '0720000001', 'email', '', 'resident_status', 'active'),
      jsonb_build_object('resident_code', 'R-2', 'id_number', '6202020002082', 'first_name', 'Ben',
                         'last_name', 'Khoza', 'date_of_birth', '1962-02-02', 'gender', 'male',
                         'contact_number', '0720000002', 'email', '', 'resident_status', 'active'),
      jsonb_build_object('resident_code', 'R-3', 'id_number', '9003030003083', 'first_name', 'Cee',
                         'last_name', 'Khoza', 'date_of_birth', '1990-03-03', 'gender', 'female',
                         'contact_number', '0720000003', 'email', '', 'resident_status', 'active')),
    'households', jsonb_build_array(
      jsonb_build_object('household_code', 'HH-1', 'primary_site_code', 'S-1',
                         'head_resident_code', 'R-1', 'household_status', 'active')),
    'household_memberships', jsonb_build_array(
      jsonb_build_object('household_code', 'HH-1', 'resident_code', 'R-1'),
      jsonb_build_object('household_code', 'HH-1', 'resident_code', 'R-2'),
      jsonb_build_object('household_code', 'HH-1', 'resident_code', 'R-3')),
    'family_relationships', jsonb_build_array(
      jsonb_build_object('resident_code', 'R-1', 'related_resident_code', 'R-2',
                         'relationship_type', 'spouse', 'relationship_status', 'active'),
      jsonb_build_object('resident_code', 'R-1', 'related_resident_code', 'R-3',
                         'relationship_type', 'parent', 'relationship_status', 'active')),
    'land_allocations', jsonb_build_array(
      jsonb_build_object('allocation_code', 'A-1', 'site_code', 'S-1', 'allocated_to_resident_code', 'R-2',
                         'allocation_date', '1995-05-05', 'allocation_status', 'active'))
  );
$$;

-- Replaces one file inside the otherwise valid payload.
create function tams_test.payload_with(p_key text, p_rows jsonb)
returns jsonb language sql immutable as $$
  select tams_test.mini_payload() || jsonb_build_object(p_key, p_rows);
$$;


-- =====================================================================
-- 1. Validation — every one of these must write nothing at all
-- =====================================================================

select tams_test.check(
  'IMPORT — the village records start empty',
  tams_test.village_is_empty()
);

select tams_test.check(
  'IMPORT 1 — duplicate site codes are refused',
  tams_test.try_import(tams_test.payload_with('land_sites', jsonb_build_array(
    jsonb_build_object('site_code', 'S-1', 'site_type', 'residential', 'street_address', '1 Main', 'site_status', 'allocated'),
    jsonb_build_object('site_code', 'S-1', 'site_type', 'residential', 'street_address', '2 Main', 'site_status', 'allocated')
  ))) = 'TA020'
);

select tams_test.check(
  'IMPORT 1a — duplicate stand numbers are refused',
  tams_test.try_import(tams_test.payload_with('land_sites', jsonb_build_array(
    jsonb_build_object('site_code', 'S-1', 'site_type', 'residential', 'stand_number', 'ST-9', 'street_address', '1 Main', 'site_status', 'allocated'),
    jsonb_build_object('site_code', 'S-2', 'site_type', 'residential', 'stand_number', 'ST-9', 'street_address', '2 Main', 'site_status', 'allocated')
  ))) = 'TA020'
);

select tams_test.check(
  'IMPORT 1b — an unrecognised site type is refused',
  tams_test.try_import(tams_test.payload_with('land_sites', jsonb_build_array(
    jsonb_build_object('site_code', 'S-1', 'site_type', 'commercial', 'street_address', '1 Main', 'site_status', 'allocated'),
    jsonb_build_object('site_code', 'S-2', 'site_type', 'residential', 'street_address', '2 Main', 'site_status', 'allocated')
  ))) = 'TA020'
);

select tams_test.check(
  'IMPORT 2 — duplicate resident identity numbers are refused',
  tams_test.try_import(tams_test.payload_with('residents', jsonb_build_array(
    jsonb_build_object('resident_code', 'R-1', 'id_number', '6001010001081', 'first_name', 'Ada', 'last_name', 'Khoza',
                       'date_of_birth', '1960-01-01', 'gender', 'female', 'resident_status', 'active'),
    jsonb_build_object('resident_code', 'R-2', 'id_number', '6001010001081', 'first_name', 'Ben', 'last_name', 'Khoza',
                       'date_of_birth', '1962-02-02', 'gender', 'male', 'resident_status', 'active'),
    jsonb_build_object('resident_code', 'R-3', 'id_number', '9003030003083', 'first_name', 'Cee', 'last_name', 'Khoza',
                       'date_of_birth', '1990-03-03', 'gender', 'female', 'resident_status', 'active')
  ))) = 'TA020'
);

select tams_test.check(
  'IMPORT 2a — a duplicate resident code is refused',
  tams_test.try_import(tams_test.payload_with('residents', jsonb_build_array(
    jsonb_build_object('resident_code', 'R-1', 'id_number', '6001010001081', 'first_name', 'Ada', 'last_name', 'Khoza',
                       'date_of_birth', '1960-01-01', 'gender', 'female', 'resident_status', 'active'),
    jsonb_build_object('resident_code', 'R-1', 'id_number', '6202020002082', 'first_name', 'Ben', 'last_name', 'Khoza',
                       'date_of_birth', '1962-02-02', 'gender', 'male', 'resident_status', 'active'),
    jsonb_build_object('resident_code', 'R-3', 'id_number', '9003030003083', 'first_name', 'Cee', 'last_name', 'Khoza',
                       'date_of_birth', '1990-03-03', 'gender', 'female', 'resident_status', 'active')
  ))) = 'TA020'
);

select tams_test.check(
  'IMPORT 2b — an impossible date of birth is refused',
  tams_test.try_import(tams_test.payload_with('residents', jsonb_build_array(
    jsonb_build_object('resident_code', 'R-1', 'id_number', '6001010001081', 'first_name', 'Ada', 'last_name', 'Khoza',
                       'date_of_birth', '1960-02-31', 'gender', 'female', 'resident_status', 'active'),
    jsonb_build_object('resident_code', 'R-2', 'id_number', '6202020002082', 'first_name', 'Ben', 'last_name', 'Khoza',
                       'date_of_birth', '1962-02-02', 'gender', 'male', 'resident_status', 'active'),
    jsonb_build_object('resident_code', 'R-3', 'id_number', '9003030003083', 'first_name', 'Cee', 'last_name', 'Khoza',
                       'date_of_birth', '1990-03-03', 'gender', 'female', 'resident_status', 'active')
  ))) = 'TA020'
);

select tams_test.check(
  'IMPORT 3 — duplicate household codes are refused',
  tams_test.try_import(tams_test.payload_with('households', jsonb_build_array(
    jsonb_build_object('household_code', 'HH-1', 'primary_site_code', 'S-1', 'head_resident_code', 'R-1', 'household_status', 'active'),
    jsonb_build_object('household_code', 'HH-1', 'primary_site_code', 'S-2', 'head_resident_code', 'R-2', 'household_status', 'active')
  ))) = 'TA020'
);

select tams_test.check(
  'IMPORT 3a — two current households on one site are refused',
  tams_test.try_import(tams_test.payload_with('households', jsonb_build_array(
    jsonb_build_object('household_code', 'HH-1', 'primary_site_code', 'S-1', 'head_resident_code', 'R-1', 'household_status', 'active'),
    jsonb_build_object('household_code', 'HH-2', 'primary_site_code', 'S-1', 'head_resident_code', 'R-3', 'household_status', 'active')
  ))) = 'TA020'
);

select tams_test.check(
  'IMPORT 4 — an unknown site reference is refused',
  tams_test.try_import(tams_test.payload_with('households', jsonb_build_array(
    jsonb_build_object('household_code', 'HH-1', 'primary_site_code', 'S-999', 'head_resident_code', 'R-1', 'household_status', 'active')
  ))) = 'TA020'
);

select tams_test.check(
  'IMPORT 4a — the message names the file, the line and the missing code',
  tams_test.import_problem(tams_test.payload_with('households', jsonb_build_array(
    jsonb_build_object('household_code', 'HH-1', 'primary_site_code', 'S-999', 'head_resident_code', 'R-1', 'household_status', 'active')
  ))) like '%households line 1 (HH-1): no land site has site_code ''S-999''%'
);

select tams_test.check(
  'IMPORT 5 — an unknown resident reference in the memberships is refused',
  tams_test.try_import(tams_test.payload_with('household_memberships', jsonb_build_array(
    jsonb_build_object('household_code', 'HH-1', 'resident_code', 'R-1'),
    jsonb_build_object('household_code', 'HH-1', 'resident_code', 'R-999')
  ))) = 'TA020'
);

select tams_test.check(
  'IMPORT 5a — an unknown household reference in the memberships is refused',
  tams_test.try_import(tams_test.payload_with('household_memberships', jsonb_build_array(
    jsonb_build_object('household_code', 'HH-1', 'resident_code', 'R-1'),
    jsonb_build_object('household_code', 'HH-999', 'resident_code', 'R-2')
  ))) = 'TA020'
);

select tams_test.check(
  'IMPORT 6 — a household head who is not a member of that household is refused',
  tams_test.try_import(tams_test.payload_with('household_memberships', jsonb_build_array(
    jsonb_build_object('household_code', 'HH-1', 'resident_code', 'R-2'),
    jsonb_build_object('household_code', 'HH-1', 'resident_code', 'R-3')
  ))) = 'TA020'
);

select tams_test.check(
  'IMPORT 6a — the message says so plainly',
  tams_test.import_problem(tams_test.payload_with('household_memberships', jsonb_build_array(
    jsonb_build_object('household_code', 'HH-1', 'resident_code', 'R-2'),
    jsonb_build_object('household_code', 'HH-1', 'resident_code', 'R-3')
  ))) like '%head ''R-1'' is not a member of that household%'
);

select tams_test.check(
  'IMPORT 7 — a resident listed in two households is refused',
  tams_test.try_import(
    tams_test.mini_payload()
    || jsonb_build_object('households', jsonb_build_array(
         jsonb_build_object('household_code', 'HH-1', 'primary_site_code', 'S-1', 'head_resident_code', 'R-1', 'household_status', 'active'),
         jsonb_build_object('household_code', 'HH-2', 'primary_site_code', 'S-2', 'head_resident_code', 'R-3', 'household_status', 'active')))
    || jsonb_build_object('household_memberships', jsonb_build_array(
         jsonb_build_object('household_code', 'HH-1', 'resident_code', 'R-1'),
         jsonb_build_object('household_code', 'HH-1', 'resident_code', 'R-2'),
         jsonb_build_object('household_code', 'HH-2', 'resident_code', 'R-2'),
         jsonb_build_object('household_code', 'HH-2', 'resident_code', 'R-3')))
  ) = 'TA020'
);

select tams_test.check(
  'IMPORT 8 — a resident related to themselves is refused',
  tams_test.try_import(tams_test.payload_with('family_relationships', jsonb_build_array(
    jsonb_build_object('resident_code', 'R-1', 'related_resident_code', 'R-1',
                       'relationship_type', 'sibling', 'relationship_status', 'active')
  ))) = 'TA020'
);

select tams_test.check(
  'IMPORT 9 — a duplicate family relationship is refused',
  tams_test.try_import(tams_test.payload_with('family_relationships', jsonb_build_array(
    jsonb_build_object('resident_code', 'R-1', 'related_resident_code', 'R-2',
                       'relationship_type', 'spouse', 'relationship_status', 'active'),
    jsonb_build_object('resident_code', 'R-1', 'related_resident_code', 'R-2',
                       'relationship_type', 'spouse', 'relationship_status', 'active')
  ))) = 'TA020'
);

select tams_test.check(
  'IMPORT 10 — an unrecognised relationship type is refused',
  tams_test.try_import(tams_test.payload_with('family_relationships', jsonb_build_array(
    jsonb_build_object('resident_code', 'R-1', 'related_resident_code', 'R-2',
                       'relationship_type', 'cousin', 'relationship_status', 'active')
  ))) = 'TA020'
);

select tams_test.check(
  'IMPORT 10a — an unknown resident in a relationship is refused',
  tams_test.try_import(tams_test.payload_with('family_relationships', jsonb_build_array(
    jsonb_build_object('resident_code', 'R-1', 'related_resident_code', 'R-999',
                       'relationship_type', 'sibling', 'relationship_status', 'active')
  ))) = 'TA020'
);

select tams_test.check(
  'IMPORT 11 — two active allocations for one site are refused',
  tams_test.try_import(tams_test.payload_with('land_allocations', jsonb_build_array(
    jsonb_build_object('allocation_code', 'A-1', 'site_code', 'S-1', 'allocated_to_resident_code', 'R-1',
                       'allocation_date', '1995-05-05', 'allocation_status', 'active'),
    jsonb_build_object('allocation_code', 'A-2', 'site_code', 'S-1', 'allocated_to_resident_code', 'R-2',
                       'allocation_date', '1999-09-09', 'allocation_status', 'active')
  ))) = 'TA020'
);

select tams_test.check(
  'IMPORT 11a — a duplicate allocation reference is refused',
  tams_test.try_import(tams_test.payload_with('land_allocations', jsonb_build_array(
    jsonb_build_object('allocation_code', 'A-1', 'site_code', 'S-1', 'allocated_to_resident_code', 'R-1',
                       'allocation_date', '1995-05-05', 'allocation_status', 'active'),
    jsonb_build_object('allocation_code', 'A-1', 'site_code', 'S-2', 'allocated_to_resident_code', 'R-2',
                       'allocation_date', '1999-09-09', 'allocation_status', 'active')
  ))) = 'TA020'
);

select tams_test.check(
  'IMPORT 12 — an allocation to a missing resident is refused',
  tams_test.try_import(tams_test.payload_with('land_allocations', jsonb_build_array(
    jsonb_build_object('allocation_code', 'A-1', 'site_code', 'S-1', 'allocated_to_resident_code', 'R-999',
                       'allocation_date', '1995-05-05', 'allocation_status', 'active')
  ))) = 'TA020'
);

select tams_test.check(
  'IMPORT 13 — an allocation on a missing site is refused',
  tams_test.try_import(tams_test.payload_with('land_allocations', jsonb_build_array(
    jsonb_build_object('allocation_code', 'A-1', 'site_code', 'S-999', 'allocated_to_resident_code', 'R-1',
                       'allocation_date', '1995-05-05', 'allocation_status', 'active')
  ))) = 'TA020'
);

select tams_test.check(
  'IMPORT 14 — every problem is reported at once, not one at a time',
  (select count(*) >= 3 from regexp_split_to_table(
     tams_test.import_problem(
       tams_test.payload_with('land_allocations', jsonb_build_array(
         jsonb_build_object('allocation_code', 'A-1', 'site_code', 'S-999', 'allocated_to_resident_code', 'R-999',
                            'allocation_date', 'not-a-date', 'allocation_status', 'active')))),
     E'\n') as line
   where line like 'land_allocations%')
);

select tams_test.check(
  'IMPORT 15 — after every refusal above, nothing whatsoever was written',
  tams_test.village_is_empty()
);


-- =====================================================================
-- 2. The real import
--
-- The payload is the real CSV package, read from the file the test
-- runner built with scripts/build-import-payload.mjs — the same builder
-- the real import command uses.
-- =====================================================================

create function tams_test.real_payload()
returns jsonb language sql stable as $real$
  select pg_read_file(current_setting('tams.payload_path'))::jsonb;
$real$;

select set_config('tams.payload_path', :'payload_path', false);

select tams_test.check(
  'IMPORT 16 — the supplied village data imports successfully',
  tams_test.try_import(tams_test.real_payload()) = 'OK'
);

-- Exactly what the import produced, so later suites can prove these
-- rows were never touched.
create table tams_test.imported_relationships as
  select id from public.family_relationships;

select tams_test.check(
  'IMPORT 17 — the import refuses to run a second time',
  tams_test.try_import(tams_test.real_payload()) = 'TA022'
);

select tams_test.check(
  'IMPORT 18 — no import key was kept anywhere in the schema',
  not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and column_name in ('resident_code', 'household_code_import', 'site_code_import',
                          'allocation_code', 'primary_site_code', 'head_resident_code')
      and table_name in ('residents', 'family_relationships', 'land_allocations'))
  and not exists (
    select 1 from information_schema.tables
    where table_schema = 'public' and table_name = 'household_memberships')
);

select tams_test.check(
  'IMPORT 19 — none of the excluded columns were created',
  not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name in ('land_sites', 'residents', 'households', 'family_relationships', 'land_allocations')
      and column_name in ('notes', 'data_source', 'current_allocation', 'occupancy_status',
                          'household_category', 'established_year', 'member_status',
                          'relationship_to_head', 'staff_status'))
);


-- =====================================================================
-- 3. The database's own rules, now that there is data
-- =====================================================================

select tams_test.check(
  'RULE 1 — a second site cannot reuse a site code',
  tams_test.run_as('service_role', null, $sql$
    insert into public.land_sites (site_code, site_type, street_address, site_status)
    select site_code, 'residential', 'somewhere else', 'allocated' from public.land_sites limit 1
  $sql$) = '23505'
);

select tams_test.check(
  'RULE 2 — a second resident cannot reuse an identity number',
  tams_test.run_as('service_role', null, $sql$
    insert into public.residents (id_number, first_name, last_name, date_of_birth, gender, resident_status)
    select id_number, 'Copy', 'Cat', '1990-01-01', 'female', 'active' from public.residents limit 1
  $sql$) = '23505'
);

select tams_test.check(
  'RULE 3 — a second household cannot reuse a household code',
  tams_test.run_as('service_role', null, $sql$
    insert into public.households (household_code, residential_site_id, household_status)
    select h.household_code, h.residential_site_id, 'inactive' from public.households h limit 1
  $sql$) = '23505'
);

select tams_test.check(
  'RULE 4 — a resident cannot be related to themselves',
  tams_test.run_as('service_role', null, $sql$
    insert into public.family_relationships (resident_id, related_resident_id, relationship_type, relationship_status)
    select r.id, r.id, 'sibling', 'active' from public.residents r limit 1
  $sql$) = '23514'
);

select tams_test.check(
  'RULE 5 — the same relationship cannot be recorded twice',
  tams_test.run_as('service_role', null, $sql$
    insert into public.family_relationships (resident_id, related_resident_id, relationship_type, relationship_status)
    select resident_id, related_resident_id, relationship_type, relationship_status
    from public.family_relationships limit 1
  $sql$) = '23505'
);

select tams_test.check(
  'RULE 6 — an unrecognised relationship type is refused',
  tams_test.run_as('service_role', null, $sql$
    insert into public.family_relationships (resident_id, related_resident_id, relationship_type, relationship_status)
    select a.id, b.id, 'cousin', 'active'
    from public.residents a, public.residents b where a.id <> b.id limit 1
  $sql$) = '23514'
);

select tams_test.check(
  'RULE 7 — a site cannot carry two active allocations',
  tams_test.run_as('service_role', null, $sql$
    insert into public.land_allocations (allocation_reference, land_site_id, resident_id, allocation_date, allocation_status)
    select 'ALLOC-DUPLICATE', a.land_site_id, a.resident_id, '2026-01-01', 'active'
    from public.land_allocations a limit 1
  $sql$) = '23505'
);

select tams_test.check(
  'RULE 8 — a second current household cannot claim an occupied site',
  tams_test.run_as('service_role', null, $sql$
    insert into public.households (household_code, residential_site_id, household_status)
    select 'HH-INTRUDER', h.residential_site_id, 'active' from public.households h limit 1
  $sql$) = '23505'
);

-- Rules 9 and 10 are deferred to the end of the transaction, so the
-- check is forced to run immediately to be caught here.
do $$
declare v_outcome text;
begin
  begin
    update public.households h
       set head_resident_id = (select r.id from public.residents r
                                where r.household_id is distinct from h.id limit 1)
     where h.household_code = 'HH-0001';
    execute 'set constraints all immediate';
    v_outcome := 'OK';
  exception when others then
    v_outcome := sqlstate;
  end;
  perform tams_test.check(
    'RULE 9 — a household head must be a resident of that household', v_outcome = 'TA021', v_outcome);
end;
$$;

do $$
declare v_outcome text;
begin
  begin
    update public.residents set household_id = null
    where id = (select head_resident_id from public.households where household_code = 'HH-0001');
    execute 'set constraints all immediate';
    v_outcome := 'OK';
  exception when others then
    v_outcome := sqlstate;
  end;
  perform tams_test.check(
    'RULE 10 — a head cannot be moved out of the household they head', v_outcome = 'TA021', v_outcome);
end;
$$;

select tams_test.check(
  'RULE 10a — those refusals changed nothing',
  (select r.household_id = h.id
   from public.households h join public.residents r on r.id = h.head_resident_id
   where h.household_code = 'HH-0001')
);

-- =====================================================================
-- 4. Row Level Security
-- =====================================================================

select tams_test.check(
  'RLS 1 — a signed-out visitor can read no village records',
  tams_test.query_as('anon', null, 'select count(*)::text from public.residents') = 'ERROR:42501'
);

-- Row Level Security decides this, not a missing grant: the Council
-- Administrator manages staff, not the village register, so the
-- register returns nothing at all to them.
select tams_test.check(
  'RLS 2 — the Council Administrator can read no village records',
  tams_test.query_as('authenticated', tams_test.uid_of('admin@ta.example'),
    'select count(*)::text from public.residents') = '0'
  and tams_test.query_as('authenticated', tams_test.uid_of('admin@ta.example'),
    'select count(*)::text from public.households') = '0'
  and tams_test.query_as('authenticated', tams_test.uid_of('admin@ta.example'),
    'select count(*)::text from public.land_allocations') = '0'
);

select tams_test.check(
  'RLS 3 — the Council Administrator cannot write village records either',
  tams_test.run_as('authenticated', tams_test.uid_of('admin@ta.example'), $sql$
    insert into public.land_sites (site_code, site_type, street_address, site_status)
    values ('RES-9999', 'residential', 'nowhere', 'allocated')
  $sql$) = '42501'
);

select tams_test.check(
  'RLS 4 — no signed-in user can run the importer',
  tams_test.run_as('authenticated', tams_test.uid_of('admin@ta.example'),
    $sql$select public.import_legacy_village_data('{}'::jsonb)$sql$) = '42501'
);

select tams_test.check(
  'RLS 5 — a signed-out visitor cannot run the importer',
  tams_test.run_as('anon', null,
    $sql$select public.import_legacy_village_data('{}'::jsonb)$sql$) = '42501'
);

select tams_test.check(
  'RLS 6 — every village table has Row Level Security switched on',
  (select count(*) = 5 from pg_tables
    where schemaname = 'public' and rowsecurity
      and tablename in ('land_sites', 'residents', 'households',
                        'family_relationships', 'land_allocations'))
);
