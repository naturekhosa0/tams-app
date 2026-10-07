-- Preview the operational records that cleanup_unlinked_account_data.sql
-- will remove. This script makes no permanent changes.

begin;

create temporary table tams_keep_residents (id uuid primary key) on commit drop;
insert into tams_keep_residents
select distinct resident_id
from public.user_accounts
where resident_id is not null;

create temporary table tams_keep_land_applications (id uuid primary key) on commit drop;
insert into tams_keep_land_applications
select distinct la.id
from public.land_applications la
join public.user_accounts ua
  on ua.id = la.applicant_user_account_id
 and ua.resident_id = la.applicant_resident_id
join tams_keep_residents kr on kr.id = la.applicant_resident_id;

create temporary table tams_keep_households (id uuid primary key) on commit drop;
insert into tams_keep_households
select distinct r.household_id
from public.residents r
join tams_keep_residents kr on kr.id = r.id
where r.household_id is not null
union
select distinct la.household_id
from public.land_applications la
join tams_keep_land_applications ka on ka.id = la.id;

create temporary table tams_keep_land_allocations (id uuid primary key) on commit drop;
insert into tams_keep_land_allocations
select distinct a.id
from public.land_allocations a
where (a.land_type in ('residential', 'business')
       and a.resident_id in (select id from tams_keep_residents))
   or (a.land_type in ('farming', 'burial')
       and a.household_id in (select id from tams_keep_households));

insert into tams_keep_households
select distinct a.household_id
from public.land_allocations a
join tams_keep_land_allocations ka on ka.id = a.id
where a.household_id is not null
on conflict do nothing;

create temporary table tams_keep_ptos (id uuid primary key) on commit drop;
insert into tams_keep_ptos
select distinct p.id
from public.ptos p
join tams_keep_land_allocations ka on ka.id = p.land_allocation_id
where (p.land_type in ('residential', 'business')
       and p.holder_resident_id in (select id from tams_keep_residents))
   or (p.land_type in ('farming', 'burial')
       and p.holder_household_id in (select id from tams_keep_households));

create temporary table tams_keep_land_sites (id uuid primary key) on commit drop;
insert into tams_keep_land_sites
select distinct h.residential_site_id
from public.households h
join tams_keep_households kh on kh.id = h.id
union
select distinct a.land_site_id
from public.land_allocations a
join tams_keep_land_allocations ka on ka.id = a.id;

-- Summary: current total, rows retained, and rows scheduled for deletion.
select * from (
  select 'residents' as record_type, count(*) as current_total,
         count(*) filter (where id in (select id from tams_keep_residents)) as retained,
         count(*) filter (where id not in (select id from tams_keep_residents)) as will_delete
  from public.residents
  union all
  select 'households', count(*),
         count(*) filter (where id in (select id from tams_keep_households)),
         count(*) filter (where id not in (select id from tams_keep_households))
  from public.households
  union all
  select 'land_applications', count(*),
         count(*) filter (where id in (select id from tams_keep_land_applications)),
         count(*) filter (where id not in (select id from tams_keep_land_applications))
  from public.land_applications
  union all
  select 'land_allocations', count(*),
         count(*) filter (where id in (select id from tams_keep_land_allocations)),
         count(*) filter (where id not in (select id from tams_keep_land_allocations))
  from public.land_allocations
  union all
  select 'ptos', count(*),
         count(*) filter (where id in (select id from tams_keep_ptos)),
         count(*) filter (where id not in (select id from tams_keep_ptos))
  from public.ptos
  union all
  select 'land_sites', count(*),
         count(*) filter (where id in (select id from tams_keep_land_sites)),
         count(*) filter (where id not in (select id from tams_keep_land_sites))
  from public.land_sites
) summary
order by record_type;

-- The resident records scheduled for deletion.
select r.id, r.id_number, r.first_name, r.last_name, h.household_code
from public.residents r
left join public.households h on h.id = r.household_id
where r.id not in (select id from tams_keep_residents)
order by r.last_name, r.first_name, r.id_number;

-- The household records scheduled for deletion.
select h.id, h.household_code, s.site_code
from public.households h
join public.land_sites s on s.id = h.residential_site_id
where h.id not in (select id from tams_keep_households)
order by h.household_code;

-- The land records scheduled for deletion.
select 'site' as record_type, s.id, s.site_code as reference
from public.land_sites s
where s.id not in (select id from tams_keep_land_sites)
union all
select 'application', a.id, a.application_reference
from public.land_applications a
where a.id not in (select id from tams_keep_land_applications)
union all
select 'allocation', a.id, a.allocation_reference
from public.land_allocations a
where a.id not in (select id from tams_keep_land_allocations)
union all
select 'pto', p.id, p.pto_number
from public.ptos p
where p.id not in (select id from tams_keep_ptos)
order by record_type, reference;

rollback;
