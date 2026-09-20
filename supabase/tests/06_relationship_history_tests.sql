-- =====================================================================
-- TAMS — family relationship history
--
-- Permanent lineage cannot be ended. Marriages and guardianships can
-- end, and can begin again later as a new episode, without erasing the
-- one before.
-- =====================================================================

create function tams_test.relationship_id(p_from text, p_to text, p_type text, p_status text default 'active')
returns uuid language sql stable security definer as $$
  select f.id from public.family_relationships f
  where f.resident_id = tams_test.resident_id_of(p_from)
    and f.related_resident_id = tams_test.resident_id_of(p_to)
    and f.relationship_type = p_type
    and f.relationship_status = p_status
  order by f.relationship_started_at desc nulls last limit 1;
$$;

-- ---- permanent lineage is permanent ---------------------------------

select tams_test.check(
  'HISTORY 1 — a parent relationship cannot be ended',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_end_family_relationship(
      tams_test.relationship_id('SYN0000000001', 'SYN0000000003', 'parent'), '2026-01-01')
  $sql$) = 'TA046'
);

select tams_test.check(
  'HISTORY 2 — a sibling relationship cannot be ended',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_end_family_relationship(
      tams_test.relationship_id('SYN0000000005', 'SYN0000000006', 'sibling'), '2026-01-01')
  $sql$) = 'TA046'
);

select tams_test.check(
  'HISTORY 3 — a grandparent relationship cannot be ended',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_end_family_relationship(
      tams_test.relationship_id('SYN0000000001', 'SYN0000000005', 'grandparent'), '2026-01-01')
  $sql$) = 'TA046'
);

select tams_test.check(
  'HISTORY 3a — a child relationship cannot be ended either',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_end_family_relationship(
      tams_test.relationship_id('SYN0000000003', 'SYN0000000001', 'child'), '2026-01-01')
  $sql$) = 'TA046'
);

select tams_test.check(
  'HISTORY 3b — those refusals left every one of them current',
  tams_test.relationship_id('SYN0000000001', 'SYN0000000003', 'parent') is not null
  and tams_test.relationship_id('SYN0000000003', 'SYN0000000001', 'child') is not null
  and tams_test.relationship_id('SYN0000000005', 'SYN0000000006', 'sibling') is not null
  and tams_test.relationship_id('SYN0000000001', 'SYN0000000005', 'grandparent') is not null
);

-- ---- a marriage begins, ends, and begins again ----------------------

select tams_test.check(
  'HISTORY 4a — a new marriage must say when it began',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_record_family_relationship(
      tams_test.resident_id_of('SYN0000000020'), tams_test.resident_id_of('SYN0000000021'), 'spouse')
  $sql$) = 'TA049'
);

select tams_test.check(
  'HISTORY 4b — permanent lineage needs no date',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_record_family_relationship(
      tams_test.resident_id_of('SYN0000000020'), tams_test.resident_id_of('SYN0000000035'), 'sibling')
  $sql$) = 'OK'
);

select tams_test.check(
  'HISTORY 4 — Thabo and Lerato marry',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_record_family_relationship(
      tams_test.resident_id_of('SYN0000000023'), tams_test.resident_id_of('SYN0000000024'),
      'spouse', '2010-05-15')
  $sql$) = 'OK'
);

select tams_test.check(
  'HISTORY 4c — both sides record the same starting date',
  (select count(*) = 2 from public.family_relationships f
    where f.relationship_type = 'spouse' and f.relationship_status = 'active'
      and f.relationship_started_at = '2010-05-15'
      and ((f.resident_id = tams_test.resident_id_of('SYN0000000023')
            and f.related_resident_id = tams_test.resident_id_of('SYN0000000024'))
        or (f.resident_id = tams_test.resident_id_of('SYN0000000024')
            and f.related_resident_id = tams_test.resident_id_of('SYN0000000023'))))
);

select tams_test.check(
  'HISTORY 10 — a second current marriage to the same person is refused',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_record_family_relationship(
      tams_test.resident_id_of('SYN0000000023'), tams_test.resident_id_of('SYN0000000024'),
      'spouse', '2012-01-01')
  $sql$) = 'TA043'
);

select tams_test.check(
  'HISTORY 7 — a marriage cannot end before it began',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_end_family_relationship(
      tams_test.relationship_id('SYN0000000023', 'SYN0000000024', 'spouse'), '2009-01-01')
  $sql$) = 'TA048'
);

select tams_test.check(
  'HISTORY 4d — the marriage is ended',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_end_family_relationship(
      tams_test.relationship_id('SYN0000000023', 'SYN0000000024', 'spouse'), '2022-08-01')
  $sql$) = 'OK'
);

select tams_test.check(
  'HISTORY 6 — ending it ended both directions, on the same date',
  (select count(*) = 2 from public.family_relationships f
    where f.relationship_type = 'spouse' and f.relationship_status = 'inactive'
      and f.relationship_ended_at = '2022-08-01'
      and f.relationship_started_at = '2010-05-15'
      and ((f.resident_id = tams_test.resident_id_of('SYN0000000023')
            and f.related_resident_id = tams_test.resident_id_of('SYN0000000024'))
        or (f.resident_id = tams_test.resident_id_of('SYN0000000024')
            and f.related_resident_id = tams_test.resident_id_of('SYN0000000023'))))
);

