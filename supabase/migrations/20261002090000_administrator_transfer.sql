-- =====================================================================
-- TAMS — handing over the Council Administrator, and getting back in
-- when nobody can
--
-- The governance rule has not changed: normal operation has exactly one
-- active Council Administrator, and no ordinary staff function may ever
-- hand that role out. What changes here is that there is now a proper
-- way to pass it on — one transaction, one reason, one audit trail —
-- and a locked-away way to recover when there is nobody left holding it.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. The invariant, restated
--
--    It used to be "no second staff row may carry the administrator
--    role at all". That cannot survive a transfer that leaves the
--    outgoing administrator deactivated but still recorded as what they
--    were. The rule that actually matters is about live access:
--
--        AT MOST ONE ACTIVE COUNCIL ADMINISTRATOR
--
--    so that is what is enforced now — on the staff row and on the
--    account, because either one could otherwise create a second.
-- ---------------------------------------------------------------------

create or replace function public.active_council_administrator_count(p_excluding_staff_id uuid default null)
returns int
language sql stable security definer set search_path = public, pg_temp
as $$
  select count(*)::int
  from public.staff s
  join public.roles r on r.id = s.role_id
  join public.user_accounts ua on ua.staff_id = s.id
  where r.role_name = 'Council Administrator'
    and ua.account_type = 'staff'
    and ua.account_status = 'active'
    and (p_excluding_staff_id is null or s.id <> p_excluding_staff_id);
$$;

create or replace function public.tg_enforce_single_council_administrator()
returns trigger
language plpgsql security definer set search_path = public, pg_temp
as $$
declare v_admin_role_id uuid := public.council_administrator_role_id();
begin
  if new.role_id = v_admin_role_id
     and public.active_council_administrator_count(new.id) > 0 then
    raise exception 'An active Council Administrator already exists.' using errcode = 'TA001';
  end if;
  return new;
end;
$$;

-- The other way in: reactivating an account whose staff record still
-- carries the administrator role.
create or replace function public.tg_enforce_single_active_administrator_account()
returns trigger
language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  if new.account_status = 'active'
     and new.account_type = 'staff'
     and new.staff_id is not null
     and exists (select 1 from public.staff s join public.roles r on r.id = s.role_id
                  where s.id = new.staff_id and r.role_name = 'Council Administrator')
     and public.active_council_administrator_count(new.staff_id) > 0 then
    raise exception 'An active Council Administrator already exists.' using errcode = 'TA001';
  end if;
  return new;
end;
$$;

drop trigger if exists user_accounts_single_active_administrator on public.user_accounts;
create trigger user_accounts_single_active_administrator
  before insert or update of account_status on public.user_accounts
  for each row execute function public.tg_enforce_single_active_administrator_account();

-- ---------------------------------------------------------------------
-- 2. Who could take it on
-- ---------------------------------------------------------------------

create or replace function public.admin_transfer_candidates()
returns table (
  staff_id uuid, employee_number text, full_name text, email text,
  role_name text, account_status text
)
language plpgsql stable security definer set search_path = public, pg_temp
as $$
begin
  perform public.acting_council_administrator_staff_id();
  return query
    select s.id, s.employee_number, s.first_name || ' ' || s.last_name, s.email,
           r.role_name, ua.account_status
    from public.staff s
    join public.roles r on r.id = s.role_id
    join public.user_accounts ua on ua.staff_id = s.id
    where ua.account_type = 'staff'
      and ua.account_status = 'active'
      and r.role_name in ('Registry Clerk', 'Land Officer', 'Council Secretary')
      and exists (select 1 from auth.users u where u.id = ua.auth_user_id)
    order by s.last_name, s.first_name;
end;
$$;

-- ---------------------------------------------------------------------
-- 3. The transfer
--
--    One transaction. Either the whole handover happened or none of it
--    did: there is no committed moment with two active administrators,
--    and none with none.
-- ---------------------------------------------------------------------

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
    jsonb_build_object(
      'administrator',        v_outgoing.first_name || ' ' || v_outgoing.last_name,
      'administrator_employee_number', v_outgoing.employee_number,
      'incoming_role',        v_incoming_role.role_name),
    jsonb_build_object(
      'administrator',        v_incoming.first_name || ' ' || v_incoming.last_name,
      'administrator_employee_number', v_incoming.employee_number,
      'outgoing_outcome',     p_outgoing_outcome,
      'outgoing_new_role',    case when p_outgoing_outcome = 'remain_staff'
                                   then v_outgoing_new_role.role_name else 'deactivated' end,
      'performed_by',         v_outgoing.first_name || ' ' || v_outgoing.last_name,
      'performed_by_role',    'Council Administrator'),
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

