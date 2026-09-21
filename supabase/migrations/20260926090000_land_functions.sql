-- =====================================================================
-- TAMS — land applications, allocation, permission to occupy
--
-- Every privileged operation establishes its caller from auth.uid() and
-- rechecks eligibility for itself. An eligibility answer worked out
-- earlier — when the form was shown, or when the application was
-- approved — is never taken as still true at the next step.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Who is a Land Officer
-- ---------------------------------------------------------------------

create or replace function public.is_active_land_officer()
returns boolean
language sql stable security definer set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.user_accounts ua
    join public.staff s on s.id = ua.staff_id
    join public.roles r on r.id = s.role_id
    where ua.auth_user_id = auth.uid()
      and ua.account_type = 'staff'
      and ua.account_status = 'active'
      and r.role_name = 'Land Officer');
$$;

create or replace function public.acting_land_officer_staff_id()
returns uuid
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_staff_id uuid;
begin
  select s.id into v_staff_id
  from public.user_accounts ua
  join public.staff s on s.id = ua.staff_id
  join public.roles r on r.id = s.role_id
  where ua.auth_user_id = auth.uid()
    and ua.account_type = 'staff'
    and ua.account_status = 'active'
    and r.role_name = 'Land Officer';

  if v_staff_id is null then
    raise exception 'Only an active Land Officer may do that.' using errcode = '42501';
  end if;
  return v_staff_id;
end;
$$;

-- ---------------------------------------------------------------------
-- 2. Age, counted properly
--
--    From the official date of birth on the register, never from
--    anything typed into a form, and by adding years to the birth date
--    rather than subtracting numbers — so leap years look after
--    themselves.
-- ---------------------------------------------------------------------

create or replace function public.is_at_least_age(p_date_of_birth date, p_years int)
returns boolean
language sql immutable
as $$
  select p_date_of_birth is not null
     and (p_date_of_birth + make_interval(years => p_years)) <= current_date;
$$;

comment on function public.is_at_least_age(date, int) is
  'True on the birthday itself. Uses date arithmetic, not a subtraction of year numbers.';

-- ---------------------------------------------------------------------
-- 3. What a permission is actually worth today
--
--    A fixed term runs out whether or not anybody has refreshed a
--    stored status, so every rights decision asks this, not the column.
-- ---------------------------------------------------------------------

create or replace function public.pto_effective_status(p_stored_status text, p_expiry_date date)
returns text
language sql immutable
as $$
  select case
    when p_stored_status <> 'active' then p_stored_status
    when p_expiry_date is not null and p_expiry_date < current_date then 'expired'
    else 'active'
  end;
$$;

-- ---------------------------------------------------------------------
-- 4. The resident behind the signed-in account
-- ---------------------------------------------------------------------

create or replace function public.current_resident_id()
returns uuid
language sql stable security definer set search_path = public, pg_temp
as $$
  select ua.resident_id
  from public.user_accounts ua
  where ua.auth_user_id = auth.uid()
    and ua.account_type = 'resident'
    and ua.account_status = 'active'
    and ua.resident_id is not null;
$$;

-- The households this resident heads.
--
-- A policy that asked `select id from households where head_resident_id = …`
-- inline would read households under Row Level Security, which gives a
-- resident nothing — so the household-head half of every policy below
-- would quietly match nothing. This looks for them as the definer, and
-- can only ever return households the caller actually heads.
create or replace function public.current_resident_headed_household_ids()
returns setof uuid
language sql stable security definer set search_path = public, pg_temp
as $$
  select h.id from public.households h
  where h.head_resident_id = public.current_resident_id();
$$;

-- ---------------------------------------------------------------------
-- 5. May this person have this kind of land?
--
--    One answer, asked at every stage: showing the form, submitting,
--    approving and allocating.
-- ---------------------------------------------------------------------

create or replace function public.land_eligibility(p_resident_id uuid, p_land_type text)
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare
  v_resident  public.residents;
  v_household public.households;
  v_account   public.user_accounts;
  v_problems  text[] := '{}';
  v_is_head   boolean := false;
begin
  if p_land_type is null or not (p_land_type = any (public.allocatable_land_types())) then
    return jsonb_build_object('eligible', false, 'problems', array['That is not a kind of land TAMS allocates.']);
  end if;

  select * into v_resident from public.residents where id = p_resident_id;
  if not found then
    return jsonb_build_object('eligible', false, 'problems', array['That person is not on the village register.']);
  end if;

  if v_resident.resident_status <> 'active' then
    v_problems := array_append(v_problems, format('The register records this person as %s.', v_resident.resident_status));
  end if;

  -- Age comes from the register, not from the application.
  if not public.is_at_least_age(v_resident.date_of_birth, 21) then
    v_problems := array_append(v_problems, 'An applicant must be at least 21 years old.');
  end if;

  select * into v_account from public.user_accounts
  where resident_id = p_resident_id and account_type = 'resident';
  if not found or v_account.account_status <> 'active' then
    v_problems := array_append(v_problems, 'A verified, active resident account is needed to apply.');
  end if;

  if v_resident.household_id is null then
    v_problems := array_append(v_problems, 'This person is not linked to a household.');
  else
    select * into v_household from public.households where id = v_resident.household_id;
    if not found or v_household.household_status <> 'active' then
      v_problems := array_append(v_problems, 'This person''s household is not current.');
    else
      v_is_head := (v_household.head_resident_id = v_resident.id);
    end if;
  end if;

  -- ---- what each kind of land asks on top ---------------------------
  if p_land_type = 'residential' then
    if exists (select 1 from public.land_allocations a
                where a.resident_id = p_resident_id and a.land_type = 'residential'
                  and a.allocation_status in ('active', 'succession_pending')) then
      v_problems := array_append(v_problems, 'This person already holds a residential stand.');
    end if;

  elsif p_land_type = 'business' then
    -- An expired permission does not free the site. The allocation has
    -- to be released by the Land Officer first.
    if exists (select 1 from public.land_allocations a
                where a.resident_id = p_resident_id and a.land_type = 'business'
                  and a.allocation_status = 'active') then
      v_problems := array_append(v_problems, 'This person already holds a business site. It has to be released before another is given.');
    end if;

  elsif p_land_type = 'farming' then
    if not v_is_head then
      v_problems := array_append(v_problems, 'Only the current head of the household may apply for farming land.');
    end if;
    if v_resident.household_id is not null
       and exists (select 1 from public.land_allocations a
                    where a.household_id = v_resident.household_id and a.land_type = 'farming'
                      and a.allocation_status = 'active') then
      v_problems := array_append(v_problems, 'This household already holds farming land.');
    end if;

  elsif p_land_type = 'burial' then
    if not v_is_head then
      v_problems := array_append(v_problems, 'Only the current head of the household may apply for a burial plot.');
    end if;
    -- Another plot only once every plot the household holds is full or
    -- closed. A usable plot means there is nowhere else to be.
    if v_resident.household_id is not null
       and exists (select 1 from public.land_allocations a
                    join public.land_sites s on s.id = a.land_site_id
                    where a.household_id = v_resident.household_id
                      and a.land_type = 'burial'
                      and a.allocation_status = 'active'
                      and s.burial_status = 'usable') then
      v_problems := array_append(v_problems, 'This household still has a burial plot with space in it.');
    end if;
  end if;

  return jsonb_build_object(
    'eligible',          array_length(v_problems, 1) is null,
    'problems',          to_jsonb(v_problems),
    'resident_id',       p_resident_id,
    'household_id',      v_resident.household_id,
    'is_household_head', v_is_head,
    'land_type',         p_land_type);
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Reference numbers, worked out from what is in the database
-- ---------------------------------------------------------------------

create or replace function public.next_reference(p_prefix text, p_column text, p_table text, p_width int default 4)
returns text
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_highest int;
begin
  execute format(
    'select coalesce(max((regexp_match(%I, %L))[1]::int), 0) from public.%I where %I ~ %L',
    p_column, '^' || p_prefix || '(\d+)$', p_table, p_column, '^' || p_prefix || '\d+$')
  into v_highest;
  return p_prefix || lpad((v_highest + 1)::text, p_width, '0');
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Reading: what the applicant and the officer may see
-- ---------------------------------------------------------------------

-- A resident sees their own applications, and the household's farming
-- and burial ones when they are the head of it.
drop policy if exists land_applications_readable on public.land_applications;
create policy land_applications_readable
  on public.land_applications for select to authenticated
  using (
    public.is_active_land_officer()
    or public.is_active_registry_clerk()
    or applicant_resident_id = public.current_resident_id()
    or (land_type in ('farming', 'burial')
        and household_id in (select public.current_resident_headed_household_ids()))
  );

