-- =====================================================================
-- TAMS — Registry Clerk functions
--
-- Reading and maintaining the village register: residents, households,
-- who lives where, who heads a household, and how people are related.
--
-- No new table. Household membership stays residents.household_id, a
-- household is still identified by household_code, and family lineage
-- still comes from family_relationships alone.
--
-- Reads go through Row Level Security. Writes go through the functions
-- below and nowhere else: there is no insert, update or delete policy
-- on any village table, so a Registry Clerk cannot write a row the
-- rules here did not agree to.
--
-- Every function re-establishes the caller from auth.uid(). Nothing the
-- browser sends stands in for authorisation.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Who is a Registry Clerk
-- ---------------------------------------------------------------------

create or replace function public.is_active_registry_clerk()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.user_accounts ua
    join public.staff s on s.id = ua.staff_id
    join public.roles r on r.id = s.role_id
    where ua.auth_user_id = auth.uid()
      and ua.account_type = 'staff'
      and ua.account_status = 'active'
      and r.role_name = 'Registry Clerk'
  );
$$;

-- Raises unless the caller is one. Used by every function below, so the
-- rule is written once.
create or replace function public.require_registry_clerk()
returns void
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_active_registry_clerk() then
    raise exception 'Only an active Registry Clerk may use the village register.'
      using errcode = '42501';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 2. Reading the register
--
--    A Registry Clerk may read the whole register. Land sites and land
--    allocations are readable too, because a household is meaningless
--    without its address and the clerk needs to see who holds the
--    allocation — but there is no write policy on either, so they
--    remain the Land Officer's to change.
-- ---------------------------------------------------------------------

drop policy if exists residents_readable_by_registry_clerk on public.residents;
create policy residents_readable_by_registry_clerk
  on public.residents for select to authenticated
  using (public.is_active_registry_clerk());

drop policy if exists households_readable_by_registry_clerk on public.households;
create policy households_readable_by_registry_clerk
  on public.households for select to authenticated
  using (public.is_active_registry_clerk());

drop policy if exists family_relationships_readable_by_registry_clerk on public.family_relationships;
create policy family_relationships_readable_by_registry_clerk
  on public.family_relationships for select to authenticated
  using (public.is_active_registry_clerk());

drop policy if exists land_sites_readable_by_registry_clerk on public.land_sites;
create policy land_sites_readable_by_registry_clerk
  on public.land_sites for select to authenticated
  using (public.is_active_registry_clerk());

drop policy if exists land_allocations_readable_by_registry_clerk on public.land_allocations;
create policy land_allocations_readable_by_registry_clerk
  on public.land_allocations for select to authenticated
  using (public.is_active_registry_clerk());

grant select on public.residents            to authenticated;
grant select on public.households           to authenticated;
grant select on public.family_relationships to authenticated;
grant select on public.land_sites           to authenticated;
grant select on public.land_allocations     to authenticated;

-- ---------------------------------------------------------------------
-- 3. Searching and viewing
-- ---------------------------------------------------------------------