select tams_test.check(
  'HISTORY 4e — an ended marriage cannot be ended again',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_end_family_relationship(
      (select id from public.family_relationships
        where resident_id = tams_test.resident_id_of('SYN0000000023')
          and related_resident_id = tams_test.resident_id_of('SYN0000000024')
          and relationship_type = 'spouse' and relationship_status = 'inactive'), '2023-01-01')
  $sql$) = 'TA047'
);

select tams_test.check(
  'HISTORY 8 — the same two people marry again: a new episode',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_record_family_relationship(
      tams_test.resident_id_of('SYN0000000023'), tams_test.resident_id_of('SYN0000000024'),
      'spouse', '2025-03-10')
  $sql$) = 'OK'
);

select tams_test.check(
  'HISTORY 9 — the first marriage is still on record, untouched',
  (select count(*) = 1 from public.family_relationships f
    where f.resident_id = tams_test.resident_id_of('SYN0000000023')
      and f.related_resident_id = tams_test.resident_id_of('SYN0000000024')
      and f.relationship_type = 'spouse'
      and f.relationship_status = 'inactive'
      and f.relationship_started_at = '2010-05-15'
      and f.relationship_ended_at = '2022-08-01')
  and (select count(*) = 1 from public.family_relationships f
        where f.resident_id = tams_test.resident_id_of('SYN0000000023')
          and f.related_resident_id = tams_test.resident_id_of('SYN0000000024')
          and f.relationship_type = 'spouse'
          and f.relationship_status = 'active'
          and f.relationship_started_at = '2025-03-10'
          and f.relationship_ended_at is null)
);

-- ---- guardianship, the same way -------------------------------------

select tams_test.check(
  'HISTORY 5 — a guardianship begins',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_record_family_relationship(
      tams_test.resident_id_of('SYN0000000033'), tams_test.resident_id_of('SYN0000000034'),
      'guardian', '2018-01-20')
  $sql$) = 'OK'
);

select tams_test.check(
  'HISTORY 5a — it is ended',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_end_family_relationship(
      tams_test.relationship_id('SYN0000000033', 'SYN0000000034', 'guardian'), '2021-06-30')
  $sql$) = 'OK'
);

select tams_test.check(
  'HISTORY 5b — the dependant side ended with it',
  (select relationship_status = 'inactive' and relationship_ended_at = '2021-06-30'
   from public.family_relationships
   where resident_id = tams_test.resident_id_of('SYN0000000034')
     and related_resident_id = tams_test.resident_id_of('SYN0000000033')
     and relationship_type = 'dependant')
);

select tams_test.check(
  'HISTORY 11 — the guardianship begins again as a new episode',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_record_family_relationship(
      tams_test.resident_id_of('SYN0000000033'), tams_test.resident_id_of('SYN0000000034'),
      'guardian', '2024-02-01')
  $sql$) = 'OK'
);

select tams_test.check(
  'HISTORY 11a — two episodes on record, one ended and one current',
  (select count(*) = 2 from public.family_relationships f
    where f.resident_id = tams_test.resident_id_of('SYN0000000033')
      and f.related_resident_id = tams_test.resident_id_of('SYN0000000034')
      and f.relationship_type = 'guardian')
);

-- ---- more than one current spouse is not the database's business ----

select tams_test.check(
  'HISTORY 12 — a second current spouse, to a different person, is allowed',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_record_family_relationship(
      tams_test.resident_id_of('SYN0000000023'), tams_test.resident_id_of('SYN0000000027'),
      'spouse', '2025-09-01')
  $sql$) = 'OK'
);

select tams_test.check(
  'HISTORY 12a — that resident now has two current spouses',
  (select count(*) = 2 from public.family_relationships f
    where f.resident_id = tams_test.resident_id_of('SYN0000000023')
      and f.relationship_type = 'spouse' and f.relationship_status = 'active')
);

-- ---- the imported relationships are exactly as they were ------------

select tams_test.check(
  'HISTORY 13 — every imported relationship is still there, current, and undated',
  (select count(*) = 200 from tams_test.imported_relationships)
  and (select count(*) = 200
       from public.family_relationships f
       join tams_test.imported_relationships i on i.id = f.id
       where f.relationship_status = 'active'
         and f.relationship_started_at is null
         and f.relationship_ended_at is null)
);

select tams_test.check(
  'HISTORY 13a — the lineage view reports which relationships have episodes',
  tams_test.query_as('authenticated', tams_test.clerk(), $sql$
    select string_agg(distinct relationship_type || '=' || time_based::text, ', ' order by relationship_type || '=' || time_based::text)
    from public.registry_family_lineage(tams_test.resident_id_of('SYN0000000023'))
  $sql$) like '%spouse=true%'
);
