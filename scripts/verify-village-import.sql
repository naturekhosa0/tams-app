-- =====================================================================
-- After the legacy import: what came in, and does it hang together?
--
-- Run in the Supabase SQL Editor, or with psql, once
-- scripts/import-legacy-data.mjs has finished.
-- =====================================================================

\echo ''
\echo '=== Totals ==='
select 'land sites'                     as record, count(*) from public.land_sites
union all select 'residents',                      count(*) from public.residents
union all select 'households',                     count(*) from public.households
union all select 'residents linked to a household', count(*) from public.residents where household_id is not null
union all select 'family relationships',           count(*) from public.family_relationships
union all select 'land allocations',               count(*) from public.land_allocations
union all select 'active land allocations',        count(*) from public.land_allocations where allocation_status = 'active';

\echo ''
\echo '=== Integrity: every one of these must be zero ==='
select 'residents with no household'          as problem,
       count(*) from public.residents where household_id is null
union all
select 'households whose head is not a member of it',
       count(*) from public.households h
       where h.head_resident_id is not null
         and not exists (select 1 from public.residents r
                          where r.id = h.head_resident_id and r.household_id = h.id)
union all
select 'sites with more than one active allocation',
       count(*) from (select land_site_id from public.land_allocations
                       where allocation_status = 'active'
                       group by land_site_id having count(*) > 1) t
union all
select 'sites lived on by more than one current household',
       count(*) from (select residential_site_id from public.households
                       where household_status = 'active'
                       group by residential_site_id having count(*) > 1) t
union all
select 'relationships pointing at a resident twice',
       count(*) from public.family_relationships where resident_id = related_resident_id;

\echo ''
\echo '=== Where the household head is NOT the land allocation holder ==='
select h.household_code,
       s.site_code,
       s.street_address,
       head.first_name || ' ' || head.last_name as household_head,
       holder.first_name || ' ' || holder.last_name as allocation_holder,
       a.allocation_reference,
       a.allocation_date
from public.households h
join public.land_sites s   on s.id = h.residential_site_id
join public.residents head on head.id = h.head_resident_id
join public.land_allocations a on a.land_site_id = s.id and a.allocation_status = 'active'
join public.residents holder   on holder.id = a.resident_id
where holder.id <> head.id
order by h.household_code;

\echo ''
\echo '=== A site in full: site, household, head, members, allocation ==='
select s.site_code,
       s.street_address || ', ' || coalesce(s.village_section, '') as address,
       h.household_code,
       head.first_name || ' ' || head.last_name as head_of_household,
       (select count(*) from public.residents m where m.household_id = h.id) as members,
       holder.first_name || ' ' || holder.last_name as allocated_to,
       case when holder.id = head.id then 'same person' else 'DIFFERENT PERSON' end as head_vs_holder
from public.households h
join public.land_sites s on s.id = h.residential_site_id
join public.residents head on head.id = h.head_resident_id
join public.land_allocations a on a.land_site_id = s.id and a.allocation_status = 'active'
join public.residents holder on holder.id = a.resident_id
order by s.site_code;

\echo ''
\echo '=== One household in detail, with its family relationships ==='
\echo '(change the household_code below to look at another)'
select r.first_name || ' ' || r.last_name as member,
       r.date_of_birth,
       case when r.id = h.head_resident_id then 'head of household' else '' end as role_in_household,
       coalesce(string_agg(distinct f.relationship_type || ' of ' || other.first_name, ', '), '') as relationships
from public.households h
join public.residents r on r.household_id = h.id
left join public.family_relationships f on f.resident_id = r.id
left join public.residents other on other.id = f.related_resident_id
where h.household_code = 'HH-0012'
group by r.id, r.first_name, r.last_name, r.date_of_birth, h.head_resident_id
order by r.date_of_birth;