-- Anything typed into a search box is text to match, never a pattern.
create or replace function public.like_pattern(p_search text)
returns text
language sql
immutable
as $$
  select '%' || replace(replace(replace(coalesce(btrim(p_search), ''), '\', '\\'), '%', '\%'), '_', '\_') || '%';
$$;

create or replace function public.registry_search_residents(p_search text default null)
returns table (
  resident_id     uuid,
  id_number       text,
  first_name      text,
  last_name       text,
  full_name       text,
  date_of_birth   date,
  gender          text,
  contact_number  text,
  email           text,
  resident_status text,
  household_code  text,
  site_code       text,
  street_address  text,
  is_household_head boolean
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_pattern text := public.like_pattern(p_search);
  v_empty   boolean := coalesce(btrim(p_search), '') = '';
begin
  perform public.require_registry_clerk();

  return query
    select r.id, r.id_number, r.first_name, r.last_name,
           r.first_name || ' ' || r.last_name,
           r.date_of_birth, r.gender, r.contact_number, r.email, r.resident_status,
           h.household_code, s.site_code, s.street_address,
           (h.head_resident_id = r.id)
    from public.residents r
    left join public.households h on h.id = r.household_id
    left join public.land_sites s on s.id = h.residential_site_id
    where v_empty
       or r.id_number ilike v_pattern
       or r.first_name ilike v_pattern
       or r.last_name ilike v_pattern
       or (r.first_name || ' ' || r.last_name) ilike v_pattern
       or coalesce(r.contact_number, '') ilike v_pattern
       or coalesce(r.email, '') ilike v_pattern
       or coalesce(h.household_code, '') ilike v_pattern
       or coalesce(s.site_code, '') ilike v_pattern
       or coalesce(s.street_address, '') ilike v_pattern
    order by r.last_name, r.first_name;
end;
$$;

create or replace function public.registry_resident_record(p_resident_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_record jsonb;
begin
  perform public.require_registry_clerk();

  select jsonb_build_object(
    'resident_id',     r.id,
    'id_number',       r.id_number,
    'first_name',      r.first_name,
    'last_name',       r.last_name,
    'full_name',       r.first_name || ' ' || r.last_name,
    'date_of_birth',   r.date_of_birth,
    'gender',          r.gender,
    'contact_number',  r.contact_number,
    'email',           r.email,
    'resident_status', r.resident_status,
    'household_id',    h.id,
    'household_code',  h.household_code,
    'household_status', h.household_status,
    'is_household_head', coalesce(h.head_resident_id = r.id, false),
    'household_head',  (select head.first_name || ' ' || head.last_name
                          from public.residents head where head.id = h.head_resident_id),
    'site_code',       s.site_code,
    'stand_number',    s.stand_number,
    'street_address',  s.street_address,
    'village_section', s.village_section,
    'village_name',    s.village_name,
    'relationship_count', (select count(*) from public.family_relationships f
                            where f.resident_id = r.id and f.relationship_status = 'active')
  )
  into v_record
  from public.residents r
  left join public.households h on h.id = r.household_id
  left join public.land_sites s on s.id = h.residential_site_id
  where r.id = p_resident_id;

  if v_record is null then
    raise exception 'That resident could not be found.' using errcode = 'TA031';
  end if;
  return v_record;
end;
$$;

-- Family lineage, straight from family_relationships. There is no tree
-- table: the relationships are the tree.
create or replace function public.registry_family_lineage(p_resident_id uuid)
returns table (
  relationship_id     uuid,
  relationship_type   text,
  relationship_status text,
  related_resident_id uuid,
  related_full_name   text,
  related_id_number   text,
  related_status      text,
  related_household_code text
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.require_registry_clerk();

  if not exists (select 1 from public.residents where id = p_resident_id) then
    raise exception 'That resident could not be found.' using errcode = 'TA031';
  end if;

  return query
    select f.id, f.relationship_type, f.relationship_status,
           other.id, other.first_name || ' ' || other.last_name,
           other.id_number, other.resident_status, h.household_code
    from public.family_relationships f
    join public.residents other on other.id = f.related_resident_id
    left join public.households h on h.id = other.household_id
    where f.resident_id = p_resident_id
    -- A row says "this resident is the <type> of the other person", so
    -- the reading order is the inverse: the people they are the child
    -- of are their parents, and come first.
    order by
      case f.relationship_type
        when 'child' then 1 when 'parent' then 2 when 'spouse' then 3
        when 'sibling' then 4 when 'grandchild' then 5 when 'grandparent' then 6
        when 'dependant' then 7 else 8 end,
      other.last_name, other.first_name;
end;
$$;

create or replace function public.registry_search_households(p_search text default null)
returns table (
  household_id     uuid,
  household_code   text,
  household_status text,
  site_code        text,
  stand_number     text,
  street_address   text,
  village_section  text,
  village_name     text,
  head_full_name   text,
  member_count     bigint
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_pattern text := public.like_pattern(p_search);
  v_empty   boolean := coalesce(btrim(p_search), '') = '';
begin
  perform public.require_registry_clerk();

  return query
    select h.id, h.household_code, h.household_status,
           s.site_code, s.stand_number, s.street_address, s.village_section, s.village_name,
           (select head.first_name || ' ' || head.last_name
              from public.residents head where head.id = h.head_resident_id),
           (select count(*) from public.residents m where m.household_id = h.id)
    from public.households h
    join public.land_sites s on s.id = h.residential_site_id
    where v_empty
       or h.household_code ilike v_pattern
       or s.site_code ilike v_pattern
       or coalesce(s.stand_number, '') ilike v_pattern
       or s.street_address ilike v_pattern
       or coalesce(s.village_section, '') ilike v_pattern
       or exists (select 1 from public.residents m
                   where m.household_id = h.id
                     and ((m.first_name || ' ' || m.last_name) ilike v_pattern
                          or m.id_number ilike v_pattern))
    order by h.household_code;
end;
$$;

-- A household in full, including who currently holds the land
-- allocation for its site — which is often not the head of household.
create or replace function public.registry_household_record(p_household_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_record jsonb;
begin
  perform public.require_registry_clerk();

  select jsonb_build_object(
    'household_id',     h.id,
    'household_code',   h.household_code,
    'household_status', h.household_status,
    'site_id',          s.id,
    'site_code',        s.site_code,
    'site_type',        s.site_type,
    'stand_number',     s.stand_number,
    'street_address',   s.street_address,
    'village_section',  s.village_section,
    'village_name',     s.village_name,
    'head_resident_id', h.head_resident_id,
    'head_full_name',   (select head.first_name || ' ' || head.last_name
                           from public.residents head where head.id = h.head_resident_id),
    'members', coalesce((
      select jsonb_agg(jsonb_build_object(
               'resident_id',   m.id,
               'full_name',     m.first_name || ' ' || m.last_name,
               'id_number',     m.id_number,
               'date_of_birth', m.date_of_birth,
               'gender',        m.gender,
               'resident_status', m.resident_status,
               'is_head',       (h.head_resident_id = m.id))
             order by (h.head_resident_id = m.id) desc, m.date_of_birth)
      from public.residents m where m.household_id = h.id), '[]'::jsonb),
    -- Context only. Land allocations belong to the Land Officer.
    'allocation', (
      select jsonb_build_object(
               'allocation_reference', a.allocation_reference,
               'allocation_date',      a.allocation_date,
               'allocation_status',    a.allocation_status,
               'holder_full_name',     holder.first_name || ' ' || holder.last_name,
               'holder_is_household_head', (a.resident_id = h.head_resident_id))
      from public.land_allocations a
      join public.residents holder on holder.id = a.resident_id
      where a.land_site_id = s.id and a.allocation_status = 'active'
      limit 1)
  )
  into v_record
  from public.households h
  join public.land_sites s on s.id = h.residential_site_id
  where h.id = p_household_id;

  if v_record is null then
    raise exception 'That household could not be found.' using errcode = 'TA032';
  end if;
  return v_record;
end;
$$;

create or replace function public.registry_dashboard_stats()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.require_registry_clerk();

  return jsonb_build_object(
    'residents',              (select count(*) from public.residents),
    'active_residents',       (select count(*) from public.residents where resident_status = 'active'),
    'households',             (select count(*) from public.households),
    'residents_without_household', (select count(*) from public.residents where household_id is null),
    'households_without_head',(select count(*) from public.households where head_resident_id is null),
    'family_relationships',   (select count(*) from public.family_relationships where relationship_status = 'active')
  );
end;
$$;

-- Residential sites a new household could be placed on: residential,
-- and not already the site of a current household.
create or replace function public.registry_available_residential_sites()
returns table (site_id uuid, site_code text, stand_number text, street_address text,
               village_section text, village_name text)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.require_registry_clerk();

  return query
    select s.id, s.site_code, s.stand_number, s.street_address, s.village_section, s.village_name
    from public.land_sites s
    where s.site_type = 'residential'
      and not exists (select 1 from public.households h
                       where h.residential_site_id = s.id and h.household_status = 'active')
    order by s.site_code;
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Creating and updating a resident record
--
--    This is the village's record of a person. It is not a sign-in
--    account: no Supabase Auth user and no user_accounts row is created
--    here, and resident accounts are not built yet.
-- ---------------------------------------------------------------------

create or replace function public.registry_create_resident(
  p_id_number       text,
  p_first_name      text,
  p_last_name       text,
  p_date_of_birth   text,
  p_gender          text,
  p_resident_status text default 'active',
  p_contact_number  text default null,
  p_email           text default null,
  p_household_id    uuid default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_id_number text := btrim(coalesce(p_id_number, ''));
  v_resident  public.residents;
begin
  perform public.require_registry_clerk();

  if v_id_number = '' or btrim(coalesce(p_first_name, '')) = ''
     or btrim(coalesce(p_last_name, '')) = '' or btrim(coalesce(p_gender, '')) = ''
     or btrim(coalesce(p_date_of_birth, '')) = '' then
    raise exception 'Identity number, first name, surname, date of birth and gender are all required.'
      using errcode = 'TA034';
  end if;

  if not public.is_importable_date(p_date_of_birth) then
    raise exception 'That date of birth is not a valid date.' using errcode = 'TA034';
  end if;

  if p_resident_status not in ('active', 'inactive', 'deceased') then
    raise exception 'Resident status must be active, inactive or deceased.' using errcode = 'TA034';
  end if;

  if exists (select 1 from public.residents r where lower(r.id_number) = lower(v_id_number)) then
    raise exception 'A resident with identity number % is already on the register.', v_id_number
      using errcode = 'TA033';
  end if;

  if p_household_id is not null
     and not exists (select 1 from public.households h where h.id = p_household_id) then
    raise exception 'That household could not be found.' using errcode = 'TA032';
  end if;

  insert into public.residents (id_number, first_name, last_name, date_of_birth, gender,
                                contact_number, email, resident_status, household_id)
  values (v_id_number, btrim(p_first_name), btrim(p_last_name), p_date_of_birth::date,
          btrim(p_gender), nullif(btrim(coalesce(p_contact_number, '')), ''),
          lower(nullif(btrim(coalesce(p_email, '')), '')), p_resident_status, p_household_id)
  returning * into v_resident;

  return jsonb_build_object(
    'resident_id', v_resident.id,
    'id_number',   v_resident.id_number,
    'full_name',   v_resident.first_name || ' ' || v_resident.last_name,
    'resident_status', v_resident.resident_status);
end;
$$;

-- Updates the record in place. The resident's id never changes, and
-- household membership is deliberately not touched here — that is
-- registry_link_resident_to_household()'s job, which has its own rules.
create or replace function public.registry_update_resident(
  p_resident_id     uuid,
  p_id_number       text,
  p_first_name      text,
  p_last_name       text,
  p_date_of_birth   text,
  p_gender          text,
  p_resident_status text,
  p_contact_number  text default null,
  p_email           text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_id_number text := btrim(coalesce(p_id_number, ''));
  v_resident  public.residents;
begin
  perform public.require_registry_clerk();

  select * into v_resident from public.residents where id = p_resident_id for update;
  if not found then
    raise exception 'That resident could not be found.' using errcode = 'TA031';
  end if;

  if v_id_number = '' or btrim(coalesce(p_first_name, '')) = ''
     or btrim(coalesce(p_last_name, '')) = '' or btrim(coalesce(p_gender, '')) = ''
     or btrim(coalesce(p_date_of_birth, '')) = '' then
    raise exception 'Identity number, first name, surname, date of birth and gender are all required.'
      using errcode = 'TA034';
  end if;

  if not public.is_importable_date(p_date_of_birth) then
    raise exception 'That date of birth is not a valid date.' using errcode = 'TA034';
  end if;

  if p_resident_status not in ('active', 'inactive', 'deceased') then
    raise exception 'Resident status must be active, inactive or deceased.' using errcode = 'TA034';
  end if;

  if exists (select 1 from public.residents r
              where lower(r.id_number) = lower(v_id_number) and r.id <> p_resident_id) then
    raise exception 'A resident with identity number % is already on the register.', v_id_number
      using errcode = 'TA033';
  end if;

  update public.residents
     set id_number       = v_id_number,
         first_name      = btrim(p_first_name),
         last_name       = btrim(p_last_name),
         date_of_birth   = p_date_of_birth::date,
         gender          = btrim(p_gender),
         contact_number  = nullif(btrim(coalesce(p_contact_number, '')), ''),
         email           = lower(nullif(btrim(coalesce(p_email, '')), '')),
         resident_status = p_resident_status
   where id = p_resident_id
  returning * into v_resident;

  return jsonb_build_object(
    'resident_id', v_resident.id,
    'id_number',   v_resident.id_number,
    'full_name',   v_resident.first_name || ' ' || v_resident.last_name,
    'resident_status', v_resident.resident_status);
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Households
-- ---------------------------------------------------------------------

-- The next free HH-#### code, worked out from what is actually in the
-- database rather than assumed.
create or replace function public.registry_next_household_code()
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_highest int;
begin
  perform public.require_registry_clerk();

  select coalesce(max((regexp_match(household_code, '^HH-(\d+)$'))[1]::int), 0)
    into v_highest
  from public.households
  where household_code ~ '^HH-\d+$';

  return 'HH-' || lpad((v_highest + 1)::text, 4, '0');
end;
$$;

create or replace function public.registry_create_household(
  p_household_code   text,
  p_site_id          uuid,
  p_household_status text default 'active'
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_code      text := btrim(coalesce(p_household_code, ''));
  v_site      public.land_sites;
  v_household public.households;
begin
  perform public.require_registry_clerk();

  if v_code = '' then
    raise exception 'A household code is required.' using errcode = 'TA034';
  end if;
  if p_household_status not in ('active', 'inactive') then
    raise exception 'Household status must be active or inactive.' using errcode = 'TA034';
  end if;
  if exists (select 1 from public.households h where upper(h.household_code) = upper(v_code)) then
    raise exception 'Household code % is already in use.', v_code using errcode = 'TA035';
  end if;

  select * into v_site from public.land_sites where id = p_site_id;
  if not found then
    raise exception 'That land site could not be found. A Registry Clerk cannot create land sites.'
      using errcode = 'TA036';
  end if;
  if v_site.site_type <> 'residential' then
    raise exception 'Site % is a % site, so a household cannot live on it.', v_site.site_code, v_site.site_type
      using errcode = 'TA036';
  end if;
  if p_household_status = 'active'
     and exists (select 1 from public.households h
                  where h.residential_site_id = v_site.id and h.household_status = 'active') then
    raise exception 'Site % is already the residential site of another current household.', v_site.site_code
      using errcode = 'TA037';
  end if;

  -- The head is designated once the household has members.
  insert into public.households (household_code, residential_site_id, household_status)
  values (v_code, v_site.id, p_household_status)
  returning * into v_household;

  return jsonb_build_object(
    'household_id',   v_household.id,
    'household_code', v_household.household_code,
    'household_status', v_household.household_status,
    'site_code',      v_site.site_code,
    'street_address', v_site.street_address);
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Household membership
--
--    A resident belongs to one household, so linking them to a new one
--    moves them. That is never done silently: moving someone who
--    already has a household has to be confirmed.
-- ---------------------------------------------------------------------

create or replace function public.registry_link_resident_to_household(
  p_resident_id  uuid,
  p_household_id uuid,
  p_confirm_reassignment boolean default false
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_resident  public.residents;
  v_household public.households;
  v_previous  public.households;
begin
  perform public.require_registry_clerk();

  select * into v_resident from public.residents where id = p_resident_id for update;
  if not found then
    raise exception 'That resident could not be found.' using errcode = 'TA031';
  end if;

  select * into v_household from public.households where id = p_household_id;
  if not found then
    raise exception 'That household could not be found.' using errcode = 'TA032';
  end if;
  if v_household.household_status <> 'active' then
    raise exception 'Household % is not current, so residents cannot be linked to it.', v_household.household_code
      using errcode = 'TA032';
  end if;

  if v_resident.household_id = v_household.id then
    raise exception '% is already a member of household %.',
      v_resident.first_name || ' ' || v_resident.last_name, v_household.household_code
      using errcode = 'TA038';
  end if;

  if v_resident.household_id is not null then
    select * into v_previous from public.households where id = v_resident.household_id;

    if not coalesce(p_confirm_reassignment, false) then
      raise exception '% already belongs to household %. Confirm the move before it is made.',
        v_resident.first_name || ' ' || v_resident.last_name, v_previous.household_code
        using errcode = 'TA038';
    end if;

    -- Moving the head out would leave that household headed by someone
    -- who no longer lives there.
    if v_previous.head_resident_id = v_resident.id then
      raise exception '% is the head of household %. Designate another head before moving them.',
        v_resident.first_name || ' ' || v_resident.last_name, v_previous.household_code
        using errcode = 'TA045';
    end if;
  end if;

  update public.residents set household_id = v_household.id where id = v_resident.id;

  return jsonb_build_object(
    'resident_id',    v_resident.id,
    'full_name',      v_resident.first_name || ' ' || v_resident.last_name,
    'household_id',   v_household.id,
    'household_code', v_household.household_code,
    'moved_from',     v_previous.household_code);
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Head of household
-- ---------------------------------------------------------------------

create or replace function public.registry_designate_household_head(
  p_household_id uuid,
  p_resident_id  uuid,
  p_confirm_replacement boolean default false
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_household public.households;
  v_resident  public.residents;
  v_current   public.residents;
begin
  perform public.require_registry_clerk();

  select * into v_household from public.households where id = p_household_id for update;
  if not found then
    raise exception 'That household could not be found.' using errcode = 'TA032';
  end if;

  select * into v_resident from public.residents where id = p_resident_id;
  if not found then
    raise exception 'That resident could not be found.' using errcode = 'TA031';
  end if;

  -- The head must live in the household they head.
  if v_resident.household_id is distinct from v_household.id then
    raise exception '% is not a member of household %, so cannot be its head.',
      v_resident.first_name || ' ' || v_resident.last_name, v_household.household_code
      using errcode = 'TA039';
  end if;

  if v_resident.resident_status = 'deceased' then
    raise exception '% is recorded as deceased and cannot be made head of a household.',
      v_resident.first_name || ' ' || v_resident.last_name
      using errcode = 'TA040';
  end if;

  if v_household.head_resident_id = v_resident.id then
    raise exception '% already heads household %.',
      v_resident.first_name || ' ' || v_resident.last_name, v_household.household_code
      using errcode = 'TA041';
  end if;

  if v_household.head_resident_id is not null then
    select * into v_current from public.residents where id = v_household.head_resident_id;
    if not coalesce(p_confirm_replacement, false) then
      raise exception 'Household % is currently headed by %. Confirm the replacement before it is made.',
        v_household.household_code, v_current.first_name || ' ' || v_current.last_name
        using errcode = 'TA041';
    end if;
  end if;

  -- One household, one head: this replaces, it never adds.
  update public.households set head_resident_id = v_resident.id where id = v_household.id;

  return jsonb_build_object(
    'household_id',   v_household.id,
    'household_code', v_household.household_code,
    'head_resident_id', v_resident.id,
    'head_full_name', v_resident.first_name || ' ' || v_resident.last_name,
    'replaced',       (v_current.first_name || ' ' || v_current.last_name));
end;
$$;

-- ---------------------------------------------------------------------
-- 8. Family relationships, and their inverses
--
--    Recording that A is B's parent also records that B is A's child.
--    Relatives need not share a household.
-- ---------------------------------------------------------------------

create or replace function public.inverse_relationship_type(p_type text)
returns text
language sql
immutable
as $$
  select case p_type
    when 'parent'      then 'child'
    when 'child'       then 'parent'
    when 'grandparent' then 'grandchild'
    when 'grandchild'  then 'grandparent'
    when 'guardian'    then 'dependant'
    when 'dependant'   then 'guardian'
    when 'spouse'      then 'spouse'
    when 'sibling'     then 'sibling'
  end;
$$;

create or replace function public.registry_record_family_relationship(
  p_resident_id         uuid,
  p_related_resident_id uuid,
  p_relationship_type   text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_resident public.residents;
  v_related  public.residents;
  v_inverse  text := public.inverse_relationship_type(p_relationship_type);
  v_added    int := 0;
  v_inverse_added int := 0;
begin
  perform public.require_registry_clerk();

  if v_inverse is null then
    raise exception 'Relationship type % is not one this system recognises.', coalesce(p_relationship_type, '(none)')
      using errcode = 'TA044';
  end if;

  if p_resident_id = p_related_resident_id then
    raise exception 'A resident cannot be related to themselves.' using errcode = 'TA042';
  end if;

  select * into v_resident from public.residents where id = p_resident_id;
  if not found then
    raise exception 'That resident could not be found.' using errcode = 'TA031';
  end if;

  select * into v_related from public.residents where id = p_related_resident_id;
  if not found then
    raise exception 'The related resident could not be found.' using errcode = 'TA031';
  end if;

  if exists (select 1 from public.family_relationships f
              where f.resident_id = p_resident_id
                and f.related_resident_id = p_related_resident_id
                and f.relationship_type = p_relationship_type) then
    raise exception '% is already recorded as the % of %.',
      v_resident.first_name || ' ' || v_resident.last_name, p_relationship_type,
      v_related.first_name || ' ' || v_related.last_name
      using errcode = 'TA043';
  end if;

  insert into public.family_relationships (resident_id, related_resident_id, relationship_type, relationship_status)
  values (p_resident_id, p_related_resident_id, p_relationship_type, 'active');
  get diagnostics v_added = row_count;

  -- The other side of the same fact. Already there (as in the imported
  -- data) means nothing to do.
  insert into public.family_relationships (resident_id, related_resident_id, relationship_type, relationship_status)
  values (p_related_resident_id, p_resident_id, v_inverse, 'active')
  on conflict (resident_id, related_resident_id, relationship_type) do nothing;
  get diagnostics v_inverse_added = row_count;

  return jsonb_build_object(
    'resident',          v_resident.first_name || ' ' || v_resident.last_name,
    'related_resident',  v_related.first_name || ' ' || v_related.last_name,
    'relationship_type', p_relationship_type,
    'inverse_type',      v_inverse,
    'recorded',          v_added,
    'inverse_recorded',  v_inverse_added);
end;
$$;

-- Relationships are never deleted. A relationship that is no longer
-- current is marked inactive, and its inverse follows it.
create or replace function public.registry_set_relationship_status(
  p_relationship_id uuid,
  p_status          text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_relationship public.family_relationships;
begin
  perform public.require_registry_clerk();

  if p_status not in ('active', 'inactive') then
    raise exception 'A relationship status must be active or inactive.' using errcode = 'TA034';
  end if;

  select * into v_relationship from public.family_relationships where id = p_relationship_id for update;
  if not found then
    raise exception 'That relationship could not be found.' using errcode = 'TA031';
  end if;

  update public.family_relationships set relationship_status = p_status where id = v_relationship.id;

  update public.family_relationships
     set relationship_status = p_status
   where resident_id = v_relationship.related_resident_id
     and related_resident_id = v_relationship.resident_id
     and relationship_type = public.inverse_relationship_type(v_relationship.relationship_type);

  return jsonb_build_object('relationship_id', v_relationship.id, 'relationship_status', p_status);
end;
$$;

-- ---------------------------------------------------------------------
-- 9. Grants
--
--    Each function turns away anyone who is not an active Registry
--    Clerk, so granting execute to authenticated is safe.
-- ---------------------------------------------------------------------

do $$
declare
  v_signature text;
begin
  foreach v_signature in array array[
    'public.is_active_registry_clerk()',
    'public.require_registry_clerk()',
    'public.like_pattern(text)',
    'public.inverse_relationship_type(text)',
    'public.registry_search_residents(text)',
    'public.registry_resident_record(uuid)',
    'public.registry_family_lineage(uuid)',
    'public.registry_search_households(text)',
    'public.registry_household_record(uuid)',
    'public.registry_dashboard_stats()',
    'public.registry_available_residential_sites()',
    'public.registry_next_household_code()',
    'public.registry_create_resident(text, text, text, text, text, text, text, text, uuid)',
    'public.registry_update_resident(uuid, text, text, text, text, text, text, text, text)',
    'public.registry_create_household(text, uuid, text)',
    'public.registry_link_resident_to_household(uuid, uuid, boolean)',
    'public.registry_designate_household_head(uuid, uuid, boolean)',
    'public.registry_record_family_relationship(uuid, uuid, text)',
    'public.registry_set_relationship_status(uuid, text)'
  ]
  loop
    execute format('revoke all on function %s from public, anon, authenticated', v_signature);
    execute format('grant execute on function %s to authenticated', v_signature);
  end loop;
end;
$$;

-- These two are internal guards; nothing should call them directly.
revoke execute on function public.require_registry_clerk() from authenticated;
