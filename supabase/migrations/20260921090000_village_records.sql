-- =====================================================================
-- TAMS — village records, and the one-time legacy import
--
-- Adds the tables the village's existing records live in:
--
--     land_sites ──< households ──< residents ──< family_relationships
--          └──< land_allocations >── residents
--
-- A household is identified by its household_code, never by surname:
-- different households legitimately share one. A household's site and a
-- site's allocation are related but separate facts — the head of the
-- household is not necessarily the person the land was allocated to.
--
-- Nothing here builds Registry Clerk or Land Officer functionality. Row
-- Level Security is on with no policies at all, so these tables are
-- reachable only by trusted server-side code until those functions are
-- built and bring their own access rules.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Land sites
-- ---------------------------------------------------------------------

create table if not exists public.land_sites (
  id              uuid primary key default gen_random_uuid(),
  site_code       text not null unique,
  site_type       text not null,
  stand_number    text,
  street_address  text not null,
  village_section text,
  village_name    text,
  site_status     text not null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint land_sites_site_code_not_blank      check (btrim(site_code) <> ''),
  constraint land_sites_street_address_not_blank check (btrim(street_address) <> ''),
  constraint land_sites_site_type_allowed        check (site_type in ('residential', 'grazing', 'burial')),
  -- Only the status the legacy records carry. Land application work will
  -- widen this when it needs to.
  constraint land_sites_site_status_allowed      check (site_status in ('allocated'))
);

comment on table public.land_sites is
  'A site in the village. Identified by site_code.';

create index if not exists land_sites_stand_number_idx on public.land_sites (stand_number);

-- ---------------------------------------------------------------------
-- 2. Residents
--
--    resident_code from the import files is deliberately absent: it is
--    an import key, resolved to this table's id while the import runs.
-- ---------------------------------------------------------------------

create table if not exists public.residents (
  id              uuid primary key default gen_random_uuid(),
  id_number       text not null unique,
  first_name      text not null,
  last_name       text not null,
  date_of_birth   date not null,
  gender          text not null,
  contact_number  text,
  email           text,
  resident_status text not null,
  household_id    uuid,                        -- foreign key added below
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint residents_id_number_not_blank  check (btrim(id_number) <> ''),
  constraint residents_first_name_not_blank check (btrim(first_name) <> ''),
  constraint residents_last_name_not_blank  check (btrim(last_name) <> ''),
  constraint residents_gender_not_blank     check (btrim(gender) <> ''),
  constraint residents_status_allowed       check (resident_status in ('active', 'inactive', 'deceased')),
  constraint residents_email_format         check (email is null or email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')
);

comment on table public.residents is
  'A person on the village register. A resident belongs to at most one household (household_id).';

create index if not exists residents_last_name_idx    on public.residents (last_name);
create index if not exists residents_household_id_idx on public.residents (household_id);

-- ---------------------------------------------------------------------
-- 3. Households
--
--    Identified by household_code. There is no household_memberships
--    table: membership is residents.household_id, so a resident can
--    only ever be in one household.
-- ---------------------------------------------------------------------

create table if not exists public.households (
  id                  uuid primary key default gen_random_uuid(),
  household_code      text not null unique,
  residential_site_id uuid not null references public.land_sites (id),
  head_resident_id    uuid references public.residents (id),
  household_status    text not null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint households_code_not_blank check (btrim(household_code) <> ''),
  constraint households_status_allowed check (household_status in ('active', 'inactive'))
);

comment on table public.households is
  'A household, identified by household_code — never by surname, which households legitimately share.';

create index if not exists households_residential_site_id_idx on public.households (residential_site_id);
create index if not exists households_head_resident_id_idx    on public.households (head_resident_id);

-- One site is the primary residential site of at most one current household.
create unique index if not exists households_one_active_per_site_idx
  on public.households (residential_site_id)
  where household_status = 'active';

-- The membership link, added now that both tables exist.
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'residents_household_id_fkey'
  ) then
    alter table public.residents
      add constraint residents_household_id_fkey
      foreign key (household_id) references public.households (id);
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 4. The head of a household must live in that household
--
--    Deferred to the end of the transaction, because an import creates
--    the household before the members are linked to it.
-- ---------------------------------------------------------------------

