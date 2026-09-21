-- =====================================================================
-- TAMS — the land model
--
-- Four land types, and only four:
--
--   residential  one per resident, perpetual permission
--   farming      one per household, five year term
--   business     one per resident, two year term
--   burial       to a household, perpetual, another only once full
--
-- Grazing is not among them. There is communal grazing in the village,
-- but it is not allocated, needs no permission to occupy, and nobody
-- applies for it, so it has no place in this system.
--
-- The Traditional Authority decides who gets land. That happens off the
-- system, in the way it always has. TAMS records the administrative
-- outcome: there is no digital approval by the Chief, the Headman or
-- the Headwoman, and no Council Administrator countersignature.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Land types
--
--    Grazing is removed if nothing uses it. If any grazing site exists
--    it is kept exactly as it is — historical records are not deleted —
--    but it is marked unavailable and excluded from every workflow
--    below, which all work from the four allocatable types.
-- ---------------------------------------------------------------------

create or replace function public.allocatable_land_types()
returns text[]
language sql
immutable
as $$
  select array['residential', 'farming', 'business', 'burial'];
$$;

do $$
declare
  v_grazing_sites int;
begin
  select count(*) into v_grazing_sites from public.land_sites where site_type = 'grazing';

  alter table public.land_sites drop constraint if exists land_sites_site_type_allowed;

  if v_grazing_sites = 0 then
    alter table public.land_sites
      add constraint land_sites_site_type_allowed
      check (site_type in ('residential', 'farming', 'business', 'burial'));
    raise notice 'No grazing sites existed; grazing removed as a land type.';
  else
    -- Kept only so the existing rows remain valid. Nothing can create a
    -- new one: registration and every workflow use the four types above.
    alter table public.land_sites
      add constraint land_sites_site_type_allowed
      check (site_type in ('residential', 'farming', 'business', 'burial', 'grazing'));
    raise notice
      '% grazing site(s) exist and were preserved as legacy records, marked unavailable and excluded from allocation.',
      v_grazing_sites;
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 2. What state a site is in
-- ---------------------------------------------------------------------

alter table public.land_sites drop constraint if exists land_sites_site_status_allowed;
alter table public.land_sites
  add constraint land_sites_site_status_allowed
  check (site_status in ('available', 'allocated', 'unavailable'));

-- Burial plots fill up. That is a property of the plot, not of whether
-- it is allocated, so it lives in its own column.
alter table public.land_sites
  add column if not exists burial_status text;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'land_sites_burial_status_shape') then
    alter table public.land_sites
      add constraint land_sites_burial_status_shape check (
        (site_type = 'burial' and burial_status in ('usable', 'full', 'closed'))
        or (site_type <> 'burial' and burial_status is null)
      );
  end if;
end;
$$;

comment on column public.land_sites.burial_status is
  'Only for burial plots: whether the plot can still take burials. A full or closed plot stays with its household for ever.';

-- Existing burial plots start usable; any legacy grazing is shut out.
update public.land_sites set burial_status = 'usable'
 where site_type = 'burial' and burial_status is null;
update public.land_sites set site_status = 'unavailable'
 where site_type = 'grazing';

create index if not exists land_sites_site_type_status_idx on public.land_sites (site_type, site_status);

-- ---------------------------------------------------------------------
-- 3. Land applications
-- ---------------------------------------------------------------------