-- ---------------------------------------------------------------------
-- 4. Emergency recovery
--
--    For one situation only: TAMS has no administrator anybody can sign
--    in as. Not a forgotten password — that is what password recovery
--    is for — but an account that is gone, deactivated, or whose
--    sign-in identity no longer exists.
--
--    There is no page anywhere in the application that reaches this. It
--    runs as service_role, from an edge function that first checks a
--    secret only the person who set the project up knows, and it
--    refuses outright the moment a healthy administrator exists.
-- ---------------------------------------------------------------------

create or replace function public.administrator_health()
returns jsonb
language sql stable security definer set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'active_administrators', public.active_council_administrator_count(),
    -- An administrator who can actually sign in: active account, active
    -- staff record, and an auth identity that still exists.
    'valid_administrators', (
      select count(*) from public.staff s
      join public.roles r on r.id = s.role_id
      join public.user_accounts ua on ua.staff_id = s.id
      join auth.users u on u.id = ua.auth_user_id
      where r.role_name = 'Council Administrator'
        and ua.account_type = 'staff'
        and ua.account_status = 'active'));
$$;

create or replace function public.emergency_recovery_candidates()
returns table (
  staff_id uuid, employee_number text, full_name text, email text, role_name text
)
language sql stable security definer set search_path = public, pg_temp
as $$
  select s.id, s.employee_number, s.first_name || ' ' || s.last_name, s.email, r.role_name
  from public.staff s
  join public.roles r on r.id = s.role_id
  join public.user_accounts ua on ua.staff_id = s.id
  join auth.users u on u.id = ua.auth_user_id
  where ua.account_type = 'staff'
    and ua.account_status = 'active'
    and r.role_name in ('Registry Clerk', 'Land Officer', 'Council Secretary')
  order by s.last_name, s.first_name;
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
    jsonb_build_object('role', v_role.role_name,
                       'valid_administrators_before', (v_health ->> 'valid_administrators')::int),
    jsonb_build_object('role', 'Council Administrator',
                       'administrator', v_staff.first_name || ' ' || v_staff.last_name,
                       'recovered_by', 'emergency recovery process'),
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

-- ---------------------------------------------------------------------
-- 5. Naming the staff actions in the trail
--
--    The three ordinary staff operations get their proper names and
--    carry their reason, so the audit reads as what happened rather
--    than as a row that changed.
-- ---------------------------------------------------------------------

