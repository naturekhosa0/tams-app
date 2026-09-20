-- =====================================================================
-- TAMS — family relationships that have a history
--
-- Some relationships are permanent lineage and some are episodes in a
-- life. A father who dies is still his child's father; a marriage can
-- end, and the same two people can marry again years later.
--
--   PERMANENT   parent ↔ child, sibling ↔ sibling,
--               grandparent ↔ grandchild
--               These are never ended through the application.
--
--   TIME-BASED  spouse ↔ spouse, guardian ↔ dependant
--               These begin, end, and may begin again as a NEW episode.
--               The earlier episode is kept exactly as it was.
--
-- The 200 imported relationships are untouched: they keep their rows,
-- their types and their active status, and simply have no dates,
-- because the historical dates are not known.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. When a relationship began and ended
-- ---------------------------------------------------------------------

alter table public.family_relationships
  add column if not exists relationship_started_at date,
  add column if not exists relationship_ended_at   date;

comment on column public.family_relationships.relationship_started_at is
  'When this episode began. Null on the imported relationships, whose dates are not known.';
comment on column public.family_relationships.relationship_ended_at is
  'When this episode ended. Only ever set on an inactive, time-based relationship.';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'family_relationships_dates_ordered') then
    alter table public.family_relationships
      add constraint family_relationships_dates_ordered check (
        relationship_ended_at is null
        or relationship_started_at is null
        or relationship_ended_at >= relationship_started_at
      );
  end if;

  -- A relationship that is still current cannot have ended.
  if not exists (select 1 from pg_constraint where conname = 'family_relationships_active_has_not_ended') then
    alter table public.family_relationships
      add constraint family_relationships_active_has_not_ended check (
        relationship_status <> 'active' or relationship_ended_at is null
      );
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 2. Uniqueness now applies to CURRENT relationships only
--
--    The old rule forbade the same triple outright, which would have
--    made a remarriage impossible to record. What must never happen is
--    two simultaneous current relationships of the same kind between
--    the same two people, in the same direction.
-- ---------------------------------------------------------------------

alter table public.family_relationships
  drop constraint if exists family_relationships_unique;

create unique index if not exists family_relationships_one_current_idx
  on public.family_relationships (resident_id, related_resident_id, relationship_type)
  where relationship_status = 'active';

-- ---------------------------------------------------------------------
-- 3. Which relationships have episodes
-- ---------------------------------------------------------------------

create or replace function public.is_time_based_relationship(p_type text)
returns boolean
language sql
immutable
as $$
  select p_type in ('spouse', 'guardian', 'dependant');
$$;

comment on function public.is_time_based_relationship(text) is
  'True for relationships that begin and end. The rest are permanent lineage.';

-- ---------------------------------------------------------------------
-- 4. Recording a relationship
--
--    Replaces the earlier version. A time-based relationship must say
--    when it began; permanent lineage need not.
-- ---------------------------------------------------------------------

