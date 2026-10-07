-- One-time operational-data cleanup.
--
-- Retains:
--   * residents referenced by user_accounts.resident_id;
--   * their current households and households used by their account land applications;
--   * land applications submitted by the matching resident account;
--   * land, PTO and renewal records held by those residents or households.
--
-- This intentionally remains outside supabase/migrations so a normal db:push
-- can never repeat this destructive maintenance operation.

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

-- An approved request must point at the same resident currently linked to
-- its account. Abort instead of guessing if historical data contradicts that.
do $$
begin
  if exists (
    select 1
    from public.resident_account_requests q
    join public.user_accounts ua on ua.id = q.user_account_id
    where q.matched_resident_id is not null
      and q.matched_resident_id is distinct from ua.resident_id
  ) then
    raise exception 'Cleanup stopped: an account request points at a resident different from its current account link.';
  end if;
end;
$$;

create temporary table tams_cleanup_report (
  record_type text primary key,
  deleted_rows bigint not null
) on commit drop;

-- Remove dependent rows first.
with deleted as (
  delete from public.resident_communication_recipients r
  where r.resident_id not in (select id from tams_keep_residents)
     or not exists (
       select 1 from public.user_accounts ua
       where ua.id = r.user_account_id and ua.resident_id = r.resident_id
     )
  returning 1
)
insert into tams_cleanup_report values ('resident_communication_recipients', (select count(*) from deleted));

with deleted as (
  delete from public.resident_communications c
  where not exists (
    select 1 from public.resident_communication_recipients r
    where r.communication_id = c.id
  )
  returning 1
)
insert into tams_cleanup_report values ('resident_communications', (select count(*) from deleted));

with deleted as (
  delete from public.pto_renewal_requests r
  where r.pto_id not in (select id from tams_keep_ptos)
     or r.requested_by_resident_id not in (select id from tams_keep_residents)
     or (r.resulting_pto_id is not null
         and r.resulting_pto_id not in (select id from tams_keep_ptos))
  returning 1
)
insert into tams_cleanup_report values ('pto_renewal_requests', (select count(*) from deleted));

-- Break history links from retained records to records being removed.
update public.ptos
set superseded_by_pto_id = case
      when superseded_by_pto_id in (select id from tams_keep_ptos) then superseded_by_pto_id
      else null end,
    renewed_from_pto_id = case
      when renewed_from_pto_id in (select id from tams_keep_ptos) then renewed_from_pto_id
      else null end,
    holder_resident_id = case
      when holder_resident_id in (select id from tams_keep_residents) then holder_resident_id
      else null end,
    holder_household_id = case
      when holder_household_id in (select id from tams_keep_households) then holder_household_id
      else null end
where id in (select id from tams_keep_ptos);

with deleted as (
  delete from public.ptos p
  where p.id not in (select id from tams_keep_ptos)
  returning 1
)
insert into tams_cleanup_report values ('ptos', (select count(*) from deleted));

update public.land_allocations
set superseded_by_allocation_id = case
      when superseded_by_allocation_id in (select id from tams_keep_land_allocations)
        then superseded_by_allocation_id else null end,
    succeeds_allocation_id = case
      when succeeds_allocation_id in (select id from tams_keep_land_allocations)
        then succeeds_allocation_id else null end,
    land_application_id = case
      when land_application_id in (select id from tams_keep_land_applications)
        then land_application_id else null end,
    resident_id = case
      when resident_id in (select id from tams_keep_residents) then resident_id
      else null end,
    household_id = case
      when household_id in (select id from tams_keep_households) then household_id
      else null end
where id in (select id from tams_keep_land_allocations);

with deleted as (
  delete from public.land_allocations a
  where a.id not in (select id from tams_keep_land_allocations)
  returning 1
)
insert into tams_cleanup_report values ('land_allocations', (select count(*) from deleted));

with deleted as (
  delete from public.land_applications a
  where a.id not in (select id from tams_keep_land_applications)
  returning 1
)
insert into tams_cleanup_report values ('land_applications', (select count(*) from deleted));

with deleted as (
  delete from public.family_relationships f
  where f.resident_id not in (select id from tams_keep_residents)
     or f.related_resident_id not in (select id from tams_keep_residents)
  returning 1
)
insert into tams_cleanup_report values ('family_relationships', (select count(*) from deleted));

-- A retained household may have named an unlinked resident as its head.
update public.households
set head_resident_id = null
where head_resident_id is not null
  and head_resident_id not in (select id from tams_keep_residents);

with deleted as (
  delete from public.residents r
  where r.id not in (select id from tams_keep_residents)
  returning 1
)
insert into tams_cleanup_report values ('residents', (select count(*) from deleted));

with deleted as (
  delete from public.households h
  where h.id not in (select id from tams_keep_households)
  returning 1
)
insert into tams_cleanup_report values ('households', (select count(*) from deleted));

with deleted as (
  delete from public.land_sites s
  where s.id not in (select id from tams_keep_land_sites)
  returning 1
)
insert into tams_cleanup_report values ('land_sites', (select count(*) from deleted));

-- Prove the account links and retained dependency graph are intact before commit.
do $$
begin
  if exists (
    select 1 from public.user_accounts ua
    where ua.resident_id is not null
      and not exists (select 1 from public.residents r where r.id = ua.resident_id)
  ) then
    raise exception 'Cleanup verification failed: an account lost its resident.';
  end if;

  if exists (
    select 1 from public.residents r
    where not exists (select 1 from public.user_accounts ua where ua.resident_id = r.id)
  ) then
    raise exception 'Cleanup verification failed: an unlinked resident remains.';
  end if;

  if exists (
    select 1 from public.households h
    where not exists (select 1 from public.residents r where r.household_id = h.id)
      and not exists (select 1 from public.land_applications a where a.household_id = h.id)
      and not exists (select 1 from public.land_allocations a where a.household_id = h.id)
  ) then
    raise exception 'Cleanup verification failed: an unlinked household remains.';
  end if;
end;
$$;

select record_type, deleted_rows
from tams_cleanup_report
order by record_type;

commit;