drop policy if exists ptos_readable on public.ptos;
create policy ptos_readable
  on public.ptos for select to authenticated
  using (
    public.is_active_land_officer()
    or public.is_active_registry_clerk()
    or holder_resident_id = public.current_resident_id()
    or holder_household_id in (select public.current_resident_headed_household_ids())
  );

drop policy if exists pto_renewal_requests_readable on public.pto_renewal_requests;
create policy pto_renewal_requests_readable
  on public.pto_renewal_requests for select to authenticated
  using (
    public.is_active_land_officer()
    or requested_by_resident_id = public.current_resident_id()
  );

-- The Land Officer reads the register and the sites for context, and
-- writes neither directly: every change goes through a function.
drop policy if exists land_sites_readable_by_land_officer on public.land_sites;
create policy land_sites_readable_by_land_officer
  on public.land_sites for select to authenticated
  using (public.is_active_land_officer());

drop policy if exists land_allocations_readable_by_land_officer on public.land_allocations;
create policy land_allocations_readable_by_land_officer
  on public.land_allocations for select to authenticated
  using (
    public.is_active_land_officer()
    or resident_id = public.current_resident_id()
    or household_id in (select public.current_resident_headed_household_ids())
  );

drop policy if exists residents_readable_by_land_officer on public.residents;
create policy residents_readable_by_land_officer
  on public.residents for select to authenticated
  using (public.is_active_land_officer());

drop policy if exists households_readable_by_land_officer on public.households;
create policy households_readable_by_land_officer
  on public.households for select to authenticated
  using (public.is_active_land_officer());

drop policy if exists family_relationships_readable_by_land_officer on public.family_relationships;
create policy family_relationships_readable_by_land_officer
  on public.family_relationships for select to authenticated
  using (public.is_active_land_officer());

-- ---------------------------------------------------------------------
-- 8. A resident applies
-- ---------------------------------------------------------------------

create or replace function public.resident_land_eligibility(p_land_type text)
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_resident_id uuid := public.current_resident_id();
begin
  if v_resident_id is null then
    raise exception 'Only a verified resident may apply for land.' using errcode = '42501';
  end if;
  return public.land_eligibility(v_resident_id, p_land_type);
end;
$$;

