-- =====================================================================
-- TAMS — Council Administrator staff management
--
--   US-CA02  Change Staff Role
--   US-CA03  Deactivate Staff Account
--            Reactivate Staff Account
--
-- Builds on the foundation migration. It adds no new table: a staff
-- member still holds exactly one role through staff.role_id, and
-- user_accounts.account_status is still the only thing that decides
-- whether a staff member may use the system.
--
-- Every function below is security definer and re-establishes the
-- caller from auth.uid(), so nothing the browser sends can stand in for
-- authorisation. They are safe to call directly; the edge function in
-- front of them is a second layer, not the only one.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Who deactivated or reactivated an account, when, and why
--
--    Recorded on the staff record itself. No status column is added:
--    account_status remains the single source of truth for access.
-- ---------------------------------------------------------------------

alter table public.staff
  add column if not exists last_deactivated_at           timestamptz,
  add column if not exists last_deactivated_by_staff_id  uuid references public.staff (id),
  add column if not exists last_deactivation_reason      text,
  add column if not exists last_reactivated_at           timestamptz,
  add column if not exists last_reactivated_by_staff_id  uuid references public.staff (id),
  add column if not exists last_reactivation_reason      text;

comment on column public.staff.last_deactivated_at is
  'When this staff member''s account was last deactivated. Not a status — account_status decides access.';
comment on column public.staff.last_reactivated_at is
  'When this staff member''s account was last reactivated. Not a status — account_status decides access.';

-- ---------------------------------------------------------------------
-- 2. Shared guard
--
--    Resolves the caller to the acting Council Administrator's staff id,
--    or refuses. Used by all three operations so the rule is written
--    once: authenticated, linked account, account_type = staff,
--    account_status = active, linked staff record, current role =
--    Council Administrator.
-- ---------------------------------------------------------------------

create or replace function public.acting_council_administrator_staff_id()
returns uuid
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_staff_id uuid;
begin
  select s.id into v_staff_id
  from public.user_accounts ua
  join public.staff s on s.id = ua.staff_id
  join public.roles r on r.id = s.role_id
  where ua.auth_user_id = auth.uid()
    and ua.account_type = 'staff'
    and ua.account_status = 'active'
    and r.role_name = 'Council Administrator';

  if v_staff_id is null then
    raise exception 'Only the active Council Administrator may manage staff accounts.'
      using errcode = '42501';
  end if;

  return v_staff_id;
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Change Staff Role (US-CA02)
--
--    Updates staff.role_id and nothing else. The staff record, the user
--    account, the Supabase Auth user, the password, the employee number
--    and the email address are all left exactly as they are.
-- ---------------------------------------------------------------------

