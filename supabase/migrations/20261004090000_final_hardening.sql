-- =====================================================================
-- Final hardening pass.
--
-- Two findings from the whole-schema security review, and one thing
-- deliberately left as it is.
--
-- 1. Trigger functions were still executable by PUBLIC.
--
--    Every ordinary function in TAMS has its EXECUTE revoked from
--    public, anon and authenticated and then granted back only to
--    authenticated. The trigger functions were never put through that,
--    because they are never called by name — so they kept PostgreSQL's
--    default, which is EXECUTE to PUBLIC.
--
--    PostgreSQL refuses to run a `returns trigger` function called
--    directly, so this was not a way in. It was an inconsistency in a
--    schema whose whole defence is that the privileges are uniform and
--    can be read off in one query. Now they are.
--
-- 2. audit_logs is intentionally NOT `force row level security`.
--
--    Every other table is forced. This one must not be, and the reason
--    is worth writing down so nobody "fixes" it later:
--
--      * audit_logs is written only by security definer functions
--        owned by the schema owner. FORCE makes the owner subject to
--        the policies too, and there is deliberately no INSERT policy —
--        so forcing it would silently stop the system auditing itself.
--      * Nothing is lost. `authenticated` is never the owner, holds no
--        INSERT, UPDATE or DELETE grant on the table, and is fully
--        subject to audit_logs_administrator_reads.
--      * Immutability does not come from RLS at all. It comes from
--        tg_audit_logs_are_immutable, which raises on any update or
--        delete whoever attempts it.
--
--    The supabase/tests suite pins all three of those properties, so
--    the reasoning is checked rather than merely asserted here.
-- =====================================================================

do $$
declare
  v_signature text;
begin
  for v_signature in
    select p.oid::regprocedure::text
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      join pg_type t on t.oid = p.prorettype
     where n.nspname = 'public'
       and t.typname = 'trigger'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', v_signature);
  end loop;
end;
$$;


-- =====================================================================
-- 3. An audited change must name only what actually changed.
--
--    audit_event() is the hand-written path: the few events that are
--    not a row being written, such as an administrator transfer. It
--    filled changed_fields with every key of the new side, whether or
--    not that key existed on the old side and whether or not its value
--    had moved.
--
--    The trigger path has always computed a real diff. This makes the
--    hand-written path agree with it, so the Council Administrator
--    reading the trail sees the same thing either way:
--
--      * both sides given  -> the keys whose values genuinely differ,
--                             across the union of the two sides, so a
--                             field that only appears on one side still
--                             counts as having moved;
--      * only the new side -> a creation: everything arrived, nothing
--                             moved, which is what the trigger records
--                             for an INSERT too.
--
--    Nothing that was already written changes. audit_logs is insert
--    only, and history is not ours to correct.
-- =====================================================================

create or replace function public.audit_event(
  p_action     text,
  p_entity     text,
  p_entity_id  uuid default null,
  p_reference  text default null,
  p_old        jsonb default null,
  p_new        jsonb default null,
  p_reason     text default null
)
returns uuid
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_actor   jsonb := public.audit_actor();
  v_group   uuid := nullif(public.audit_context_value('tams.audit_group'), '')::uuid;
  v_old     jsonb := public.audit_strip(p_old);
  v_new     jsonb := public.audit_strip(p_new);
  v_changed text[];
  v_id      uuid;
begin
  if p_new is null then
    v_changed := null;
  elsif p_old is null then
    -- A creation. Everything on the new side arrived at once.
    select coalesce(array_agg(k order by k), '{}') into v_changed
      from jsonb_object_keys(v_new) as k;
  else
    -- A change. Only what moved, judged over both sides together.
    select coalesce(array_agg(k order by k), '{}') into v_changed
      from (select jsonb_object_keys(v_old) as k
            union
            select jsonb_object_keys(v_new)) as keys
     where v_old -> k is distinct from v_new -> k;
  end if;

  insert into public.audit_logs (
    actor_user_id, actor_staff_id, actor_role, actor_account_type, actor_label,
    action, entity_type, entity_id, entity_reference,
    old_values, new_values, changed_fields, reason, event_group_id)
  values (
    nullif(v_actor ->> 'actor_user_id', '')::uuid,
    nullif(v_actor ->> 'actor_staff_id', '')::uuid,
    v_actor ->> 'actor_role', v_actor ->> 'actor_account_type', v_actor ->> 'actor_label',
    p_action, p_entity, p_entity_id, p_reference,
    case when p_old is null then null else v_old end,
    case when p_new is null then null else v_new end,
    v_changed,
    nullif(btrim(coalesce(p_reason, '')), ''),
    v_group)
  returning id into v_id;
  return v_id;