create or replace function public.change_staff_role(p_staff_id uuid, p_new_role_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_admin_staff_id uuid := public.acting_council_administrator_staff_id();
  v_staff          public.staff;
  v_account        public.user_accounts;
  v_current_role   public.roles;
  v_new_role       public.roles;
begin
  select * into v_staff from public.staff where id = p_staff_id for update;
  if not found then
    raise exception 'That staff member could not be found.' using errcode = 'TA010';
  end if;

  select * into v_current_role from public.roles where id = v_staff.role_id;
  if v_current_role.role_name = 'Council Administrator' then
    raise exception 'The Council Administrator role cannot be changed here.' using errcode = 'TA011';
  end if;

  select * into v_account from public.user_accounts where staff_id = v_staff.id for update;
  if not found or v_account.account_status <> 'active' then
    raise exception 'That staff member''s account is not active, so their role cannot be changed.'
      using errcode = 'TA012';
  end if;

  select * into v_new_role from public.roles where id = p_new_role_id;
  if not found then
    raise exception 'The selected role does not exist.' using errcode = 'TA013';
  end if;
  -- Still refused, transfer or no transfer. The administrator role is
  -- handed over by Administrator Transfer and by nothing else.
  if v_new_role.role_name = 'Council Administrator' then
    raise exception 'The Council Administrator role cannot be assigned to a staff member.'
      using errcode = 'TA014';
  end if;
  if v_new_role.id = v_staff.role_id then
    raise exception 'That staff member already holds the % role.', v_new_role.role_name
      using errcode = 'TA015';
  end if;

  perform public.audit_context('STAFF_ROLE_CHANGED', null, null);
  update public.staff set role_id = v_new_role.id where id = v_staff.id;

  return jsonb_build_object(
    'staff_id', v_staff.id, 'employee_number', v_staff.employee_number,
    'full_name', v_staff.first_name || ' ' || v_staff.last_name, 'email', v_staff.email,
    'previous_role', v_current_role.role_name, 'new_role', v_new_role.role_name,
    'account_status', v_account.account_status, 'changed_by', v_admin_staff_id);
end;
$$;

-- The same two, only so the audit says what happened and carries the
-- reason across both rows the operation writes.
do $$
begin
  execute $fn$
    create or replace function public.deactivate_staff_account(p_staff_id uuid, p_reason text)
    returns jsonb
    language plpgsql volatile security definer set search_path = public, pg_temp
    as $body$
    declare
      v_admin_staff_id uuid := public.acting_council_administrator_staff_id();
      v_reason text := btrim(coalesce(p_reason, ''));
      v_staff public.staff; v_account public.user_accounts; v_role public.roles;
    begin
      if v_reason = '' then
        raise exception 'A reason for deactivating the account is required.' using errcode = 'TA018';
      end if;
      if length(v_reason) > 500 then
        raise exception 'The reason is too long (500 characters at most).' using errcode = 'TA018';
      end if;

      select * into v_staff from public.staff where id = p_staff_id for update;
      if not found then
        raise exception 'That staff member could not be found.' using errcode = 'TA010';
      end if;

      select * into v_role from public.roles where id = v_staff.role_id;
      if v_role.role_name = 'Council Administrator' then
        raise exception 'The Council Administrator account cannot be deactivated here.' using errcode = 'TA011';
      end if;

      select * into v_account from public.user_accounts where staff_id = v_staff.id for update;
      if not found then
        raise exception 'That staff member has no user account.' using errcode = 'TA010';
      end if;
      if v_account.account_status = 'deactivated' then
        raise exception 'That account is already deactivated.' using errcode = 'TA016';
      end if;

      perform public.audit_context('STAFF_DEACTIVATED', v_reason, null);

      update public.user_accounts set account_status = 'deactivated' where id = v_account.id;
      update public.staff
         set last_deactivated_at = now(),
             last_deactivated_by_staff_id = v_admin_staff_id,
             last_deactivation_reason = v_reason
       where id = v_staff.id;

      return jsonb_build_object(
        'staff_id', v_staff.id, 'employee_number', v_staff.employee_number,
        'full_name', v_staff.first_name || ' ' || v_staff.last_name, 'email', v_staff.email,
        'role_name', v_role.role_name, 'account_status', 'deactivated',
        'reason', v_reason, 'deactivated_by', v_admin_staff_id);
    end;
    $body$;
  $fn$;

  execute $fn$
    create or replace function public.reactivate_staff_account(p_staff_id uuid, p_reason text)
    returns jsonb
    language plpgsql volatile security definer set search_path = public, pg_temp
    as $body$
    declare
      v_admin_staff_id uuid := public.acting_council_administrator_staff_id();
      v_reason text := btrim(coalesce(p_reason, ''));
      v_staff public.staff; v_account public.user_accounts; v_role public.roles;
    begin
      if v_reason = '' then
        raise exception 'A reason for reactivating the account is required.' using errcode = 'TA018';
      end if;
      if length(v_reason) > 500 then
        raise exception 'The reason is too long (500 characters at most).' using errcode = 'TA018';
      end if;

      select * into v_staff from public.staff where id = p_staff_id for update;
      if not found then
        raise exception 'That staff member could not be found.' using errcode = 'TA010';
      end if;

      select * into v_role from public.roles where id = v_staff.role_id;
      if v_role.role_name = 'Council Administrator' then
        raise exception 'The Council Administrator account is not managed here.' using errcode = 'TA011';
      end if;

      select * into v_account from public.user_accounts where staff_id = v_staff.id for update;
      if not found then
        raise exception 'That staff member has no user account.' using errcode = 'TA010';
      end if;
      if v_account.account_status = 'active' then
        raise exception 'That account is already active.' using errcode = 'TA017';
      end if;

      perform public.audit_context('STAFF_REACTIVATED', v_reason, null);

      update public.user_accounts set account_status = 'active' where id = v_account.id;
      update public.staff
         set last_reactivated_at = now(),
             last_reactivated_by_staff_id = v_admin_staff_id,
             last_reactivation_reason = v_reason
       where id = v_staff.id;

      return jsonb_build_object(
        'staff_id', v_staff.id, 'employee_number', v_staff.employee_number,
        'full_name', v_staff.first_name || ' ' || v_staff.last_name, 'email', v_staff.email,
        'role_name', v_role.role_name, 'account_status', 'active',
        'reason', v_reason, 'reactivated_by', v_admin_staff_id);
    end;
    $body$;
  $fn$;
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Grants
-- ---------------------------------------------------------------------

do $$
declare v_signature text;
begin
  foreach v_signature in array array[
    'public.admin_transfer_candidates()',
    'public.transfer_council_administrator(uuid, text, text, uuid)'
  ]
  loop
    execute format('revoke all on function %s from public, anon, authenticated', v_signature);
    execute format('grant execute on function %s to authenticated', v_signature);
  end loop;
end;
$$;

-- Recovery is not reachable from a browser at all, at any privilege.
revoke all on function public.emergency_promote_administrator(uuid, text) from public, anon, authenticated;
revoke all on function public.emergency_recovery_candidates() from public, anon, authenticated;
revoke all on function public.administrator_health() from public, anon, authenticated;
revoke all on function public.active_council_administrator_count(uuid) from public, anon, authenticated;
grant execute on function public.emergency_promote_administrator(uuid, text) to service_role;
grant execute on function public.emergency_recovery_candidates() to service_role;
grant execute on function public.administrator_health() to service_role;