create or replace function public.tg_household_head_belongs_to_household()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.head_resident_id is null then return null; end if;
  -- The row may have been removed again inside the same transaction.
  if not exists (select 1 from public.households h where h.id = new.id) then return null; end if;

  if not exists (
    select 1 from public.residents r
    where r.id = new.head_resident_id and r.household_id = new.id
  ) then
    raise exception 'The head of household % must be a resident of that household.', new.household_code
      using errcode = 'TA021';
  end if;
  return null;
end;
$$;

drop trigger if exists household_head_belongs_to_household on public.households;
create constraint trigger household_head_belongs_to_household
  after insert or update of head_resident_id on public.households
  deferrable initially deferred
  for each row execute function public.tg_household_head_belongs_to_household();

-- The same rule seen from the other side: a head cannot be moved out of
-- the household they head.
create or replace function public.tg_resident_move_keeps_head_valid()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_code text;
begin
  if not exists (select 1 from public.residents r where r.id = new.id) then return null; end if;

  select h.household_code into v_code
  from public.households h
  where h.head_resident_id = new.id
    and h.id is distinct from new.household_id;

  if found then
    raise exception 'That resident is the head of household % and cannot be moved out of it.', v_code
      using errcode = 'TA021';
  end if;
  return null;
end;
$$;

drop trigger if exists resident_move_keeps_head_valid on public.residents;
create constraint trigger resident_move_keeps_head_valid
  after update of household_id on public.residents
  deferrable initially deferred
  for each row execute function public.tg_resident_move_keeps_head_valid();

-- ---------------------------------------------------------------------
-- 5. Family relationships
-- ---------------------------------------------------------------------

create table if not exists public.family_relationships (
  id                  uuid primary key default gen_random_uuid(),
  resident_id         uuid not null references public.residents (id),
  related_resident_id uuid not null references public.residents (id),
  relationship_type   text not null,
  relationship_status text not null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint family_relationships_not_self check (resident_id <> related_resident_id),
  constraint family_relationships_type_allowed check (
    relationship_type in ('parent', 'child', 'spouse', 'sibling',
                          'grandparent', 'grandchild', 'guardian', 'dependant')
  ),
  constraint family_relationships_status_allowed check (relationship_status in ('active', 'inactive')),
  constraint family_relationships_unique unique (resident_id, related_resident_id, relationship_type)
);

comment on table public.family_relationships is
  'How two residents are related, recorded from one resident''s point of view. The reverse is a row of its own.';

create index if not exists family_relationships_resident_id_idx on public.family_relationships (resident_id);
create index if not exists family_relationships_related_resident_id_idx on public.family_relationships (related_resident_id);

-- ---------------------------------------------------------------------
-- 6. Land allocations
--
--    Who a site was allocated to. Separate from the household living
--    there: the head of that household may be someone else entirely.
-- ---------------------------------------------------------------------

create table if not exists public.land_allocations (
  id                   uuid primary key default gen_random_uuid(),
  allocation_reference text not null unique,
  land_site_id         uuid not null references public.land_sites (id),
  resident_id          uuid not null references public.residents (id),
  allocation_date      date not null,
  allocation_status    text not null,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  constraint land_allocations_reference_not_blank check (btrim(allocation_reference) <> ''),
  -- Only the status the legacy records carry; historical statuses come
  -- with the allocation workflow later.
  constraint land_allocations_status_allowed check (allocation_status in ('active'))
);

comment on table public.land_allocations is
  'An allocation of a site to a resident. The allocation holder is not necessarily the head of the household on that site.';

create index if not exists land_allocations_land_site_id_idx on public.land_allocations (land_site_id);
create index if not exists land_allocations_resident_id_idx  on public.land_allocations (resident_id);

-- A site can only be under one active allocation at a time.
create unique index if not exists land_allocations_one_active_per_site_idx
  on public.land_allocations (land_site_id)
  where allocation_status = 'active';

-- ---------------------------------------------------------------------
-- 7. Keep updated_at honest
-- ---------------------------------------------------------------------

create or replace function public.tg_touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

do $$
declare
  v_table text;