create or replace function public.resident_submit_land_application(
  p_land_type text,
  p_details   jsonb
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_resident_id  uuid := public.current_resident_id();
  v_eligibility  jsonb;
  v_resident     public.residents;
  v_account_id   uuid;
  v_application  public.land_applications;
  v_reason       text := btrim(coalesce(p_details ->> 'reason_for_application', ''));
begin
  if v_resident_id is null then
    raise exception 'Only a verified resident may apply for land.' using errcode = '42501';
  end if;

  v_eligibility := public.land_eligibility(v_resident_id, p_land_type);
  if not (v_eligibility ->> 'eligible')::boolean then
    raise exception '%', (select string_agg(value, ' ') from jsonb_array_elements_text(v_eligibility -> 'problems'))
      using errcode = 'TA060';
  end if;

  if v_reason = '' then
    raise exception 'A reason for the application is required.' using errcode = 'TA061';
  end if;

  if p_land_type = 'farming'
     and coalesce(p_details ->> 'farming_type', '') not in ('crop', 'livestock', 'mixed', 'other') then
    raise exception 'Choose the kind of farming this land is for.' using errcode = 'TA061';
  end if;
  if p_land_type = 'business'
     and coalesce(p_details ->> 'business_type', '') not in ('shop', 'restaurant', 'salon', 'workshop', 'office', 'other') then
    raise exception 'Choose the kind of business this site is for.' using errcode = 'TA061';
  end if;

  select * into v_resident from public.residents where id = v_resident_id;
  select id into v_account_id from public.user_accounts where resident_id = v_resident_id;

  begin
    insert into public.land_applications (
      application_reference, applicant_resident_id, applicant_user_account_id, household_id,
      land_type, reason_for_application, intended_use, lives_with_household,
      farming_type, farming_activity, business_name, business_type, business_description)
    values (
      public.next_reference('APP-', 'application_reference', 'land_applications', 5),
      v_resident_id, v_account_id, v_resident.household_id,
      p_land_type, v_reason,
      nullif(btrim(coalesce(p_details ->> 'intended_use', '')), ''),
      case when p_land_type = 'residential' then (p_details ->> 'lives_with_household')::boolean end,
      case when p_land_type = 'farming' then p_details ->> 'farming_type' end,
      case when p_land_type = 'farming' then nullif(btrim(coalesce(p_details ->> 'farming_activity', '')), '') end,
      case when p_land_type = 'business' then nullif(btrim(coalesce(p_details ->> 'business_name', '')), '') end,
      case when p_land_type = 'business' then p_details ->> 'business_type' end,
      case when p_land_type = 'business' then nullif(btrim(coalesce(p_details ->> 'business_description', '')), '') end)
    returning * into v_application;
  exception when unique_violation then
    raise exception 'There is already an application of this kind waiting to be dealt with.'
      using errcode = 'TA062';
  end;

  return jsonb_build_object(
    'application_id',        v_application.id,
    'application_reference', v_application.application_reference,
    'land_type',             v_application.land_type,
    'application_status',    v_application.application_status);
end;
$$;

-- ---------------------------------------------------------------------
-- 9. Land sites
-- ---------------------------------------------------------------------

create or replace function public.land_officer_register_site(
  p_site_code       text,
  p_site_type       text,
  p_street_address  text,
  p_stand_number    text default null,
  p_village_section text default null,
  p_village_name    text default null
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_code text := btrim(coalesce(p_site_code, ''));
  v_site public.land_sites;
begin
  perform public.acting_land_officer_staff_id();

  if v_code = '' or btrim(coalesce(p_street_address, '')) = '' then
    raise exception 'A site code and a street address are required.' using errcode = 'TA063';
  end if;

  -- Only the four. Grazing is not allocated through TAMS.
  if not (p_site_type = any (public.allocatable_land_types())) then
    raise exception '% is not a kind of land TAMS allocates.', coalesce(p_site_type, '(none)')
      using errcode = 'TA064';
  end if;

  if exists (select 1 from public.land_sites where upper(site_code) = upper(v_code)) then
    raise exception 'Site code % is already in use.', v_code using errcode = 'TA065';
  end if;

  insert into public.land_sites (site_code, site_type, stand_number, street_address,
                                 village_section, village_name, site_status, burial_status)
  values (v_code, p_site_type, nullif(btrim(coalesce(p_stand_number, '')), ''), btrim(p_street_address),
          nullif(btrim(coalesce(p_village_section, '')), ''), nullif(btrim(coalesce(p_village_name, '')), ''),
          'available', case when p_site_type = 'burial' then 'usable' end)
  returning * into v_site;

  return jsonb_build_object('site_id', v_site.id, 'site_code', v_site.site_code,
                            'site_type', v_site.site_type, 'site_status', v_site.site_status);
end;
$$;

create or replace function public.land_officer_update_site(
  p_site_id         uuid,
  p_site_type       text,
  p_street_address  text,
  p_stand_number    text default null,
  p_village_section text default null,
  p_village_name    text default null,
  p_site_status     text default null
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_site   public.land_sites;
  v_open   boolean;
  v_status text;
begin
  perform public.acting_land_officer_staff_id();

  select * into v_site from public.land_sites where id = p_site_id for update;
  if not found then
    raise exception 'That land site could not be found.' using errcode = 'TA066';
  end if;

  v_open := exists (select 1 from public.land_allocations a
                     where a.land_site_id = v_site.id
                       and a.allocation_status in ('active', 'succession_pending'));

  if p_site_type is distinct from v_site.site_type then
    if v_open then
      raise exception 'Site % is allocated, so its type cannot be changed.', v_site.site_code
        using errcode = 'TA067';
    end if;
    if exists (select 1 from public.land_allocations a where a.land_site_id = v_site.id) then
      raise exception 'Site % has allocation history, so its type cannot be changed.', v_site.site_code
        using errcode = 'TA067';
    end if;
    if not (p_site_type = any (public.allocatable_land_types())) then
      raise exception '% is not a kind of land TAMS allocates.', coalesce(p_site_type, '(none)')
        using errcode = 'TA064';
    end if;
  end if;

  v_status := coalesce(p_site_status, v_site.site_status);
  if v_status not in ('available', 'allocated', 'unavailable') then
    raise exception 'A site is available, allocated or unavailable.' using errcode = 'TA068';
  end if;
  -- An allocated site is not made free by editing it. Release the
  -- allocation instead.
  if v_open and v_status <> 'allocated' then
    raise exception 'Site % is allocated. Release the allocation before changing its status.', v_site.site_code
      using errcode = 'TA068';
  end if;

  update public.land_sites
     set site_type = p_site_type,
         street_address = btrim(p_street_address),
         stand_number = nullif(btrim(coalesce(p_stand_number, '')), ''),
         village_section = nullif(btrim(coalesce(p_village_section, '')), ''),
         village_name = nullif(btrim(coalesce(p_village_name, '')), ''),
         site_status = v_status,
         burial_status = case when p_site_type = 'burial' then coalesce(v_site.burial_status, 'usable') end
   where id = v_site.id
  returning * into v_site;

  return jsonb_build_object('site_id', v_site.id, 'site_code', v_site.site_code,
                            'site_type', v_site.site_type, 'site_status', v_site.site_status);
end;
$$;

-- ---------------------------------------------------------------------
-- 10. Reviewing an application
-- ---------------------------------------------------------------------

create or replace function public.land_officer_applications(
  p_status text default null,
  p_land_type text default null,
  p_search text default null
)
returns table (
  application_id        uuid,
  application_reference text,
  land_type             text,
  application_status    text,
  applicant_name        text,
  applicant_id_number   text,
  applicant_age         int,
  household_code        text,
  submitted_at          timestamptz,
  reviewed_at           timestamptz,
  decline_reason        text,
  allocated_site_code   text
)
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_pattern text := public.like_pattern(p_search);
        v_empty boolean := coalesce(btrim(p_search), '') = '';
begin
  perform public.acting_land_officer_staff_id();

  return query
    select a.id, a.application_reference, a.land_type, a.application_status,
           r.first_name || ' ' || r.last_name, r.id_number,
           extract(year from age(current_date, r.date_of_birth))::int,
           h.household_code, a.submitted_at, a.reviewed_at, a.decline_reason,
           (select s.site_code from public.land_allocations al
             join public.land_sites s on s.id = al.land_site_id
             where al.land_application_id = a.id limit 1)
    from public.land_applications a
    join public.residents r on r.id = a.applicant_resident_id
    join public.households h on h.id = a.household_id
    where (p_status is null or a.application_status = p_status)
      and (p_land_type is null or a.land_type = p_land_type)
      and (v_empty
           or a.application_reference ilike v_pattern
           or r.first_name ilike v_pattern or r.last_name ilike v_pattern
           or (r.first_name || ' ' || r.last_name) ilike v_pattern
           or r.id_number ilike v_pattern
           or h.household_code ilike v_pattern)
    order by a.submitted_at desc;
end;
$$;

-- Everything the officer needs to judge one application, all of it read
-- only. Identity, household and family are the Registry Clerk's to
-- change, not this function's.
create or replace function public.land_officer_application(p_application_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_result jsonb;
begin
  perform public.acting_land_officer_staff_id();

  select jsonb_build_object(
    'application_id',        a.id,
    'application_reference', a.application_reference,
    'land_type',             a.land_type,
    'application_status',    a.application_status,
    'reason_for_application', a.reason_for_application,
    'intended_use',          a.intended_use,
    'lives_with_household',  a.lives_with_household,
    'farming_type',          a.farming_type,
    'farming_activity',      a.farming_activity,
    'business_name',         a.business_name,
    'business_type',         a.business_type,
    'business_description',  a.business_description,
    'submitted_at',          a.submitted_at,
    'reviewed_at',           a.reviewed_at,
    'decline_reason',        a.decline_reason,
    'applicant', jsonb_build_object(
      'resident_id',     r.id,
      'full_name',       r.first_name || ' ' || r.last_name,
      'id_number',       r.id_number,
      'date_of_birth',   r.date_of_birth,
      'age',             extract(year from age(current_date, r.date_of_birth))::int,
      'gender',          r.gender,
      'resident_status', r.resident_status,
      'account_status',  (select ua.account_status from public.user_accounts ua where ua.resident_id = r.id)),
    'household', jsonb_build_object(
      'household_id',     h.id,
      'household_code',   h.household_code,
      'household_status', h.household_status,
      'head_full_name',   (select head.first_name || ' ' || head.last_name
                             from public.residents head where head.id = h.head_resident_id),
      'is_head',          (h.head_resident_id = r.id),
      'members', coalesce((select jsonb_agg(jsonb_build_object(
                             'full_name', m.first_name || ' ' || m.last_name,
                             'resident_status', m.resident_status,
                             'age', extract(year from age(current_date, m.date_of_birth))::int)
                           order by m.date_of_birth)
                           from public.residents m where m.household_id = h.id), '[]'::jsonb)),
    'family', coalesce((select jsonb_agg(jsonb_build_object(
                          'relationship_type', f.relationship_type,
                          'related_full_name', o.first_name || ' ' || o.last_name,
                          'relationship_status', f.relationship_status)
                        order by f.relationship_type)
                        from public.family_relationships f
                        join public.residents o on o.id = f.related_resident_id
                        where f.resident_id = r.id and f.relationship_status = 'active'), '[]'::jsonb),
    'land_held', coalesce((select jsonb_agg(jsonb_build_object(
                             'allocation_reference', al.allocation_reference,
                             'land_type',  al.land_type,
                             'site_code',  s.site_code,
                             'allocation_status', al.allocation_status,
                             'burial_status', s.burial_status,
                             'held_by', case when al.resident_id is not null then 'resident' else 'household' end)
                           order by al.land_type)
                           from public.land_allocations al
                           join public.land_sites s on s.id = al.land_site_id
                           where (al.resident_id = r.id or al.household_id = h.id)
                             and al.allocation_status in ('active', 'succession_pending')), '[]'::jsonb),
    'earlier_applications', coalesce((select jsonb_agg(jsonb_build_object(
                             'application_reference', e.application_reference,
                             'land_type', e.land_type,
                             'application_status', e.application_status,
                             'submitted_at', e.submitted_at,
                             'decline_reason', e.decline_reason)
                           order by e.submitted_at desc)
                           from public.land_applications e
                           where e.applicant_resident_id = r.id and e.id <> a.id), '[]'::jsonb),
    'eligibility', public.land_eligibility(r.id, a.land_type)
  ) into v_result
  from public.land_applications a
  join public.residents r on r.id = a.applicant_resident_id
  join public.households h on h.id = a.household_id
  where a.id = p_application_id;

  if v_result is null then
    raise exception 'That application could not be found.' using errcode = 'TA069';
  end if;
  return v_result;
end;
$$;

create or replace function public.land_officer_approve_application(p_application_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id    uuid := public.acting_land_officer_staff_id();
  v_application public.land_applications;
  v_eligibility jsonb;
begin
  select * into v_application from public.land_applications where id = p_application_id for update;
  if not found then
    raise exception 'That application could not be found.' using errcode = 'TA069';
  end if;
  if v_application.application_status <> 'pending' then
    raise exception 'That application has already been %.', v_application.application_status
      using errcode = 'TA069';
  end if;

  -- Asked again, now. Circumstances move between applying and deciding.
  v_eligibility := public.land_eligibility(v_application.applicant_resident_id, v_application.land_type);
  if not (v_eligibility ->> 'eligible')::boolean then
    raise exception '%', (select string_agg(value, ' ') from jsonb_array_elements_text(v_eligibility -> 'problems'))
      using errcode = 'TA060';
  end if;

  update public.land_applications
     set application_status = 'approved', reviewed_at = now(), reviewed_by_staff_id = v_staff_id
   where id = v_application.id;

  return jsonb_build_object('application_id', v_application.id,
                            'application_reference', v_application.application_reference,
                            'application_status', 'approved');
end;
$$;

create or replace function public.land_officer_decline_application(
  p_application_id uuid,
  p_reason text
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id uuid := public.acting_land_officer_staff_id();
  v_reason   text := btrim(coalesce(p_reason, ''));
  v_application public.land_applications;
begin
  if v_reason = '' then
    raise exception 'A reason is required, so the applicant knows why.' using errcode = 'TA061';
  end if;

  select * into v_application from public.land_applications where id = p_application_id for update;
  if not found then
    raise exception 'That application could not be found.' using errcode = 'TA069';
  end if;
  if v_application.application_status <> 'pending' then
    raise exception 'That application has already been %.', v_application.application_status
      using errcode = 'TA069';
  end if;

  update public.land_applications
     set application_status = 'declined', decline_reason = v_reason,
         reviewed_at = now(), reviewed_by_staff_id = v_staff_id
   where id = v_application.id;

  return jsonb_build_object('application_id', v_application.id, 'application_status', 'declined',
                            'decline_reason', v_reason);
end;
$$;

-- ---------------------------------------------------------------------
-- 11. Allocating a site
--
--     One transaction: the site is locked, everything is rechecked, the
--     allocation is written, the site is marked and the application is
--     closed. Two officers acting at once cannot both win — the unique
--     indexes on open allocations settle it in the database.
-- ---------------------------------------------------------------------

create or replace function public.land_officer_available_sites(p_land_type text)
returns table (site_id uuid, site_code text, stand_number text, street_address text,
               village_section text, village_name text)
language plpgsql stable security definer set search_path = public, pg_temp
as $$
begin
  perform public.acting_land_officer_staff_id();
  return query
    select s.id, s.site_code, s.stand_number, s.street_address, s.village_section, s.village_name
    from public.land_sites s
    where s.site_type = p_land_type
      and s.site_status = 'available'
      and (s.site_type <> 'burial' or s.burial_status = 'usable')
      and not exists (select 1 from public.land_allocations a
                       where a.land_site_id = s.id
                         and a.allocation_status in ('active', 'succession_pending'))
    order by s.site_code;
end;
$$;

create or replace function public.land_officer_allocate_site(
  p_application_id uuid,
  p_site_id        uuid
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id    uuid := public.acting_land_officer_staff_id();
  v_application public.land_applications;
  v_site        public.land_sites;
  v_eligibility jsonb;
  v_allocation  public.land_allocations;
  v_resident    public.residents;
begin
  select * into v_application from public.land_applications where id = p_application_id for update;
  if not found then
    raise exception 'That application could not be found.' using errcode = 'TA069';
  end if;
  if v_application.application_status <> 'approved' then
    raise exception 'Only an approved application can be given a site. This one is %.',
      v_application.application_status using errcode = 'TA069';
  end if;

  -- Locking the site is what makes two simultaneous allocations
  -- impossible rather than merely unlikely.
  select * into v_site from public.land_sites where id = p_site_id for update;
  if not found then
    raise exception 'That land site could not be found.' using errcode = 'TA066';
  end if;
  if v_site.site_type <> v_application.land_type then
    raise exception 'Site % is % land, but this is a % application.',
      v_site.site_code, v_site.site_type, v_application.land_type using errcode = 'TA070';
  end if;
  if v_site.site_status <> 'available'
     or exists (select 1 from public.land_allocations a
                 where a.land_site_id = v_site.id
                   and a.allocation_status in ('active', 'succession_pending')) then
    raise exception 'Site % is not available.', v_site.site_code using errcode = 'TA071';
  end if;
  if v_site.site_type = 'burial' and v_site.burial_status <> 'usable' then
    raise exception 'Burial plot % is %, so it cannot be allocated.', v_site.site_code, v_site.burial_status
      using errcode = 'TA071';
  end if;

  v_eligibility := public.land_eligibility(v_application.applicant_resident_id, v_application.land_type);
  if not (v_eligibility ->> 'eligible')::boolean then
    raise exception '%', (select string_agg(value, ' ') from jsonb_array_elements_text(v_eligibility -> 'problems'))
      using errcode = 'TA060';
  end if;

  select * into v_resident from public.residents where id = v_application.applicant_resident_id;

  begin
    insert into public.land_allocations (
      allocation_reference, land_site_id, resident_id, household_id, land_application_id,
      land_type, allocation_date, allocation_status)
    values (
      public.next_reference('ALLOC-', 'allocation_reference', 'land_allocations', 4),
      v_site.id,
      -- Residential and business are held by the person; farming and
      -- burial by the household. Residential keeps the household too,
      -- which is what succession later depends on.
      case when v_application.land_type in ('residential', 'business') then v_resident.id end,
      v_application.household_id,
      v_application.id,
      v_application.land_type, current_date, 'active')
    returning * into v_allocation;
  exception when unique_violation then
    raise exception 'That site or that applicant already has a current allocation.' using errcode = 'TA071';
  end;

  update public.land_sites set site_status = 'allocated' where id = v_site.id;
  update public.land_applications set application_status = 'allocated' where id = v_application.id;

  return jsonb_build_object(
    'allocation_id',        v_allocation.id,
    'allocation_reference', v_allocation.allocation_reference,
    'site_code',            v_site.site_code,
    'land_type',            v_allocation.land_type,
    'application_status',   'allocated');
end;
$$;

-- ---------------------------------------------------------------------
-- 12. Issuing a permission to occupy
--
--     Every field comes from the allocation and the register. The
--     officer types nothing: not the holder, not the site, not the
--     duration.
-- ---------------------------------------------------------------------

create or replace function public.pto_term_end(p_land_type text, p_from date)
returns date
language sql immutable
as $$
  select case p_land_type
    when 'farming'  then (p_from + make_interval(years => 5))::date
    when 'business' then (p_from + make_interval(years => 2))::date
    else null   -- residential and burial are perpetual
  end;
$$;

create or replace function public.land_officer_issue_pto(p_allocation_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id   uuid := public.acting_land_officer_staff_id();
  v_allocation public.land_allocations;
  v_prefix     text;
  v_pto        public.ptos;
begin
  select * into v_allocation from public.land_allocations where id = p_allocation_id for update;
  if not found then
    raise exception 'That allocation could not be found.' using errcode = 'TA072';
  end if;
  if v_allocation.allocation_status <> 'active' then
    raise exception 'That allocation is %, so no permission can be issued against it.',
      v_allocation.allocation_status using errcode = 'TA072';
  end if;
  if exists (select 1 from public.ptos p
              where p.land_allocation_id = v_allocation.id and p.pto_status = 'active') then
    raise exception 'That allocation already has a current permission to occupy.' using errcode = 'TA073';
  end if;

  v_prefix := case v_allocation.land_type
                when 'residential' then 'PTO-RES-'
                when 'farming'     then 'PTO-FRM-'
                when 'business'    then 'PTO-BUS-'
                else 'PTO-BUR-' end;

  insert into public.ptos (
    pto_number, land_allocation_id, land_type, holder_resident_id, holder_household_id,
    issue_date, expiry_date, pto_status, issued_by_staff_id, verification_token)
  values (
    public.next_reference(v_prefix, 'pto_number', 'ptos', 4),
    v_allocation.id, v_allocation.land_type,
    case when v_allocation.land_type in ('residential', 'business') then v_allocation.resident_id end,
    case when v_allocation.land_type in ('farming', 'burial') then v_allocation.household_id end,
    current_date,
    public.pto_term_end(v_allocation.land_type, current_date),
    'active', v_staff_id,
    encode(gen_random_bytes(16), 'hex'))
  returning * into v_pto;

  return jsonb_build_object(
    'pto_id',     v_pto.id,
    'pto_number', v_pto.pto_number,
    'land_type',  v_pto.land_type,
    'issue_date', v_pto.issue_date,
    'expiry_date', v_pto.expiry_date,
    'perpetual',  (v_pto.expiry_date is null),
    'verification_token', v_pto.verification_token);
end;
$$;

-- ---------------------------------------------------------------------
-- 13. Renewal — only what has a term to renew
-- ---------------------------------------------------------------------

create or replace function public.resident_request_pto_renewal(p_pto_id uuid, p_reason text default null)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_resident_id uuid := public.current_resident_id();
  v_pto         public.ptos;
  v_allocation  public.land_allocations;
  v_request     public.pto_renewal_requests;
begin
  if v_resident_id is null then
    raise exception 'Only a verified resident may ask for a renewal.' using errcode = '42501';
  end if;

  select * into v_pto from public.ptos where id = p_pto_id for update;
  if not found then
    raise exception 'That permission could not be found.' using errcode = 'TA074';
  end if;

  -- Perpetual permissions are not renewed; there is nothing to renew.
  if v_pto.land_type not in ('farming', 'business') then
    raise exception 'A % permission to occupy is perpetual and is not renewed.', v_pto.land_type
      using errcode = 'TA075';
  end if;
  if v_pto.pto_status in ('revoked', 'superseded') then
    raise exception 'That permission was %, so it cannot be renewed.', v_pto.pto_status
      using errcode = 'TA076';
  end if;
  if v_pto.pto_status = 'renewed' then
    raise exception 'That permission has already been renewed.' using errcode = 'TA076';
  end if;

  -- Business is the holder's own; farming belongs to the household and
  -- is asked for by whoever heads it now.
  if v_pto.land_type = 'business' then
    if v_pto.holder_resident_id <> v_resident_id then
      raise exception 'That permission is not yours.' using errcode = '42501';
    end if;
  else
    if not exists (select 1 from public.households h
                    where h.id = v_pto.holder_household_id and h.head_resident_id = v_resident_id) then
      raise exception 'Only the current head of the household may renew the household''s farming permission.'
        using errcode = '42501';
    end if;
  end if;

  select * into v_allocation from public.land_allocations where id = v_pto.land_allocation_id;
  if v_allocation.allocation_status <> 'active' then
    raise exception 'The allocation behind that permission is no longer current.' using errcode = 'TA076';
  end if;

  begin
    insert into public.pto_renewal_requests (pto_id, requested_by_resident_id, reason)
    values (v_pto.id, v_resident_id, nullif(btrim(coalesce(p_reason, '')), ''))
    returning * into v_request;
  exception when unique_violation then
    raise exception 'A renewal request for that permission is already waiting.' using errcode = 'TA077';
  end;

  return jsonb_build_object('renewal_request_id', v_request.id, 'pto_number', v_pto.pto_number,
                            'request_status', 'pending');
end;
$$;

create or replace function public.land_officer_renewal_requests(p_status text default 'pending')
returns table (
  renewal_request_id uuid, pto_number text, land_type text, site_code text,
  holder_name text, household_code text, expiry_date date, effective_status text,
  requested_at timestamptz, request_status text, reason text, decline_reason text
)
language plpgsql stable security definer set search_path = public, pg_temp
as $$
begin
  perform public.acting_land_officer_staff_id();
  return query
    select q.id, p.pto_number, p.land_type, s.site_code,
           (select r.first_name || ' ' || r.last_name from public.residents r where r.id = p.holder_resident_id),
           (select h.household_code from public.households h where h.id = p.holder_household_id),
           p.expiry_date, public.pto_effective_status(p.pto_status, p.expiry_date),
           q.requested_at, q.request_status, q.reason, q.decline_reason
    from public.pto_renewal_requests q
    join public.ptos p on p.id = q.pto_id
    join public.land_allocations a on a.id = p.land_allocation_id
    join public.land_sites s on s.id = a.land_site_id
    where (p_status is null or q.request_status = p_status)
    order by q.requested_at;
end;
$$;

-- Approving writes a NEW permission and marks the old one renewed. The
-- old one is never edited into the new one.
create or replace function public.land_officer_approve_renewal(p_request_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id   uuid := public.acting_land_officer_staff_id();
  v_request    public.pto_renewal_requests;
  v_old        public.ptos;
  v_allocation public.land_allocations;
  v_start      date;
  v_prefix     text;
  v_new        public.ptos;
begin
  select * into v_request from public.pto_renewal_requests where id = p_request_id for update;
  if not found then
    raise exception 'That renewal request could not be found.' using errcode = 'TA077';
  end if;
  if v_request.request_status <> 'pending' then
    raise exception 'That renewal request has already been %.', v_request.request_status using errcode = 'TA077';
  end if;

  select * into v_old from public.ptos where id = v_request.pto_id for update;
  if v_old.pto_status not in ('active', 'expired') then
    raise exception 'That permission is %, so it cannot be renewed.', v_old.pto_status using errcode = 'TA076';
  end if;

  select * into v_allocation from public.land_allocations where id = v_old.land_allocation_id for update;
  if v_allocation.allocation_status <> 'active' then
    raise exception 'The allocation behind that permission is no longer current.' using errcode = 'TA076';
  end if;

  -- Renewing early continues from the old expiry; renewing something
  -- already lapsed starts today. Either way the site does not change.
  if v_old.land_type = 'business' then
    if (select resident_status from public.residents where id = v_old.holder_resident_id) <> 'active' then
      raise exception 'The holder is no longer an active resident.' using errcode = 'TA060';
    end if;
  else
    if not exists (select 1 from public.households h
                    where h.id = v_old.holder_household_id and h.household_status = 'active') then
      raise exception 'That household is no longer current.' using errcode = 'TA060';
    end if;
    if not exists (select 1 from public.households h
                    where h.id = v_old.holder_household_id
                      and h.head_resident_id = v_request.requested_by_resident_id) then
      raise exception 'The person who asked is no longer the head of that household.' using errcode = 'TA060';
    end if;
  end if;

  v_start := greatest(current_date, coalesce(v_old.expiry_date, current_date));

  v_prefix := case v_old.land_type when 'farming' then 'PTO-FRM-' else 'PTO-BUS-' end;

  update public.ptos set pto_status = 'renewed' where id = v_old.id;

  insert into public.ptos (
    pto_number, land_allocation_id, land_type, holder_resident_id, holder_household_id,
    issue_date, expiry_date, pto_status, renewed_from_pto_id, issued_by_staff_id, verification_token)
  values (
    public.next_reference(v_prefix, 'pto_number', 'ptos', 4),
    v_old.land_allocation_id, v_old.land_type, v_old.holder_resident_id, v_old.holder_household_id,
    v_start, public.pto_term_end(v_old.land_type, v_start), 'active', v_old.id, v_staff_id,
    encode(gen_random_bytes(16), 'hex'))
  returning * into v_new;

  update public.pto_renewal_requests
     set request_status = 'approved', reviewed_at = now(),
         reviewed_by_staff_id = v_staff_id, resulting_pto_id = v_new.id
   where id = v_request.id;

  return jsonb_build_object(
    'previous_pto_number', v_old.pto_number, 'previous_status', 'renewed',
    'pto_number', v_new.pto_number, 'issue_date', v_new.issue_date, 'expiry_date', v_new.expiry_date);
end;
$$;

create or replace function public.land_officer_decline_renewal(p_request_id uuid, p_reason text)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id uuid := public.acting_land_officer_staff_id();
  v_reason   text := btrim(coalesce(p_reason, ''));
  v_request  public.pto_renewal_requests;
begin
  if v_reason = '' then
    raise exception 'A reason is required.' using errcode = 'TA061';
  end if;
  select * into v_request from public.pto_renewal_requests where id = p_request_id for update;
  if not found then
    raise exception 'That renewal request could not be found.' using errcode = 'TA077';
  end if;
  if v_request.request_status <> 'pending' then
    raise exception 'That renewal request has already been %.', v_request.request_status using errcode = 'TA077';
  end if;

  update public.pto_renewal_requests
     set request_status = 'declined', decline_reason = v_reason,
         reviewed_at = now(), reviewed_by_staff_id = v_staff_id
   where id = v_request.id;

  return jsonb_build_object('renewal_request_id', v_request.id, 'request_status', 'declined',
                            'decline_reason', v_reason);
end;
$$;

-- ---------------------------------------------------------------------
-- 14. Revoking, and releasing a site
-- ---------------------------------------------------------------------

create or replace function public.land_officer_revoke_pto(p_pto_id uuid, p_reason text)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id uuid := public.acting_land_officer_staff_id();
  v_reason   text := btrim(coalesce(p_reason, ''));
  v_pto      public.ptos;
begin
  if v_reason = '' then
    raise exception 'A reason for revoking is required.' using errcode = 'TA061';
  end if;

  select * into v_pto from public.ptos where id = p_pto_id for update;
  if not found then
    raise exception 'That permission could not be found.' using errcode = 'TA074';
  end if;
  if v_pto.pto_status = 'revoked' then
    raise exception 'That permission has already been revoked.' using errcode = 'TA076';
  end if;

  update public.ptos
     set pto_status = 'revoked', revoked_at = now(),
         revocation_reason = v_reason, revoked_by_staff_id = v_staff_id
   where id = v_pto.id;

  -- The allocation is not touched. Whether the land goes back is a
  -- separate, deliberate decision.
  return jsonb_build_object('pto_number', v_pto.pto_number, 'pto_status', 'revoked',
                            'revocation_reason', v_reason);
end;
$$;

-- Ends an allocation and puts the site back into circulation. Nothing
-- expires its way to a new holder: this is always a deliberate act.
create or replace function public.land_officer_release_allocation(
  p_allocation_id uuid,
  p_reason        text
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id   uuid := public.acting_land_officer_staff_id();
  v_reason     text := btrim(coalesce(p_reason, ''));
  v_allocation public.land_allocations;
  v_site       public.land_sites;
begin
  if v_reason = '' then
    raise exception 'A reason for releasing the site is required.' using errcode = 'TA061';
  end if;

  select * into v_allocation from public.land_allocations where id = p_allocation_id for update;
  if not found then
    raise exception 'That allocation could not be found.' using errcode = 'TA072';
  end if;
  if v_allocation.allocation_status not in ('active', 'succession_pending') then
    raise exception 'That allocation is already %.', v_allocation.allocation_status using errcode = 'TA072';
  end if;

  select * into v_site from public.land_sites where id = v_allocation.land_site_id for update;

  update public.land_allocations
     set allocation_status = 'released', ended_at = current_date,
         end_reason = v_reason, ended_by_staff_id = v_staff_id
   where id = v_allocation.id;

  -- Any permission still standing on it ends with it.
  update public.ptos
     set pto_status = 'superseded'
   where land_allocation_id = v_allocation.id and pto_status in ('active', 'expired');

  -- A burial plot never goes back into circulation: it stays with the
  -- household that holds it, for ever.
  if v_site.site_type = 'burial' then
    update public.land_sites set site_status = 'unavailable' where id = v_site.id;
  else
    update public.land_sites set site_status = 'available' where id = v_site.id;
  end if;

  return jsonb_build_object('allocation_reference', v_allocation.allocation_reference,
                            'allocation_status', 'released', 'site_code', v_site.site_code,
                            'site_status', (select site_status from public.land_sites where id = v_site.id));
end;
$$;

-- ---------------------------------------------------------------------
-- 15. Burial plots fill up
-- ---------------------------------------------------------------------

create or replace function public.land_officer_set_burial_status(p_site_id uuid, p_burial_status text)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare v_site public.land_sites;
begin
  perform public.acting_land_officer_staff_id();

  if p_burial_status not in ('usable', 'full', 'closed') then
    raise exception 'A burial plot is usable, full or closed.' using errcode = 'TA078';
  end if;

  select * into v_site from public.land_sites where id = p_site_id for update;
  if not found then
    raise exception 'That land site could not be found.' using errcode = 'TA066';
  end if;
  if v_site.site_type <> 'burial' then
    raise exception 'Site % is % land, not a burial plot.', v_site.site_code, v_site.site_type
      using errcode = 'TA078';
  end if;

  update public.land_sites set burial_status = p_burial_status where id = v_site.id;

  return jsonb_build_object('site_code', v_site.site_code, 'burial_status', p_burial_status);
end;
$$;

-- ---------------------------------------------------------------------
-- 16. Residential succession
--
--     A perpetual permission outlives nobody. When the holder dies the
--     allocation is flagged for review and the site stays out of reach
--     of anyone else — but TAMS chooses no heir. The Traditional
--     Authority decides, off the system, and the officer records it.
-- ---------------------------------------------------------------------

create or replace function public.tg_residential_succession_on_death()
returns trigger
language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  if new.resident_status = 'deceased' and coalesce(old.resident_status, '') <> 'deceased' then
    update public.land_allocations
       set allocation_status = 'succession_pending'
     where resident_id = new.id
       and land_type = 'residential'
       and allocation_status = 'active';
  end if;
  return null;
end;
$$;

drop trigger if exists residential_succession_on_death on public.residents;
create trigger residential_succession_on_death
  after update of resident_status on public.residents
  for each row execute function public.tg_residential_succession_on_death();

-- Who could take it on. Shown to help the officer, ranked by nothing:
-- the order is by age, and it carries no claim of entitlement.
create or replace function public.land_officer_succession_candidates(p_allocation_id uuid)
returns table (
  resident_id uuid, full_name text, id_number text, date_of_birth date, age int,
  relationship text, eligible boolean, problems jsonb
)
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_allocation public.land_allocations;
begin
  perform public.acting_land_officer_staff_id();

  select * into v_allocation from public.land_allocations where id = p_allocation_id;
  if not found then
    raise exception 'That allocation could not be found.' using errcode = 'TA072';
  end if;

  return query
    select m.id, m.first_name || ' ' || m.last_name, m.id_number, m.date_of_birth,
           extract(year from age(current_date, m.date_of_birth))::int,
           (select string_agg(distinct f.relationship_type, ', ')
              from public.family_relationships f
              where f.resident_id = v_allocation.resident_id
                and f.related_resident_id = m.id
                and f.relationship_status = 'active'),
           (public.land_eligibility(m.id, 'residential') ->> 'eligible')::boolean,
           public.land_eligibility(m.id, 'residential') -> 'problems'
    from public.residents m
    where m.household_id = v_allocation.household_id
      and m.id is distinct from v_allocation.resident_id
    order by m.date_of_birth;
end;
$$;

create or replace function public.land_officer_record_succession(
  p_allocation_id  uuid,
  p_successor_id   uuid,
  p_reason         text default null
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id     uuid := public.acting_land_officer_staff_id();
  v_allocation   public.land_allocations;
  v_successor    public.residents;
  v_new          public.land_allocations;
  v_new_pto      public.ptos;
  v_old_pto      public.ptos;
begin
  select * into v_allocation from public.land_allocations where id = p_allocation_id for update;
  if not found then
    raise exception 'That allocation could not be found.' using errcode = 'TA072';
  end if;
  if v_allocation.land_type <> 'residential' then
    raise exception 'Succession applies to residential land.' using errcode = 'TA079';
  end if;
  if v_allocation.allocation_status <> 'succession_pending' then
    raise exception 'That allocation is not waiting for succession.' using errcode = 'TA079';
  end if;

  select * into v_successor from public.residents where id = p_successor_id;
  if not found then
    raise exception 'That person is not on the village register.' using errcode = 'TA031';
  end if;

  -- The successor must already be of this household. If they are not,
  -- the Registry Clerk corrects the membership first.
  if v_successor.household_id is distinct from v_allocation.household_id then
    raise exception '% is not a member of the household that holds this site. Ask the Registry Clerk to correct the membership first.',
      v_successor.first_name || ' ' || v_successor.last_name using errcode = 'TA080';
  end if;

  -- Active, 21, and without a stand of their own already.
  if v_successor.resident_status <> 'active' then
    raise exception '% is recorded as % on the register.',
      v_successor.first_name || ' ' || v_successor.last_name, v_successor.resident_status
      using errcode = 'TA060';
  end if;
  if not public.is_at_least_age(v_successor.date_of_birth, 21) then
    raise exception '% is under 21.', v_successor.first_name || ' ' || v_successor.last_name
      using errcode = 'TA060';
  end if;
  if exists (select 1 from public.land_allocations a
              where a.resident_id = v_successor.id and a.land_type = 'residential'
                and a.allocation_status in ('active', 'succession_pending')) then
    raise exception '% already holds a residential stand. Nobody gets a second one.',
      v_successor.first_name || ' ' || v_successor.last_name using errcode = 'TA060';
  end if;

  -- The old allocation is superseded, not edited. Same site, same
  -- household, new episode.
  update public.land_allocations
     set allocation_status = 'superseded', ended_at = current_date,
         end_reason = coalesce(nullif(btrim(coalesce(p_reason, '')), ''), 'Succession recorded'),
         ended_by_staff_id = v_staff_id
   where id = v_allocation.id;

  insert into public.land_allocations (
    allocation_reference, land_site_id, resident_id, household_id, land_application_id,
    land_type, allocation_date, allocation_status, succeeds_allocation_id)
  values (
    public.next_reference('ALLOC-', 'allocation_reference', 'land_allocations', 4),
    v_allocation.land_site_id, v_successor.id, v_allocation.household_id,
    v_allocation.land_application_id, 'residential', current_date, 'active', v_allocation.id)
  returning * into v_new;

  update public.land_allocations
     set superseded_by_allocation_id = v_new.id where id = v_allocation.id;

  -- The old permission is superseded and kept; a new one is issued.
  select * into v_old_pto from public.ptos
   where land_allocation_id = v_allocation.id and pto_status in ('active', 'expired')
   order by issue_date desc limit 1;

  insert into public.ptos (
    pto_number, land_allocation_id, land_type, holder_resident_id,
    issue_date, expiry_date, pto_status, issued_by_staff_id, verification_token)
  values (
    public.next_reference('PTO-RES-', 'pto_number', 'ptos', 4),
    v_new.id, 'residential', v_successor.id, current_date, null, 'active', v_staff_id,
    encode(gen_random_bytes(16), 'hex'))
  returning * into v_new_pto;

  if v_old_pto.id is not null then
    update public.ptos
       set pto_status = 'superseded', superseded_by_pto_id = v_new_pto.id
     where id = v_old_pto.id;
  end if;

  -- The head of the household is the Registry Clerk's business and is
  -- deliberately left alone here.
  return jsonb_build_object(
    'previous_allocation', v_allocation.allocation_reference,
    'previous_pto_number', v_old_pto.pto_number,
    'allocation_reference', v_new.allocation_reference,
    'pto_number', v_new_pto.pto_number,
    'successor', v_successor.first_name || ' ' || v_successor.last_name,
    'site_code', (select site_code from public.land_sites where id = v_new.land_site_id),
    'household_id', v_new.household_id);
end;
$$;

-- When no successor exists and the Authority decides the land comes
-- back. Never automatic, always with a reason.
create or replace function public.land_officer_return_to_authority(
  p_allocation_id uuid,
  p_reason        text
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_allocation public.land_allocations;
begin
  perform public.acting_land_officer_staff_id();

  if btrim(coalesce(p_reason, '')) = '' then
    raise exception 'A reason is required to return a site to the Traditional Authority.' using errcode = 'TA061';
  end if;

  select * into v_allocation from public.land_allocations where id = p_allocation_id;
  if not found then
    raise exception 'That allocation could not be found.' using errcode = 'TA072';
  end if;
  if v_allocation.allocation_status <> 'succession_pending' then
    raise exception 'Only a site waiting for succession is returned this way.' using errcode = 'TA079';
  end if;

  return public.land_officer_release_allocation(p_allocation_id, p_reason);
end;
$$;

-- ---------------------------------------------------------------------
-- 17. What a resident sees of their own land
-- ---------------------------------------------------------------------

create or replace function public.resident_land_portal()
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare
  v_resident_id uuid := public.current_resident_id();
  v_household_id uuid;
  v_is_head boolean;
begin
  if v_resident_id is null then
    raise exception 'Only a verified resident may see this.' using errcode = '42501';
  end if;

  select r.household_id, (h.head_resident_id = r.id)
    into v_household_id, v_is_head
  from public.residents r
  left join public.households h on h.id = r.household_id
  where r.id = v_resident_id;

  return jsonb_build_object(
    'resident_id',       v_resident_id,
    'household_id',      v_household_id,
    'is_household_head', coalesce(v_is_head, false),
    'eligibility', jsonb_build_object(
      'residential', public.land_eligibility(v_resident_id, 'residential'),
      'farming',     public.land_eligibility(v_resident_id, 'farming'),
      'business',    public.land_eligibility(v_resident_id, 'business'),
      'burial',      public.land_eligibility(v_resident_id, 'burial')),
    'applications', coalesce((
      select jsonb_agg(jsonb_build_object(
               'application_reference', a.application_reference,
               'land_type',             a.land_type,
               'application_status',    a.application_status,
               'submitted_at',          a.submitted_at,
               'decline_reason',        a.decline_reason)
             order by a.submitted_at desc)
      from public.land_applications a
      where a.applicant_resident_id = v_resident_id
         or (a.land_type in ('farming', 'burial') and coalesce(v_is_head, false)
             and a.household_id = v_household_id)), '[]'::jsonb),
    'allocations', coalesce((
      select jsonb_agg(jsonb_build_object(
               'allocation_reference', al.allocation_reference,
               'land_type',            al.land_type,
               'site_code',            s.site_code,
               'street_address',       s.street_address,
               'village_section',      s.village_section,
               'allocation_status',    al.allocation_status,
               'allocation_date',      al.allocation_date,
               'burial_status',        s.burial_status)
             order by al.allocation_date desc)
      from public.land_allocations al
      join public.land_sites s on s.id = al.land_site_id
      where al.allocation_status in ('active', 'succession_pending')
        and (al.resident_id = v_resident_id
             or (al.land_type in ('farming', 'burial') and coalesce(v_is_head, false)
                 and al.household_id = v_household_id))), '[]'::jsonb),
    'ptos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'pto_id',            p.id,
               'pto_number',        p.pto_number,
               'land_type',         p.land_type,
               'site_code',         s.site_code,
               'issue_date',        p.issue_date,
               'expiry_date',       p.expiry_date,
               'perpetual',         (p.expiry_date is null),
               'effective_status',  public.pto_effective_status(p.pto_status, p.expiry_date),
               'verification_token', p.verification_token,
               'renewable',         (p.land_type in ('farming', 'business')
                                     and public.pto_effective_status(p.pto_status, p.expiry_date) in ('active', 'expired')),
               'renewal_pending',   exists (select 1 from public.pto_renewal_requests q
                                             where q.pto_id = p.id and q.request_status = 'pending'))
             order by p.issue_date desc)
      from public.ptos p
      join public.land_allocations al on al.id = p.land_allocation_id
      join public.land_sites s on s.id = al.land_site_id
      where p.holder_resident_id = v_resident_id
         or (coalesce(v_is_head, false) and p.holder_household_id = v_household_id)), '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------
-- 18. What the Land Officer sees
-- ---------------------------------------------------------------------

create or replace function public.land_officer_dashboard()
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
begin
  perform public.acting_land_officer_staff_id();
  return jsonb_build_object(
    'pending_applications',    (select count(*) from public.land_applications where application_status = 'pending'),
    'awaiting_allocation',     (select count(*) from public.land_applications where application_status = 'approved'),
    'available_sites',         (select count(*) from public.land_sites where site_status = 'available'),
    'active_allocations',      (select count(*) from public.land_allocations where allocation_status = 'active'),
    'succession_pending',      (select count(*) from public.land_allocations where allocation_status = 'succession_pending'),
    'active_ptos',             (select count(*) from public.ptos
                                 where public.pto_effective_status(pto_status, expiry_date) = 'active'),
    'expired_ptos',            (select count(*) from public.ptos
                                 where public.pto_effective_status(pto_status, expiry_date) = 'expired'),
    'pending_renewals',        (select count(*) from public.pto_renewal_requests where request_status = 'pending'),
    'burial_plots_usable',     (select count(*) from public.land_sites
                                 where site_type = 'burial' and burial_status = 'usable'));
end;
$$;

create or replace function public.land_officer_sites(p_search text default null, p_site_type text default null)
returns table (
  site_id uuid, site_code text, site_type text, site_status text, burial_status text,
  stand_number text, street_address text, village_section text, village_name text,
  current_holder text, allocation_count bigint
)
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_pattern text := public.like_pattern(p_search);
        v_empty boolean := coalesce(btrim(p_search), '') = '';
begin
  perform public.acting_land_officer_staff_id();
  return query
    select s.id, s.site_code, s.site_type, s.site_status, s.burial_status,
           s.stand_number, s.street_address, s.village_section, s.village_name,
           (select coalesce(r.first_name || ' ' || r.last_name, h.household_code)
              from public.land_allocations a
              left join public.residents r on r.id = a.resident_id
              left join public.households h on h.id = a.household_id
              where a.land_site_id = s.id and a.allocation_status in ('active', 'succession_pending')
              limit 1),
           (select count(*) from public.land_allocations a where a.land_site_id = s.id)
    from public.land_sites s
    where (p_site_type is null or s.site_type = p_site_type)
      and (v_empty or s.site_code ilike v_pattern or s.street_address ilike v_pattern
           or coalesce(s.stand_number, '') ilike v_pattern)
    order by s.site_code;
end;
$$;

-- Everything that ever happened to one site.
create or replace function public.land_officer_site_history(p_site_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_result jsonb;
begin
  perform public.acting_land_officer_staff_id();

  select jsonb_build_object(
    'site_id', s.id, 'site_code', s.site_code, 'site_type', s.site_type,
    'site_status', s.site_status, 'burial_status', s.burial_status,
    'stand_number', s.stand_number, 'street_address', s.street_address,
    'village_section', s.village_section, 'village_name', s.village_name,
    'allocations', coalesce((
      select jsonb_agg(jsonb_build_object(
               'allocation_id',        a.id,
               'allocation_reference', a.allocation_reference,
               'land_type',            a.land_type,
               'allocation_status',    a.allocation_status,
               'allocation_date',      a.allocation_date,
               'ended_at',             a.ended_at,
               'end_reason',           a.end_reason,
               'holder', coalesce(r.first_name || ' ' || r.last_name, '(household)'),
               'household_code', h.household_code,
               'application_reference', app.application_reference,
               'succeeds', (select prev.allocation_reference from public.land_allocations prev
                             where prev.id = a.succeeds_allocation_id),
               'ptos', coalesce((select jsonb_agg(jsonb_build_object(
                          'pto_number', p.pto_number,
                          'issue_date', p.issue_date,
                          'expiry_date', p.expiry_date,
                          'stored_status', p.pto_status,
                          'effective_status', public.pto_effective_status(p.pto_status, p.expiry_date),
                          'revocation_reason', p.revocation_reason)
                        order by p.issue_date)
                        from public.ptos p where p.land_allocation_id = a.id), '[]'::jsonb))
             order by a.allocation_date desc)
      from public.land_allocations a
      left join public.residents r on r.id = a.resident_id
      left join public.households h on h.id = a.household_id
      left join public.land_applications app on app.id = a.land_application_id
      where a.land_site_id = s.id), '[]'::jsonb)
  ) into v_result
  from public.land_sites s where s.id = p_site_id;

  if v_result is null then
    raise exception 'That land site could not be found.' using errcode = 'TA066';
  end if;
  return v_result;
end;
$$;

create or replace function public.land_officer_ptos(p_search text default null, p_status text default null)
returns table (
  pto_id uuid, pto_number text, land_type text, site_code text,
  holder_name text, household_code text, issue_date date, expiry_date date,
  stored_status text, effective_status text, allocation_id uuid, allocation_status text
)
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_pattern text := public.like_pattern(p_search);
        v_empty boolean := coalesce(btrim(p_search), '') = '';
begin
  perform public.acting_land_officer_staff_id();
  return query
    select p.id, p.pto_number, p.land_type, s.site_code,
           r.first_name || ' ' || r.last_name, h.household_code,
           p.issue_date, p.expiry_date, p.pto_status,
           public.pto_effective_status(p.pto_status, p.expiry_date),
           a.id, a.allocation_status
    from public.ptos p
    join public.land_allocations a on a.id = p.land_allocation_id
    join public.land_sites s on s.id = a.land_site_id
    left join public.residents r on r.id = p.holder_resident_id
    left join public.households h on h.id = p.holder_household_id
    where (p_status is null or public.pto_effective_status(p.pto_status, p.expiry_date) = p_status)
      and (v_empty or p.pto_number ilike v_pattern or s.site_code ilike v_pattern
           or coalesce(h.household_code, '') ilike v_pattern
           or coalesce(r.first_name || ' ' || r.last_name, '') ilike v_pattern)
    order by p.issue_date desc;
end;
$$;

-- Every allocation, past and present. The Allocations screen and the
-- succession screen are both this list, filtered.
create or replace function public.land_officer_allocations(
  p_status    text default 'active',
  p_land_type text default null,
  p_search    text default null
)
returns table (
  allocation_id uuid, allocation_reference text, land_type text,
  site_id uuid, site_code text, street_address text, village_section text,
  burial_status text, holder_resident_id uuid, holder_name text,
  household_id uuid, household_code text,
  allocation_status text, allocation_date date, ended_at date, end_reason text,
  pto_id uuid, pto_number text, pto_expiry_date date, pto_effective_status text
)
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_pattern text := public.like_pattern(p_search);
        v_empty boolean := coalesce(btrim(p_search), '') = '';
begin
  perform public.acting_land_officer_staff_id();
  return query
    select a.id, a.allocation_reference, a.land_type,
           s.id, s.site_code, s.street_address, s.village_section, s.burial_status,
           a.resident_id, r.first_name || ' ' || r.last_name,
           a.household_id, h.household_code,
           a.allocation_status, a.allocation_date, a.ended_at, a.end_reason,
           p.id, p.pto_number, p.expiry_date,
           public.pto_effective_status(p.pto_status, p.expiry_date)
    from public.land_allocations a
    join public.land_sites s on s.id = a.land_site_id
    left join public.residents r on r.id = a.resident_id
    left join public.households h on h.id = a.household_id
    -- The permission that is current for this allocation, if there is one.
    left join lateral (
      select p2.* from public.ptos p2
       where p2.land_allocation_id = a.id
         and p2.pto_status in ('active', 'expired')
       order by p2.issue_date desc, p2.created_at desc
       limit 1) p on true
    where (p_status is null or a.allocation_status = p_status)
      and (p_land_type is null or a.land_type = p_land_type)
      and (v_empty
           or a.allocation_reference ilike v_pattern
           or s.site_code ilike v_pattern
           or coalesce(h.household_code, '') ilike v_pattern
           or coalesce(r.first_name || ' ' || r.last_name, '') ilike v_pattern)
    order by a.allocation_date desc, a.allocation_reference desc;
end;
$$;

-- ---------------------------------------------------------------------
-- 19. The permission document, and verifying one
--
--     The document carries what a permission has to show and nothing
--     about the person beyond their name. No identity number, no date
--     of birth, no contact details.
-- ---------------------------------------------------------------------

create or replace function public.pto_document(p_pto_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare
  v_result jsonb;
  v_allowed boolean;
begin
  select
    public.is_active_land_officer()
    or p.holder_resident_id = public.current_resident_id()
    or exists (select 1 from public.households h
                where h.id = p.holder_household_id and h.head_resident_id = public.current_resident_id())
  into v_allowed
  from public.ptos p where p.id = p_pto_id;

  if not coalesce(v_allowed, false) then
    raise exception 'That permission to occupy is not yours to view.' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'pto_number',      p.pto_number,
    'land_type',       p.land_type,
    'holder_name',     coalesce(r.first_name || ' ' || r.last_name, 'Household ' || h.household_code),
    'household_code',  h.household_code,
    'site_code',       s.site_code,
    'stand_number',    s.stand_number,
    'street_address',  s.street_address,
    'village_section', s.village_section,
    'village_name',    s.village_name,
    'issue_date',      p.issue_date,
    'expiry_date',     p.expiry_date,
    'perpetual',       (p.expiry_date is null),
    'effective_status', public.pto_effective_status(p.pto_status, p.expiry_date),
    'verification_token', p.verification_token
  ) into v_result
  from public.ptos p
  join public.land_allocations a on a.id = p.land_allocation_id
  join public.land_sites s on s.id = a.land_site_id
  left join public.residents r on r.id = p.holder_resident_id
  left join public.households h on h.id = p.holder_household_id
  where p.id = p_pto_id;

  return v_result;
end;
$$;

-- Public. Anyone holding the printed document can check it is real.
-- It answers with enough to establish authenticity and nothing more:
-- no identity number, no birth date, no contact details, no internal
-- identifiers.
create or replace function public.verify_pto(p_token text)
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_result jsonb;
begin
  if coalesce(btrim(p_token), '') = '' then
    return jsonb_build_object('found', false);
  end if;

  select jsonb_build_object(
    'found',           true,
    'pto_number',      p.pto_number,
    'land_type',       p.land_type,
    'holder_name',     coalesce(r.first_name || ' ' || r.last_name, 'Household ' || h.household_code),
    'site_code',       s.site_code,
    'village_section', s.village_section,
    'village_name',    s.village_name,
    'issue_date',      p.issue_date,
    'expiry_date',     p.expiry_date,
    'perpetual',       (p.expiry_date is null),
    'status',          public.pto_effective_status(p.pto_status, p.expiry_date)
  ) into v_result
  from public.ptos p
  join public.land_allocations a on a.id = p.land_allocation_id
  join public.land_sites s on s.id = a.land_site_id
  left join public.residents r on r.id = p.holder_resident_id
  left join public.households h on h.id = p.holder_household_id
  where p.verification_token = btrim(p_token);

  return coalesce(v_result, jsonb_build_object('found', false));
end;
$$;

-- ---------------------------------------------------------------------
-- 20. Grants
--
--     Each function establishes its own caller, so execute may be given
--     to signed-in users; the functions turn away anyone who should not
--     be there. Verification is the one public one.
-- ---------------------------------------------------------------------

do $$
declare v_signature text;
begin
  foreach v_signature in array array[
    'public.is_active_land_officer()',
    'public.is_at_least_age(date, int)',
    'public.pto_effective_status(text, date)',
    'public.pto_term_end(text, date)',
    'public.allocatable_land_types()',
    'public.current_resident_id()',
    'public.current_resident_headed_household_ids()',
    'public.land_eligibility(uuid, text)',
    'public.resident_land_eligibility(text)',
    'public.resident_submit_land_application(text, jsonb)',
    'public.resident_land_portal()',
    'public.resident_request_pto_renewal(uuid, text)',
    'public.pto_document(uuid)',
    'public.land_officer_register_site(text, text, text, text, text, text)',
    'public.land_officer_update_site(uuid, text, text, text, text, text, text)',
    'public.land_officer_applications(text, text, text)',
    'public.land_officer_application(uuid)',
    'public.land_officer_approve_application(uuid)',
    'public.land_officer_decline_application(uuid, text)',
    'public.land_officer_available_sites(text)',
    'public.land_officer_allocate_site(uuid, uuid)',
    'public.land_officer_issue_pto(uuid)',
    'public.land_officer_renewal_requests(text)',
    'public.land_officer_approve_renewal(uuid)',
    'public.land_officer_decline_renewal(uuid, text)',
    'public.land_officer_revoke_pto(uuid, text)',
    'public.land_officer_release_allocation(uuid, text)',
    'public.land_officer_set_burial_status(uuid, text)',
    'public.land_officer_succession_candidates(uuid)',
    'public.land_officer_record_succession(uuid, uuid, text)',
    'public.land_officer_return_to_authority(uuid, text)',
    'public.land_officer_dashboard()',
    'public.land_officer_sites(text, text)',
    'public.land_officer_site_history(uuid)',
    'public.land_officer_ptos(text, text)',
    'public.land_officer_allocations(text, text, text)'
  ]
  loop
    execute format('revoke all on function %s from public, anon, authenticated', v_signature);
    execute format('grant execute on function %s to authenticated', v_signature);
  end loop;
end;
$$;

revoke all on function public.acting_land_officer_staff_id() from public, anon, authenticated;
revoke all on function public.next_reference(text, text, text, int) from public, anon, authenticated;

-- Verification is meant to be usable by anybody holding the document.
revoke all on function public.verify_pto(text) from public;
grant execute on function public.verify_pto(text) to anon, authenticated;