create table if not exists public.land_applications (
  id                       uuid primary key default gen_random_uuid(),
  application_reference    text not null unique,
  applicant_resident_id    uuid not null references public.residents (id),
  applicant_user_account_id uuid references public.user_accounts (id),
  household_id             uuid not null references public.households (id),
  land_type                text not null,
  application_status       text not null default 'pending',

  reason_for_application   text not null,
  intended_use             text,
  -- Residential
  lives_with_household     boolean,
  -- Farming
  farming_type             text,
  farming_activity         text,
  -- Business
  business_name            text,
  business_type            text,
  business_description     text,

  submitted_at             timestamptz not null default now(),
  reviewed_at              timestamptz,
  reviewed_by_staff_id     uuid references public.staff (id),
  decline_reason           text,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),

  constraint land_applications_type_allowed
    check (land_type in ('residential', 'farming', 'business', 'burial')),
  constraint land_applications_status_allowed
    check (application_status in ('pending', 'approved', 'declined', 'allocated')),
  constraint land_applications_reason_present
    check (btrim(reason_for_application) <> ''),
  constraint land_applications_farming_type_allowed
    check (farming_type is null or farming_type in ('crop', 'livestock', 'mixed', 'other')),
  constraint land_applications_business_type_allowed
    check (business_type is null or business_type in ('shop', 'restaurant', 'salon', 'workshop', 'office', 'other')),
  constraint land_applications_review_shape check (
    (application_status = 'pending' and reviewed_at is null and reviewed_by_staff_id is null and decline_reason is null)
    or (application_status = 'declined' and reviewed_at is not null and reviewed_by_staff_id is not null
        and btrim(coalesce(decline_reason, '')) <> '')
    or (application_status in ('approved', 'allocated') and reviewed_at is not null
        and reviewed_by_staff_id is not null and decline_reason is null)
  )
);

comment on table public.land_applications is
  'One application for land. The applicant never chooses a site: the Land Officer allocates one after approval.';

create index if not exists land_applications_applicant_idx on public.land_applications (applicant_resident_id);
create index if not exists land_applications_household_idx on public.land_applications (household_id);
create index if not exists land_applications_status_idx on public.land_applications (application_status, land_type);

-- An applicant may not have two residential or business applications in
-- flight, and a household may not have two farming or burial ones.
create unique index if not exists land_applications_one_open_per_resident_idx
  on public.land_applications (applicant_resident_id, land_type)
  where application_status in ('pending', 'approved') and land_type in ('residential', 'business');

create unique index if not exists land_applications_one_open_per_household_idx
  on public.land_applications (household_id, land_type)
  where application_status in ('pending', 'approved') and land_type in ('farming', 'burial');

-- ---------------------------------------------------------------------
-- 4. Allocations gain what the four types need
--
--    The imported allocations are untouched: they keep their references,
--    their sites, their residents and their dates.
-- ---------------------------------------------------------------------

alter table public.land_allocations
  add column if not exists household_id            uuid references public.households (id),
  add column if not exists land_application_id     uuid references public.land_applications (id),
  add column if not exists land_type               text,
  add column if not exists ended_at                date,
  add column if not exists end_reason              text,
  add column if not exists ended_by_staff_id       uuid references public.staff (id),
  add column if not exists superseded_by_allocation_id uuid references public.land_allocations (id),
  add column if not exists succeeds_allocation_id  uuid references public.land_allocations (id);

-- Farming and burial land is held by a household, so there is not
-- always a resident to name.
alter table public.land_allocations alter column resident_id drop not null;

-- The imported allocations are all residential; fill in what the new
-- columns need from the records that already exist.
update public.land_allocations a
   set land_type = coalesce(a.land_type, s.site_type)
  from public.land_sites s
 where s.id = a.land_site_id and a.land_type is null;

update public.land_allocations a
   set household_id = r.household_id
  from public.residents r
 where r.id = a.resident_id and a.household_id is null;

alter table public.land_allocations alter column land_type set not null;

alter table public.land_allocations drop constraint if exists land_allocations_status_allowed;
alter table public.land_allocations
  add constraint land_allocations_status_allowed
  check (allocation_status in ('active', 'succession_pending', 'superseded', 'released'));

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'land_allocations_type_allowed') then
    alter table public.land_allocations
      add constraint land_allocations_type_allowed
      check (land_type in ('residential', 'farming', 'business', 'burial'));
  end if;

  -- Who holds it: residential and business name a resident, farming and
  -- burial name a household. Residential keeps the household too, which
  -- is what makes succession possible later.
  if not exists (select 1 from pg_constraint where conname = 'land_allocations_holder_shape') then
    alter table public.land_allocations
      add constraint land_allocations_holder_shape check (
        (land_type in ('residential', 'business') and resident_id is not null)
        or (land_type in ('farming', 'burial') and household_id is not null)
      );
  end if;