create or replace function public.change_staff_role(
  p_staff_id    uuid,
  p_new_role_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_admin_staff_id uuid := public.acting_council_administrator_staff_id();
  v_staff          public.staff;
  v_account        public.user_accounts;
  v_current_role   public.roles;
  v_new_role       public.roles;
begin
  -- ---- the target -------------------------------------------------
  select * into v_staff from public.staff where id = p_staff_id for update;
  if not found then
    raise exception 'That staff member could not be found.' using errcode = 'TA010';
  end if;

  select * into v_current_role from public.roles where id = v_staff.role_id;

  if v_current_role.role_name = 'Council Administrator' then
    raise exception 'The Council Administrator role cannot be changed here.'
      using errcode = 'TA011';
  end if;

  select * into v_account from public.user_accounts where staff_id = v_staff.id for update;
  if not found or v_account.account_status <> 'active' then
    raise exception 'That staff member''s account is not active, so their role cannot be changed.'
      using errcode = 'TA012';
  end if;

  -- ---- the requested role -----------------------------------------
  select * into v_new_role from public.roles where id = p_new_role_id;
  if not found then
    raise exception 'The selected role does not exist.' using errcode = 'TA013';
  end if;

  -- Refused here even when the administrator role id is submitted by
  -- hand, exactly as staff creation refuses it.
  if v_new_role.role_name = 'Council Administrator' then
    raise exception 'The Council Administrator role cannot be assigned to a staff member.'
      using errcode = 'TA014';
  end if;

  if v_new_role.id = v_staff.role_id then
    raise exception 'That staff member already holds the % role.', v_new_role.role_name
      using errcode = 'TA015';
  end if;

  -- ---- the one change ---------------------------------------------
  update public.staff set role_id = v_new_role.id where id = v_staff.id;

  return jsonb_build_object(
    'staff_id',        v_staff.id,
    'employee_number', v_staff.employee_number,
    'full_name',       v_staff.first_name || ' ' || v_staff.last_name,
    'email',           v_staff.email,
    'previous_role',   v_current_role.role_name,
    'new_role',        v_new_role.role_name,
    'account_status',  v_account.account_status,
    'changed_by',      v_admin_staff_id
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Deactivate Staff Account (US-CA03)
--
--    Flips account_status to 'deactivated'. Nothing is deleted: the
--    staff record, the user account, the Supabase Auth user and the
--    staff member's role all stay exactly as they are, so the account
--    can be reactivated later with the same identity.
-- ---------------------------------------------------------------------

create or replace function public.deactivate_staff_account(
  p_staff_id uuid,
  p_reason   text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_admin_staff_id uuid := public.acting_council_administrator_staff_id();
  v_reason         text := btrim(coalesce(p_reason, ''));
  v_staff          public.staff;
  v_account        public.user_accounts;
  v_role           public.roles;
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
    raise exception 'The Council Administrator account cannot be deactivated here.'
      using errcode = 'TA011';
  end if;

  select * into v_account from public.user_accounts where staff_id = v_staff.id for update;
  if not found then
    raise exception 'That staff member has no user account.' using errcode = 'TA010';
  end if;
  if v_account.account_status = 'deactivated' then
    raise exception 'That account is already deactivated.' using errcode = 'TA016';
  end if;

  update public.user_accounts
     set account_status = 'deactivated'
   where id = v_account.id;

  -- Who did it, when, and why. The role is deliberately untouched.
  update public.staff
     set last_deactivated_at          = now(),
         last_deactivated_by_staff_id = v_admin_staff_id,
         last_deactivation_reason     = v_reason
   where id = v_staff.id;

  return jsonb_build_object(
    'staff_id',        v_staff.id,
    'employee_number', v_staff.employee_number,
    'full_name',       v_staff.first_name || ' ' || v_staff.last_name,
    'email',           v_staff.email,
    'role_name',       v_role.role_name,
    'account_status',  'deactivated',
    'reason',          v_reason,
    'deactivated_by',  v_admin_staff_id
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Reactivate Staff Account
--
--    Flips account_status back to 'active'. Creates nothing: the same
--    staff record, user account, Auth identity, employee number, email
--    address and role are simply usable again.
-- ---------------------------------------------------------------------

create or replace function public.reactivate_staff_account(
  p_staff_id uuid,
  p_reason   text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_admin_staff_id uuid := public.acting_council_administrator_staff_id();
  v_reason         text := btrim(coalesce(p_reason, ''));
  v_staff          public.staff;
  v_account        public.user_accounts;
  v_role           public.roles;
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
    raise exception 'The Council Administrator account is not managed here.'
      using errcode = 'TA011';
  end if;

  select * into v_account from public.user_accounts where staff_id = v_staff.id for update;
  if not found then
    raise exception 'That staff member has no user account.' using errcode = 'TA010';
  end if;
  if v_account.account_status = 'active' then
    raise exception 'That account is already active.' using errcode = 'TA017';
  end if;

  update public.user_accounts
     set account_status = 'active'
   where id = v_account.id;

  update public.staff
     set last_reactivated_at          = now(),
         last_reactivated_by_staff_id = v_admin_staff_id,
         last_reactivation_reason     = v_reason
   where id = v_staff.id;

  return jsonb_build_object(
    'staff_id',        v_staff.id,
    'employee_number', v_staff.employee_number,
    'full_name',       v_staff.first_name || ' ' || v_staff.last_name,
    'email',           v_staff.email,
    'role_name',       v_role.role_name,
    'account_status',  'active',
    'reason',          v_reason,
    'reactivated_by',  v_admin_staff_id
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 6. The staff list gains the deactivation history the actions need
-- ---------------------------------------------------------------------

drop function if exists public.admin_staff_accounts();

create function public.admin_staff_accounts()
returns table (
  account_id                uuid,
  email                     text,
  account_status            text,
  account_created_at        timestamptz,
  last_login                timestamptz,
  staff_id                  uuid,
  employee_number           text,
  first_name                text,
  last_name                 text,
  contact_number            text,
  role_id                   uuid,
  role_name                 text,
  invitation_completed      boolean,
  is_council_administrator  boolean,
  last_deactivated_at       timestamptz,
  last_deactivation_reason  text,
  last_deactivated_by       text,
  last_reactivated_at       timestamptz,
  last_reactivation_reason  text,
  last_reactivated_by       text
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_active_council_administrator() then
    raise exception 'Only the Council Administrator may list staff accounts.'
      using errcode = '42501';
  end if;

  return query
    select ua.id, ua.email, ua.account_status, ua.created_at, ua.last_login,
           s.id, s.employee_number, s.first_name, s.last_name, s.contact_number,
           r.id, r.role_name,
           (u.last_sign_in_at is not null),
           (r.role_name = 'Council Administrator'),
           s.last_deactivated_at, s.last_deactivation_reason,
           (select d.first_name || ' ' || d.last_name from public.staff d
             where d.id = s.last_deactivated_by_staff_id),
           s.last_reactivated_at, s.last_reactivation_reason,
           (select a.first_name || ' ' || a.last_name from public.staff a
             where a.id = s.last_reactivated_by_staff_id)
    from public.user_accounts ua
    join public.staff s on s.id = ua.staff_id
    join public.roles r on r.id = s.role_id
    join auth.users u on u.id = ua.auth_user_id
    order by ua.created_at desc;
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Grants
--
--    Each function refuses anyone who is not the active Council
--    Administrator, so granting execute to authenticated is safe: an
--    ordinary staff member calling one directly is turned away by the
--    function itself.
-- ---------------------------------------------------------------------

revoke all on function public.acting_council_administrator_staff_id()           from public, anon, authenticated;
revoke all on function public.change_staff_role(uuid, uuid)                     from public, anon, authenticated;
revoke all on function public.deactivate_staff_account(uuid, text)              from public, anon, authenticated;
revoke all on function public.reactivate_staff_account(uuid, text)              from public, anon, authenticated;
revoke all on function public.admin_staff_accounts()                            from public, anon, authenticated;

grant execute on function public.change_staff_role(uuid, uuid)        to authenticated;
grant execute on function public.deactivate_staff_account(uuid, text) to authenticated;
grant execute on function public.reactivate_staff_account(uuid, text) to authenticated;
grant execute on function public.admin_staff_accounts()               to authenticated;