end;
$$;

revoke all on function public.audit_event(text, text, uuid, text, jsonb, jsonb, text)
  from public, anon, authenticated;


-- =====================================================================
-- 4. The two hand-written events now read as a real before and after.
--
--    Administrator transfer and emergency recovery each built their own
--    old and new objects, and the two sides carried different keys. The
--    Council Administrator reading the trail saw four fields whose
--    "from" column was empty, and one whose "to" column was, for an
--    event where every one of those facts genuinely has both.
--
--    Two of the fields were not a before-and-after at all: performed_by
--    and performed_by_role repeated the actor, which every audit row
--    already records in its own columns.
--
--    Only the payloads change. Neither function's behaviour, checks or
--    return value moves, and nothing already written is touched.
-- =====================================================================

create or replace function public.transfer_council_administrator(
  p_incoming_staff_id  uuid,
  p_outgoing_outcome   text,      -- 'remain_staff' or 'deactivate'
  p_reason             text,
  p_outgoing_role_id   uuid default null
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_outgoing_staff_id uuid := public.acting_council_administrator_staff_id();
  v_reason  text := btrim(coalesce(p_reason, ''));
  v_outgoing public.staff;
  v_incoming public.staff;
  v_outgoing_account public.user_accounts;
  v_incoming_account public.user_accounts;
  v_incoming_role public.roles;
  v_outgoing_new_role public.roles;
  v_admin_role_id uuid := public.council_administrator_role_id();
  v_group uuid;
begin
  if v_reason = '' then
    raise exception 'A reason for the transfer is required.' using errcode = 'TA130';
  end if;
  if length(v_reason) > 500 then
    raise exception 'The reason is too long (500 characters at most).' using errcode = 'TA130';
  end if;
  if p_outgoing_outcome is null or p_outgoing_outcome not in ('remain_staff', 'deactivate') then
    raise exception 'Say what becomes of the outgoing administrator: remain as staff, or be deactivated.'
      using errcode = 'TA131';
  end if;

  select * into v_outgoing from public.staff where id = v_outgoing_staff_id for update;
  select * into v_outgoing_account from public.user_accounts where staff_id = v_outgoing.id for update;

  -- ---- the incoming administrator ---------------------------------
  if p_incoming_staff_id is null or p_incoming_staff_id = v_outgoing_staff_id then
    raise exception 'Choose a different staff member to transfer to.' using errcode = 'TA132';
  end if;

  select * into v_incoming from public.staff where id = p_incoming_staff_id for update;
  if not found then
    raise exception 'That staff member could not be found.' using errcode = 'TA132';
  end if;

  select * into v_incoming_role from public.roles where id = v_incoming.role_id;
  if v_incoming_role.role_name = 'Council Administrator' then
    raise exception 'That staff member already holds the Council Administrator role.'
      using errcode = 'TA132';
  end if;
  if v_incoming_role.role_name not in ('Registry Clerk', 'Land Officer', 'Council Secretary') then
    raise exception 'The incoming administrator must currently hold an ordinary staff role.'
      using errcode = 'TA132';
  end if;

  select * into v_incoming_account from public.user_accounts where staff_id = v_incoming.id for update;
  if not found or v_incoming_account.account_type <> 'staff' then
    raise exception 'That staff member has no staff account.' using errcode = 'TA133';
  end if;
  if v_incoming_account.account_status <> 'active' then
    raise exception 'That staff member''s account is deactivated, so they cannot take over.'
      using errcode = 'TA133';
  end if;
  if not exists (select 1 from auth.users u where u.id = v_incoming_account.auth_user_id) then
    raise exception 'That staff member has no sign-in identity, so they cannot take over.'
      using errcode = 'TA133';
  end if;

  -- ---- what becomes of the outgoing one ---------------------------
  if p_outgoing_outcome = 'remain_staff' then
    select * into v_outgoing_new_role from public.roles where id = p_outgoing_role_id;
    if not found then
      raise exception 'Choose the ordinary role the outgoing administrator will hold.'
        using errcode = 'TA134';
    end if;
    if v_outgoing_new_role.role_name not in ('Registry Clerk', 'Land Officer', 'Council Secretary') then
      raise exception 'The outgoing administrator must take one of the three ordinary roles.'
        using errcode = 'TA134';
    end if;
  end if;

  -- ---- the handover, in order -------------------------------------
  --      The outgoing administrator stops being one first, so there is
  --      never an instant with two.
  v_group := public.audit_context('TRANSFER_COUNCIL_ADMINISTRATOR', v_reason, null);

  -- The actor's role is recorded now, before it changes, so the trail
  -- shows who they were when they did this.
  perform public.audit_event(
    'TRANSFER_COUNCIL_ADMINISTRATOR', 'staff', v_incoming.id, v_incoming.employee_number,
    -- Both sides describe the same four facts, so the trail reads as a
    -- genuine before and after. Who performed the transfer is not
    -- repeated here: the audit row already records the actor.
    jsonb_build_object(
      'administrator',                 v_outgoing.first_name || ' ' || v_outgoing.last_name,
      'administrator_employee_number', v_outgoing.employee_number,
      'incoming_administrator_role',   v_incoming_role.role_name,
      'outgoing_administrator_role',   'Council Administrator'),
    jsonb_build_object(
      'administrator',                 v_incoming.first_name || ' ' || v_incoming.last_name,
      'administrator_employee_number', v_incoming.employee_number,
      'incoming_administrator_role',   'Council Administrator',
      'outgoing_administrator_role',   case when p_outgoing_outcome = 'remain_staff'
                                            then v_outgoing_new_role.role_name
                                            else 'deactivated' end),
    v_reason);

  if p_outgoing_outcome = 'remain_staff' then
    update public.staff set role_id = v_outgoing_new_role.id where id = v_outgoing.id;
  else
    -- The role is left as it was: they were the administrator, and the
    -- record should keep saying so. What stops them acting is the
    -- account, which is the single source of truth for access.
    update public.user_accounts set account_status = 'deactivated' where id = v_outgoing_account.id;
    update public.staff
       set last_deactivated_at = now(),
           last_deactivated_by_staff_id = v_outgoing.id,
           last_deactivation_reason = 'Administrator transfer: ' || v_reason
     where id = v_outgoing.id;
  end if;

  update public.staff set role_id = v_admin_role_id where id = v_incoming.id;

  -- ---- exactly one, or none of this happened ----------------------
  if public.active_council_administrator_count() <> 1 then
    raise exception 'The transfer would not have left exactly one active Council Administrator.'
      using errcode = 'TA135';
  end if;

  -- ---- telling both of them ---------------------------------------
  perform public.notify_user(
    public.staff_account_id(v_incoming.id), 'administration',
    'You are now the Council Administrator',
    v_outgoing.first_name || ' ' || v_outgoing.last_name ||
    ' has transferred the Council Administrator role to you. Reason: ' || v_reason ||
    '. You now manage staff accounts and can read the audit trail.',
    '/dashboard', 'staff', v_incoming.id, v_incoming.employee_number);

  if p_outgoing_outcome = 'remain_staff' then
    perform public.notify_user(
      public.staff_account_id(v_outgoing.id), 'administration',
      'You are no longer the Council Administrator',
      'The Council Administrator role has been transferred to ' ||
      v_incoming.first_name || ' ' || v_incoming.last_name ||
      '. You now hold the ' || v_outgoing_new_role.role_name || ' role. Reason: ' || v_reason || '.',
      '/home', 'staff', v_outgoing.id, v_outgoing.employee_number);
  end if;

  return jsonb_build_object(
    'event_group_id',     v_group,
    'outgoing_name',      v_outgoing.first_name || ' ' || v_outgoing.last_name,
    'outgoing_outcome',   p_outgoing_outcome,
    'outgoing_new_role',  case when p_outgoing_outcome = 'remain_staff'
                               then v_outgoing_new_role.role_name else null end,
    'incoming_name',      v_incoming.first_name || ' ' || v_incoming.last_name,
    'incoming_previous_role', v_incoming_role.role_name,
    'active_administrators', public.active_council_administrator_count(),
    'reason',             v_reason);
end;
$$;
create or replace function public.emergency_promote_administrator(
  p_staff_id uuid,
  p_reason   text
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_reason  text := btrim(coalesce(p_reason, ''));
  v_staff   public.staff;
  v_account public.user_accounts;
  v_role    public.roles;
  v_health  jsonb := public.administrator_health();
begin
  if v_reason = '' then
    raise exception 'A reason for the emergency recovery is required.' using errcode = 'TA136';
  end if;

  -- The whole guard. If somebody can already sign in as the
  -- administrator, this is not an emergency and there is nothing here.
  if (v_health ->> 'valid_administrators')::int > 0 then
    raise exception 'TAMS already has an active Council Administrator who can sign in. Use the ordinary Administrator Transfer, or normal password recovery.'
      using errcode = 'TA137';
  end if;

  select * into v_staff from public.staff where id = p_staff_id for update;
  if not found then
    raise exception 'That staff member could not be found.' using errcode = 'TA138';
  end if;

  select * into v_role from public.roles where id = v_staff.role_id;
  if v_role.role_name not in ('Registry Clerk', 'Land Officer', 'Council Secretary') then
    raise exception 'Recovery promotes an existing ordinary staff member.' using errcode = 'TA138';
  end if;

  select * into v_account from public.user_accounts where staff_id = v_staff.id for update;
  if not found or v_account.account_type <> 'staff' or v_account.account_status <> 'active' then
    raise exception 'That staff member has no active staff account.' using errcode = 'TA138';
  end if;
  if not exists (select 1 from auth.users u where u.id = v_account.auth_user_id) then
    raise exception 'That staff member has no sign-in identity.' using errcode = 'TA138';
  end if;

  perform public.audit_context('EMERGENCY_ADMIN_RECOVERY', v_reason, null);

  update public.staff set role_id = public.council_administrator_role_id() where id = v_staff.id;

  if public.active_council_administrator_count() <> 1 then
    raise exception 'Recovery would not have left exactly one active Council Administrator.'
      using errcode = 'TA135';
  end if;

  -- The reason is recorded. The secret that let this run is not, here
  -- or anywhere else: it never reaches the database at all.
  perform public.audit_event(
    'EMERGENCY_ADMIN_RECOVERY', 'staff', v_staff.id, v_staff.employee_number,
    -- The same two facts on each side. That this was the recovery
    -- process is the action's name, and who it promoted is the entity.
    jsonb_build_object(
      'administrator_role',   v_role.role_name,
      'valid_administrators', (v_health ->> 'valid_administrators')::int),
    jsonb_build_object(
      'administrator_role',   'Council Administrator',
      'valid_administrators', public.active_council_administrator_count()),
    v_reason);

  perform public.notify_user(
    public.staff_account_id(v_staff.id), 'administration',
    'You are now the Council Administrator',
    'TAMS had no Council Administrator who could sign in, and the emergency recovery process has ' ||
    'promoted your account. Reason given: ' || v_reason || '.',
    '/dashboard', 'staff', v_staff.id, v_staff.employee_number);

  return jsonb_build_object(
    'staff_id', v_staff.id,
    'employee_number', v_staff.employee_number,
    'full_name', v_staff.first_name || ' ' || v_staff.last_name,
    'previous_role', v_role.role_name,
    'active_administrators', public.active_council_administrator_count());
end;
$$;