end;
$$;

create index if not exists land_allocations_household_idx on public.land_allocations (household_id);
create index if not exists land_allocations_type_status_idx on public.land_allocations (land_type, allocation_status);

-- Anything that writes an allocation without saying which kind of land
-- it is, or which household, can work it out from the site and the
-- resident. This is what keeps the legacy importer — written before
-- these columns existed — working exactly as it did.
create or replace function public.tg_land_allocation_defaults()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.land_type is null then
    select s.site_type into new.land_type from public.land_sites s where s.id = new.land_site_id;
  end if;
  if new.household_id is null and new.resident_id is not null then
    select r.household_id into new.household_id from public.residents r where r.id = new.resident_id;
  end if;
  return new;
end;
$$;

drop trigger if exists land_allocation_defaults on public.land_allocations;
create trigger land_allocation_defaults
  before insert on public.land_allocations
  for each row execute function public.tg_land_allocation_defaults();

-- A burial plot is usable unless somebody says otherwise.
create or replace function public.tg_land_site_defaults()
returns trigger
language plpgsql
as $$
begin
  if new.site_type = 'burial' and new.burial_status is null then
    new.burial_status := 'usable';
  elsif new.site_type <> 'burial' then
    new.burial_status := null;
  end if;
  return new;
end;
$$;

drop trigger if exists land_site_defaults on public.land_sites;
create trigger land_site_defaults
  before insert or update of site_type on public.land_sites
  for each row execute function public.tg_land_site_defaults();

-- ---- The hard limits, in the database itself -------------------------

-- A site carries one allocation that is not finished. succession_pending
-- counts: the site is not free while a succession is undecided.
drop index if exists public.land_allocations_one_active_per_site_idx;
create unique index if not exists land_allocations_one_open_per_site_idx
  on public.land_allocations (land_site_id)
  where allocation_status in ('active', 'succession_pending');

-- One residential stand and one business site per resident.
create unique index if not exists land_allocations_one_residential_per_resident_idx
  on public.land_allocations (resident_id)
  where land_type = 'residential' and allocation_status in ('active', 'succession_pending');

create unique index if not exists land_allocations_one_business_per_resident_idx
  on public.land_allocations (resident_id)
  where land_type = 'business' and allocation_status = 'active';

-- One farming allocation per household. Burial is deliberately absent:
-- a household may hold several plots over time, governed by whether any
-- is still usable.
create unique index if not exists land_allocations_one_farming_per_household_idx
  on public.land_allocations (household_id)
  where land_type = 'farming' and allocation_status = 'active';

-- ---------------------------------------------------------------------
-- 5. Permission to occupy
-- ---------------------------------------------------------------------

create table if not exists public.ptos (
  id                   uuid primary key default gen_random_uuid(),
  pto_number           text not null unique,
  land_allocation_id   uuid not null references public.land_allocations (id),
  land_type            text not null,
  holder_resident_id   uuid references public.residents (id),
  holder_household_id  uuid references public.households (id),
  issue_date           date not null default current_date,
  -- Null means perpetual. There is no fake far-future date anywhere.
  expiry_date          date,
  pto_status           text not null default 'active',
  superseded_by_pto_id uuid references public.ptos (id),
  renewed_from_pto_id  uuid references public.ptos (id),
  revoked_at           timestamptz,
  revocation_reason    text,
  revoked_by_staff_id  uuid references public.staff (id),
  issued_by_staff_id   uuid references public.staff (id),
  verification_token   text not null unique,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),

  constraint ptos_type_allowed check (land_type in ('residential', 'farming', 'business', 'burial')),
  constraint ptos_status_allowed
    check (pto_status in ('active', 'expired', 'renewed', 'revoked', 'superseded')),
  -- Residential and burial are perpetual; farming and business are not.
  constraint ptos_term_shape check (
    (land_type in ('residential', 'burial') and expiry_date is null)
    or (land_type in ('farming', 'business') and expiry_date is not null and expiry_date > issue_date)
  ),
  constraint ptos_holder_shape check (
    (land_type in ('residential', 'business') and holder_resident_id is not null)
    or (land_type in ('farming', 'burial') and holder_household_id is not null)
  ),
  constraint ptos_revocation_shape check (
    pto_status <> 'revoked'
    or (revoked_at is not null and btrim(coalesce(revocation_reason, '')) <> '' and revoked_by_staff_id is not null)
  )
);