begin
  foreach v_table in array array['land_sites', 'residents', 'households',
                                 'family_relationships', 'land_allocations']
  loop
    execute format('drop trigger if exists touch_updated_at on public.%I', v_table);
    execute format(
      'create trigger touch_updated_at before update on public.%I
       for each row execute function public.tg_touch_updated_at()', v_table);
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- 8. Row Level Security
--
--    On, with no policies. Nothing the browser holds can read or write
--    these tables. Registry Clerk and Land Officer access will be added
--    with those functions.
-- ---------------------------------------------------------------------

alter table public.land_sites           enable row level security;
alter table public.residents            enable row level security;
alter table public.households           enable row level security;
alter table public.family_relationships enable row level security;
alter table public.land_allocations     enable row level security;

alter table public.land_sites           force row level security;
alter table public.residents            force row level security;
alter table public.households           force row level security;
alter table public.family_relationships force row level security;
alter table public.land_allocations     force row level security;

revoke all on public.land_sites           from anon, authenticated;
revoke all on public.residents            from anon, authenticated;
revoke all on public.households           from anon, authenticated;
revoke all on public.family_relationships from anon, authenticated;
revoke all on public.land_allocations     from anon, authenticated;

grant all on public.land_sites           to service_role;
grant all on public.residents            to service_role;
grant all on public.households           to service_role;
grant all on public.family_relationships to service_role;
grant all on public.land_allocations     to service_role;

-- =====================================================================
-- 9. The one-time legacy import
--
-- The whole village dataset arrives as one JSON document, is checked in
-- full, and is then written in a single transaction. If anything at all
-- is wrong, nothing is written and every problem found is reported at
-- once — so a broken file can be fixed in one pass rather than one
-- error at a time.
--
-- The import keys (RES-0001, R-0001, HH-0001) live only in temporary
-- tables that disappear when the transaction ends. Nothing in the
-- permanent schema stores them.
--
-- Executable by service_role only: there is no page, and no signed-in
-- user, that can reach this.
-- =====================================================================

create or replace function public.is_importable_date(p_value text)
returns boolean
language plpgsql
immutable
as $$
begin
  perform p_value::date;
  return true;
exception when others then
  return false;
end;
$$;

create or replace function public.import_legacy_village_data(p_payload jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_problems text[] := '{}';
  v_counts   jsonb;
begin
  -- ---- This is a one-time import ------------------------------------
  if exists (select 1 from public.land_sites)
     or exists (select 1 from public.residents)
     or exists (select 1 from public.households)
     or exists (select 1 from public.land_allocations)
     or exists (select 1 from public.family_relationships)
  then
    raise exception 'The village records are not empty. The legacy import is a one-time process and will not run again.'
      using errcode = 'TA022';
  end if;

  -- ---- Stage the files ----------------------------------------------
  --      The ids are generated here, which is what turns each import
  --      code into a real UUID for everything that references it.
  drop table if exists _import_sites;
  create temp table _import_sites on commit drop as
    select gen_random_uuid() as id, row_number() over () as line, x.*
    from jsonb_to_recordset(coalesce(p_payload -> 'land_sites', '[]'::jsonb)) as x(
      site_code text, site_type text, stand_number text, street_address text,
      village_section text, village_name text, site_status text);

  drop table if exists _import_residents;
  create temp table _import_residents on commit drop as
    select gen_random_uuid() as id, row_number() over () as line, x.*
    from jsonb_to_recordset(coalesce(p_payload -> 'residents', '[]'::jsonb)) as x(
      resident_code text, id_number text, first_name text, last_name text,
      date_of_birth text, gender text, contact_number text, email text, resident_status text);

  drop table if exists _import_households;
  create temp table _import_households on commit drop as
    select gen_random_uuid() as id, row_number() over () as line, x.*
    from jsonb_to_recordset(coalesce(p_payload -> 'households', '[]'::jsonb)) as x(
      household_code text, primary_site_code text, head_resident_code text, household_status text);

  drop table if exists _import_memberships;
  create temp table _import_memberships on commit drop as
    select row_number() over () as line, x.*
    from jsonb_to_recordset(coalesce(p_payload -> 'household_memberships', '[]'::jsonb)) as x(
      household_code text, resident_code text);

  drop table if exists _import_relationships;
  create temp table _import_relationships on commit drop as
    select row_number() over () as line, x.*
    from jsonb_to_recordset(coalesce(p_payload -> 'family_relationships', '[]'::jsonb)) as x(
      resident_code text, related_resident_code text,
      relationship_type text, relationship_status text);

  drop table if exists _import_allocations;
  create temp table _import_allocations on commit drop as
    select row_number() over () as line, x.*
    from jsonb_to_recordset(coalesce(p_payload -> 'land_allocations', '[]'::jsonb)) as x(
      allocation_code text, site_code text, allocated_to_resident_code text,
      allocation_date text, allocation_status text);

  -- ---- Land sites ----------------------------------------------------
  v_problems := v_problems || array(
    select format('land_sites line %s: site_code, street_address, site_type and site_status are all required', line)
    from _import_sites
    where coalesce(btrim(site_code), '') = '' or coalesce(btrim(street_address), '') = ''
       or coalesce(btrim(site_type), '') = '' or coalesce(btrim(site_status), '') = '');

  v_problems := v_problems || array(
    select format('land_sites: site_code %L appears %s times', site_code, count(*))
    from _import_sites where site_code is not null group by site_code having count(*) > 1);

  v_problems := v_problems || array(
    select format('land_sites: stand_number %L appears %s times', stand_number, count(*))
    from _import_sites where coalesce(btrim(stand_number), '') <> ''
    group by stand_number having count(*) > 1);

  v_problems := v_problems || array(
    select format('land_sites line %s: site_type %L must be residential, grazing or burial', line, site_type)
    from _import_sites where site_type is not null and site_type not in ('residential', 'grazing', 'burial'));

  v_problems := v_problems || array(
    select format('land_sites line %s: site_status %L is not one this system accepts yet', line, site_status)
    from _import_sites where site_status is not null and site_status not in ('allocated'));

  -- ---- Residents ------------------------------------------------------
  v_problems := v_problems || array(
    select format('residents line %s: resident_code, id_number, first_name, last_name, date_of_birth and gender are all required', line)
    from _import_residents
    where coalesce(btrim(resident_code), '') = '' or coalesce(btrim(id_number), '') = ''
       or coalesce(btrim(first_name), '') = '' or coalesce(btrim(last_name), '') = ''
       or coalesce(btrim(date_of_birth), '') = '' or coalesce(btrim(gender), '') = '');

  v_problems := v_problems || array(
    select format('residents: resident_code %L appears %s times', resident_code, count(*))
    from _import_residents where resident_code is not null group by resident_code having count(*) > 1);

  v_problems := v_problems || array(
    select format('residents: id_number %L appears %s times', id_number, count(*))
    from _import_residents where id_number is not null group by id_number having count(*) > 1);

  v_problems := v_problems || array(
    select format('residents line %s: resident_status %L must be active, inactive or deceased', line, resident_status)
    from _import_residents where resident_status is not null
      and resident_status not in ('active', 'inactive', 'deceased'));

  v_problems := v_problems || array(
    select format('residents line %s: date_of_birth %L is not a valid date', line, date_of_birth)
    from _import_residents where coalesce(btrim(date_of_birth), '') <> ''
      and not public.is_importable_date(date_of_birth));

  v_problems := v_problems || array(
    select format('residents line %s: email %L is not a valid email address', line, email)
    from _import_residents where coalesce(btrim(email), '') <> ''
      and email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$');

  -- ---- Households ------------------------------------------------------
  v_problems := v_problems || array(
    select format('households line %s: household_code, primary_site_code and household_status are all required', line)
    from _import_households
    where coalesce(btrim(household_code), '') = '' or coalesce(btrim(primary_site_code), '') = ''
       or coalesce(btrim(household_status), '') = '');

  v_problems := v_problems || array(
    select format('households: household_code %L appears %s times', household_code, count(*))
    from _import_households where household_code is not null group by household_code having count(*) > 1);

  v_problems := v_problems || array(
    select format('households line %s: household_status %L must be active or inactive', line, household_status)
    from _import_households where household_status is not null
      and household_status not in ('active', 'inactive'));

  v_problems := v_problems || array(
    select format('households line %s (%s): no land site has site_code %L', h.line, h.household_code, h.primary_site_code)
    from _import_households h
    where h.primary_site_code is not null
      and not exists (select 1 from _import_sites s where s.site_code = h.primary_site_code));

  v_problems := v_problems || array(
    select format('households line %s (%s): no resident has resident_code %L', h.line, h.household_code, h.head_resident_code)
    from _import_households h
    where coalesce(btrim(h.head_resident_code), '') <> ''
      and not exists (select 1 from _import_residents r where r.resident_code = h.head_resident_code));

  v_problems := v_problems || array(
    select format('households: site %L is the primary site of %s current households (%s)',
                  primary_site_code, count(*), string_agg(household_code, ', ' order by household_code))
    from _import_households where household_status = 'active'
    group by primary_site_code having count(*) > 1);

  -- ---- Household membership --------------------------------------------
  v_problems := v_problems || array(
    select format('household_memberships line %s: no household has household_code %L', m.line, m.household_code)
    from _import_memberships m
    where not exists (select 1 from _import_households h where h.household_code = m.household_code));

  v_problems := v_problems || array(
    select format('household_memberships line %s: no resident has resident_code %L', m.line, m.resident_code)
    from _import_memberships m
    where not exists (select 1 from _import_residents r where r.resident_code = m.resident_code));

  v_problems := v_problems || array(
    select format('household_memberships: resident %L is listed in %s households (%s)',
                  resident_code, count(*), string_agg(household_code, ', ' order by household_code))
    from _import_memberships group by resident_code having count(*) > 1);

  -- The head of a household must be one of that household's members.
  v_problems := v_problems || array(
    select format('households line %s (%s): head %L is not a member of that household',
                  h.line, h.household_code, h.head_resident_code)
    from _import_households h
    where coalesce(btrim(h.head_resident_code), '') <> ''
      and exists (select 1 from _import_residents r where r.resident_code = h.head_resident_code)
      and not exists (
        select 1 from _import_memberships m
        where m.household_code = h.household_code and m.resident_code = h.head_resident_code));

  -- ---- Family relationships ---------------------------------------------
  v_problems := v_problems || array(
    select format('family_relationships line %s: no resident has resident_code %L', f.line, f.resident_code)
    from _import_relationships f
    where not exists (select 1 from _import_residents r where r.resident_code = f.resident_code));

  v_problems := v_problems || array(
    select format('family_relationships line %s: no resident has related_resident_code %L', f.line, f.related_resident_code)
    from _import_relationships f
    where not exists (select 1 from _import_residents r where r.resident_code = f.related_resident_code));

  v_problems := v_problems || array(
    select format('family_relationships line %s: %L cannot be related to themselves', line, resident_code)
    from _import_relationships where resident_code = related_resident_code);

  v_problems := v_problems || array(
    select format('family_relationships line %s: relationship_type %L is not one this system recognises', line, relationship_type)
    from _import_relationships where relationship_type is null
       or relationship_type not in ('parent', 'child', 'spouse', 'sibling',
                                    'grandparent', 'grandchild', 'guardian', 'dependant'));

  v_problems := v_problems || array(
    select format('family_relationships line %s: relationship_status %L must be active or inactive', line, relationship_status)
    from _import_relationships where relationship_status is null
       or relationship_status not in ('active', 'inactive'));

  v_problems := v_problems || array(
    select format('family_relationships: %L → %L as %L appears %s times',
                  resident_code, related_resident_code, relationship_type, count(*))
    from _import_relationships
    group by resident_code, related_resident_code, relationship_type having count(*) > 1);

  -- ---- Land allocations ---------------------------------------------------
  v_problems := v_problems || array(
    select format('land_allocations line %s: allocation_code, site_code, allocated_to_resident_code, allocation_date and allocation_status are all required', line)
    from _import_allocations
    where coalesce(btrim(allocation_code), '') = '' or coalesce(btrim(site_code), '') = ''
       or coalesce(btrim(allocated_to_resident_code), '') = ''
       or coalesce(btrim(allocation_date), '') = '' or coalesce(btrim(allocation_status), '') = '');

  v_problems := v_problems || array(
    select format('land_allocations: allocation_code %L appears %s times', allocation_code, count(*))
    from _import_allocations where allocation_code is not null
    group by allocation_code having count(*) > 1);

  v_problems := v_problems || array(
    select format('land_allocations line %s (%s): no land site has site_code %L', a.line, a.allocation_code, a.site_code)
    from _import_allocations a
    where not exists (select 1 from _import_sites s where s.site_code = a.site_code));

  v_problems := v_problems || array(
    select format('land_allocations line %s (%s): no resident has resident_code %L',
                  a.line, a.allocation_code, a.allocated_to_resident_code)
    from _import_allocations a
    where not exists (select 1 from _import_residents r where r.resident_code = a.allocated_to_resident_code));

  v_problems := v_problems || array(
    select format('land_allocations line %s: allocation_date %L is not a valid date', line, allocation_date)
    from _import_allocations where coalesce(btrim(allocation_date), '') <> ''
      and not public.is_importable_date(allocation_date));

  v_problems := v_problems || array(
    select format('land_allocations line %s: allocation_status %L is not one this system accepts yet', line, allocation_status)
    from _import_allocations where allocation_status is not null and allocation_status not in ('active'));

  v_problems := v_problems || array(
    select format('land_allocations: site %L has %s active allocations (%s)',
                  site_code, count(*), string_agg(allocation_code, ', ' order by allocation_code))
    from _import_allocations where allocation_status = 'active'
    group by site_code having count(*) > 1);

  -- ---- Stop here if anything is wrong -------------------------------------
  if array_length(v_problems, 1) > 0 then
    raise exception E'The import was stopped and nothing was written. % problem(s) found:\n%',
      array_length(v_problems, 1),
      array_to_string((select array_agg(p) from unnest(v_problems) with ordinality as t(p, n) where n <= 50), E'\n')
      using errcode = 'TA020';
  end if;

  -- ---- Write, in dependency order ------------------------------------------
  insert into public.land_sites (id, site_code, site_type, stand_number, street_address,
                                 village_section, village_name, site_status)
  select id, btrim(site_code), site_type, nullif(btrim(stand_number), ''), btrim(street_address),
         nullif(btrim(village_section), ''), nullif(btrim(village_name), ''), site_status
  from _import_sites;

  insert into public.residents (id, id_number, first_name, last_name, date_of_birth, gender,
                                contact_number, email, resident_status)
  select id, btrim(id_number), btrim(first_name), btrim(last_name), date_of_birth::date, btrim(gender),
         nullif(btrim(contact_number), ''), lower(nullif(btrim(email), '')), resident_status
  from _import_residents;

  insert into public.households (id, household_code, residential_site_id, head_resident_id, household_status)
  select h.id, btrim(h.household_code), s.id, r.id, h.household_status
  from _import_households h
  join _import_sites s on s.site_code = h.primary_site_code
  left join _import_residents r on r.resident_code = h.head_resident_code;

  -- Membership is a column on the resident, not a table of its own.
  update public.residents r
     set household_id = h.id
  from _import_memberships m
  join _import_residents ir on ir.resident_code = m.resident_code
  join _import_households h on h.household_code = m.household_code
  where r.id = ir.id;

  insert into public.family_relationships (resident_id, related_resident_id, relationship_type, relationship_status)
  select a.id, b.id, f.relationship_type, f.relationship_status
  from _import_relationships f
  join _import_residents a on a.resident_code = f.resident_code
  join _import_residents b on b.resident_code = f.related_resident_code;

  insert into public.land_allocations (allocation_reference, land_site_id, resident_id,
                                       allocation_date, allocation_status)
  select btrim(a.allocation_code), s.id, r.id, a.allocation_date::date, a.allocation_status
  from _import_allocations a
  join _import_sites s on s.site_code = a.site_code
  join _import_residents r on r.resident_code = a.allocated_to_resident_code;

  select jsonb_build_object(
    'land_sites',                 (select count(*) from public.land_sites),
    'residents',                  (select count(*) from public.residents),
    'households',                 (select count(*) from public.households),
    'residents_linked_to_household', (select count(*) from public.residents where household_id is not null),
    'family_relationships',       (select count(*) from public.family_relationships),
    'land_allocations',           (select count(*) from public.land_allocations)
  ) into v_counts;

  return v_counts;
end;
$$;

-- Trusted server-side only. No signed-in user can reach this.
revoke all on function public.import_legacy_village_data(jsonb) from public, anon, authenticated;
revoke all on function public.is_importable_date(text)          from public, anon, authenticated;
grant execute on function public.import_legacy_village_data(jsonb) to service_role;