create or replace function public.registry_record_family_relationship(
  p_resident_id         uuid,
  p_related_resident_id uuid,
  p_relationship_type   text,
  p_started_at          date default null
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

  -- A marriage or a guardianship is an episode, so it has to say when
  -- it started. Lineage simply is.
  if public.is_time_based_relationship(p_relationship_type) and p_started_at is null then
    raise exception 'A % relationship must say when it began.', p_relationship_type
      using errcode = 'TA049';
  end if;

  select * into v_resident from public.residents where id = p_resident_id;
  if not found then
    raise exception 'That resident could not be found.' using errcode = 'TA031';
  end if;

  select * into v_related from public.residents where id = p_related_resident_id;
  if not found then
    raise exception 'The related resident could not be found.' using errcode = 'TA031';
  end if;

  -- Only a CURRENT one of the same kind is a duplicate. An earlier
  -- episode that has ended is history, and history is allowed to repeat.
  if exists (select 1 from public.family_relationships f
              where f.resident_id = p_resident_id
                and f.related_resident_id = p_related_resident_id
                and f.relationship_type = p_relationship_type
                and f.relationship_status = 'active') then
    raise exception '% is already recorded as the current % of %.',
      v_resident.first_name || ' ' || v_resident.last_name, p_relationship_type,
      v_related.first_name || ' ' || v_related.last_name
      using errcode = 'TA043';
  end if;

  insert into public.family_relationships
    (resident_id, related_resident_id, relationship_type, relationship_status, relationship_started_at)
  values (p_resident_id, p_related_resident_id, p_relationship_type, 'active', p_started_at);
  get diagnostics v_added = row_count;

  -- The other side of the same fact, with the same starting date.
  insert into public.family_relationships
    (resident_id, related_resident_id, relationship_type, relationship_status, relationship_started_at)
  values (p_related_resident_id, p_resident_id, v_inverse, 'active', p_started_at)
  on conflict (resident_id, related_resident_id, relationship_type)
    where relationship_status = 'active'
  do nothing;
  get diagnostics v_inverse_added = row_count;

  return jsonb_build_object(
    'resident',          v_resident.first_name || ' ' || v_resident.last_name,
    'related_resident',  v_related.first_name || ' ' || v_related.last_name,
    'relationship_type', p_relationship_type,
    'inverse_type',      v_inverse,
    'started_at',        p_started_at,
    'time_based',        public.is_time_based_relationship(p_relationship_type),
    'recorded',          v_added,
    'inverse_recorded',  v_inverse_added);
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Ending a time-based relationship
--
--    Ends this episode and the matching one the other way round. The
--    rows stay exactly where they are: a divorce is recorded, never
--    erased. Permanent lineage cannot be ended here at all.
-- ---------------------------------------------------------------------

create or replace function public.registry_end_family_relationship(
  p_relationship_id uuid,
  p_ended_at        date
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_relationship public.family_relationships;
  v_inverse      text;
  v_ended        int := 0;
begin
  perform public.require_registry_clerk();

  select * into v_relationship
  from public.family_relationships where id = p_relationship_id for update;
  if not found then
    raise exception 'That relationship could not be found.' using errcode = 'TA031';
  end if;

  if not public.is_time_based_relationship(v_relationship.relationship_type) then
    raise exception 'A % relationship is permanent and is not ended. A parent remains a parent.',
      v_relationship.relationship_type
      using errcode = 'TA046';
  end if;

  if v_relationship.relationship_status <> 'active' then
    raise exception 'That relationship has already ended.' using errcode = 'TA047';
  end if;

  if p_ended_at is null then
    raise exception 'An end date is required.' using errcode = 'TA048';
  end if;

  if v_relationship.relationship_started_at is not null
     and p_ended_at < v_relationship.relationship_started_at then
    raise exception 'The relationship cannot end on % because it began on %.',
      p_ended_at, v_relationship.relationship_started_at
      using errcode = 'TA048';
  end if;

  v_inverse := public.inverse_relationship_type(v_relationship.relationship_type);

  update public.family_relationships
     set relationship_status = 'inactive',
         relationship_ended_at = p_ended_at
   where id = v_relationship.id;
  get diagnostics v_ended = row_count;

  -- The same episode seen from the other side.
  update public.family_relationships
     set relationship_status = 'inactive',
         relationship_ended_at = p_ended_at
   where resident_id = v_relationship.related_resident_id
     and related_resident_id = v_relationship.resident_id
     and relationship_type = v_inverse
     and relationship_status = 'active';

  return jsonb_build_object(
    'relationship_id',   v_relationship.id,
    'relationship_type', v_relationship.relationship_type,
    'ended_at',          p_ended_at,
    'ended',             v_ended);
end;
$$;

-- The old catch-all is gone: it let permanent lineage be retired, which
-- is exactly what must not happen.
drop function if exists public.registry_set_relationship_status(uuid, text);

-- ---------------------------------------------------------------------
-- 6. Lineage, now with its dates
-- ---------------------------------------------------------------------

drop function if exists public.registry_family_lineage(uuid);

create function public.registry_family_lineage(p_resident_id uuid)
returns table (
  relationship_id         uuid,
  relationship_type       text,
  relationship_status     text,
  relationship_started_at date,
  relationship_ended_at   date,
  time_based              boolean,
  related_resident_id     uuid,
  related_full_name       text,
  related_id_number       text,
  related_status          text,
  related_household_code  text
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
           f.relationship_started_at, f.relationship_ended_at,
           public.is_time_based_relationship(f.relationship_type),
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
        when 'child' then 1 when 'parent' then 2 when 'sibling' then 3
        when 'grandchild' then 4 when 'grandparent' then 5
        when 'spouse' then 6 when 'dependant' then 7 else 8 end,
      f.relationship_status,
      f.relationship_started_at desc nulls last,
      other.last_name, other.first_name;
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Grants
-- ---------------------------------------------------------------------

do $$
declare
  v_signature text;
begin
  foreach v_signature in array array[
    'public.is_time_based_relationship(text)',
    'public.registry_family_lineage(uuid)',
    'public.registry_record_family_relationship(uuid, uuid, text, date)',
    'public.registry_end_family_relationship(uuid, date)'
  ]
  loop
    execute format('revoke all on function %s from public, anon, authenticated', v_signature);
    execute format('grant execute on function %s to authenticated', v_signature);
  end loop;
end;
$$;

-- The three-argument form was replaced by the one that takes a date.
drop function if exists public.registry_record_family_relationship(uuid, uuid, text);