comment on table public.ptos is
  'A permission to occupy. Never edited into another: renewal and succession create a new one and leave the old on record.';

create index if not exists ptos_allocation_idx on public.ptos (land_allocation_id);
create index if not exists ptos_holder_resident_idx on public.ptos (holder_resident_id);
create index if not exists ptos_holder_household_idx on public.ptos (holder_household_id);
create index if not exists ptos_status_idx on public.ptos (pto_status);

-- One live permission per allocation.
create unique index if not exists ptos_one_active_per_allocation_idx
  on public.ptos (land_allocation_id)
  where pto_status = 'active';

-- ---------------------------------------------------------------------
-- 6. Renewal requests
-- ---------------------------------------------------------------------

create table if not exists public.pto_renewal_requests (
  id                    uuid primary key default gen_random_uuid(),
  pto_id                uuid not null references public.ptos (id),
  requested_by_resident_id uuid not null references public.residents (id),
  request_status        text not null default 'pending',
  reason                text,
  requested_at          timestamptz not null default now(),
  reviewed_at           timestamptz,
  reviewed_by_staff_id  uuid references public.staff (id),
  decline_reason        text,
  resulting_pto_id      uuid references public.ptos (id),
  created_at            timestamptz not null default now(),

  constraint pto_renewal_requests_status_allowed
    check (request_status in ('pending', 'approved', 'declined')),
  constraint pto_renewal_requests_review_shape check (
    (request_status = 'pending' and reviewed_at is null and decline_reason is null and resulting_pto_id is null)
    or (request_status = 'approved' and reviewed_at is not null and reviewed_by_staff_id is not null
        and resulting_pto_id is not null and decline_reason is null)
    or (request_status = 'declined' and reviewed_at is not null and reviewed_by_staff_id is not null
        and btrim(coalesce(decline_reason, '')) <> '')
  )
);

create index if not exists pto_renewal_requests_pto_idx on public.pto_renewal_requests (pto_id);

-- One open request per permission.
create unique index if not exists pto_renewal_requests_one_open_idx
  on public.pto_renewal_requests (pto_id)
  where request_status = 'pending';

-- ---------------------------------------------------------------------
-- 7. Row Level Security
--
--    Reads are policy-driven; every write goes through the functions in
--    the next migration, which establish the caller for themselves.
-- ---------------------------------------------------------------------

alter table public.land_applications     enable row level security;
alter table public.ptos                  enable row level security;
alter table public.pto_renewal_requests  enable row level security;
alter table public.land_applications     force row level security;
alter table public.ptos                  force row level security;
alter table public.pto_renewal_requests  force row level security;

revoke all on public.land_applications    from anon, authenticated;
revoke all on public.ptos                 from anon, authenticated;
revoke all on public.pto_renewal_requests from anon, authenticated;
grant select on public.land_applications    to authenticated;
grant select on public.ptos                 to authenticated;
grant select on public.pto_renewal_requests to authenticated;
grant all on public.land_applications    to service_role;
grant all on public.ptos                 to service_role;
grant all on public.pto_renewal_requests to service_role;
