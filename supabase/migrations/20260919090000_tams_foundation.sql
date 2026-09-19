-- =====================================================================
-- TAMS — Traditional Authority Management System
-- Foundation migration: roles, staff, user accounts, authentication.
--
-- Scope of this migration (nothing else is created):
--   * roles            — the four staff roles
--   * staff            — the staff record
--   * user_accounts    — the sign-in account linked to auth.users
--
-- Everything is written on the assumption that the browser can never be
-- trusted: the client holds no secrets, performs no writes, and every
-- privileged decision is re-made in the database from auth.uid().
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------

create table if not exists public.roles (
  id          uuid primary key default gen_random_uuid(),
  role_name   text not null unique,
  description text,
  created_at  timestamptz not null default now()
);

comment on table public.roles is
  'The fixed set of staff roles. Rows are seeded by migration and are not created through the application.';

create table if not exists public.staff (
  id              uuid primary key default gen_random_uuid(),
  employee_number text not null unique,
  first_name      text not null,
  last_name       text not null,
  email           text not null unique,
  contact_number  text not null,
  role_id         uuid not null references public.roles (id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint staff_employee_number_not_blank check (btrim(employee_number) <> ''),
  constraint staff_first_name_not_blank      check (btrim(first_name) <> ''),
  constraint staff_last_name_not_blank       check (btrim(last_name) <> ''),
  constraint staff_email_format              check (email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  constraint staff_contact_number_format     check (contact_number ~ '^[0-9+][0-9 ()+-]{8,19}$')
);

comment on table public.staff is
  'One row per staff member. A staff member holds exactly one role (staff.role_id).';

create index if not exists staff_role_id_idx on public.staff (role_id);

create table if not exists public.user_accounts (
  id             uuid primary key default gen_random_uuid(),
  auth_user_id   uuid not null unique references auth.users (id) on delete cascade,
  email          text not null unique,
  account_type   text not null,
  account_status text not null,
  staff_id       uuid unique references public.staff (id) on delete restrict,
  resident_id    uuid,                                   -- reserved for a later function; unused for now
  created_at     timestamptz not null default now(),
  last_login     timestamptz,
  constraint user_accounts_account_type_allowed   check (account_type in ('staff')),
  constraint user_accounts_account_status_allowed check (account_status in ('active', 'deactivated')),
  constraint user_accounts_email_format           check (email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  -- a staff account must point at a staff record and never at a resident
  constraint user_accounts_staff_shape check (
    account_type <> 'staff' or (staff_id is not null and resident_id is null)
  )
);

comment on table public.user_accounts is
  'Sign-in account linked to auth.users. For staff, account_status is the single source of truth for system access.';
comment on column public.user_accounts.resident_id is
  'Reserved for a future resident function. Not used by any current code path.';

create index if not exists user_accounts_staff_id_idx on public.user_accounts (staff_id);

-- ---------------------------------------------------------------------
-- 2. Seed the roles
-- ---------------------------------------------------------------------

insert into public.roles (role_name, description) values
  ('Registry Clerk',        'Handles registry intake and record keeping.'),
  ('Land Officer',          'Handles land related administration.'),
  ('Council Secretary',     'Handles council administration and meetings.'),
  ('Council Administrator', 'Administers the system and manages staff accounts.')
on conflict (role_name) do nothing;

-- ---------------------------------------------------------------------
-- 3. Normalisation and integrity triggers
-- ---------------------------------------------------------------------

create or replace function public.tg_staff_normalise()
returns trigger
language plpgsql
as $$
begin
  new.employee_number := btrim(new.employee_number);
  new.first_name      := btrim(new.first_name);
  new.last_name       := btrim(new.last_name);
  new.email           := lower(btrim(new.email));
  new.contact_number  := btrim(new.contact_number);
  new.updated_at      := now();
  return new;
end;
$$;

drop trigger if exists staff_normalise on public.staff;
create trigger staff_normalise
  before insert or update on public.staff
  for each row execute function public.tg_staff_normalise();

create or replace function public.tg_user_accounts_normalise()
returns trigger
language plpgsql
as $$
begin
  new.email := lower(btrim(new.email));
  return new;
end;
$$;

drop trigger if exists user_accounts_normalise on public.user_accounts;
create trigger user_accounts_normalise
  before insert or update on public.user_accounts
  for each row execute function public.tg_user_accounts_normalise();

-- Case-insensitive uniqueness for the employee number.
create unique index if not exists staff_employee_number_ci_idx
  on public.staff (upper(employee_number));

-- The id of the Council Administrator role, used by the guards below.
create or replace function public.council_administrator_role_id()
returns uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select id from public.roles where role_name = 'Council Administrator';
$$;

-- During normal operation there is exactly ONE Council Administrator.
-- Enforced in the database so that no code path — application, edge
-- function or direct SQL — can quietly create a second one.
create or replace function public.tg_enforce_single_council_administrator()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_admin_role_id uuid := public.council_administrator_role_id();
begin
  if new.role_id = v_admin_role_id
     and exists (
       select 1 from public.staff s
       where s.role_id = v_admin_role_id
         and s.id <> new.id
     )
  then
    raise exception 'A Council Administrator already exists.'
      using errcode = 'TA001';
  end if;
  return new;
end;
$$;

drop trigger if exists staff_single_council_administrator on public.staff;
create trigger staff_single_council_administrator
  before insert or update of role_id on public.staff
  for each row execute function public.tg_enforce_single_council_administrator();

-- A staff record must never exist without its user account. The check is
-- deferred to the end of the transaction, so the trusted creation path
-- can insert the staff record first and the account immediately after,
-- while a staff record inserted on its own can never be committed.
create or replace function public.tg_staff_requires_user_account()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  -- The row may have been removed again inside the same transaction.
  if not exists (select 1 from public.staff s where s.id = new.id) then
    return null;
  end if;

  if not exists (select 1 from public.user_accounts ua where ua.staff_id = new.id) then
    raise exception 'A staff record cannot exist without its user account.'
      using errcode = 'TA005';
  end if;

  return null;
end;
$$;

drop trigger if exists staff_requires_user_account on public.staff;
create constraint trigger staff_requires_user_account
  after insert on public.staff
  deferrable initially deferred
  for each row execute function public.tg_staff_requires_user_account();

-- ---------------------------------------------------------------------
-- 4. Authorisation helpers
--
--    These read the CURRENT database state for the CURRENT auth user.
--    Nothing is ever taken from the browser.
-- ---------------------------------------------------------------------

-- True only when the caller is an authenticated, active, staff user whose
-- staff record currently carries the Council Administrator role.
create or replace function public.is_active_council_administrator()
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
      and r.role_name = 'Council Administrator'
  );
$$;

-- True when the caller is any active staff member.
create or replace function public.is_active_staff()
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
    where ua.auth_user_id = auth.uid()
      and ua.account_type = 'staff'
      and ua.account_status = 'active'
  );
$$;

-- Everything the signed-in user is allowed to know about themselves.
-- Returns null when the auth user has no account record at all.
-- `access_granted` is the one flag the application trusts.
create or replace function public.current_staff_context()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'account_id',      ua.id,
    'email',           ua.email,
    'account_type',    ua.account_type,
    'account_status',  ua.account_status,
    'last_login',      ua.last_login,
    'staff_id',        s.id,
    'employee_number', s.employee_number,
    'first_name',      s.first_name,
    'last_name',       s.last_name,
    'full_name',       s.first_name || ' ' || s.last_name,
    'contact_number',  s.contact_number,
    'role_name',       r.role_name,
    'is_council_administrator', coalesce(r.role_name = 'Council Administrator', false),
    'access_granted', (
      ua.account_type = 'staff'
      and ua.account_status = 'active'
      and s.id is not null
      and r.id is not null
    )
  )
  from public.user_accounts ua
  left join public.staff s on s.id = ua.staff_id
  left join public.roles r on r.id = s.role_id
  where ua.auth_user_id = auth.uid();
$$;

-- Stamp a successful sign-in. Only ever touches the caller's own row.
create or replace function public.record_login()
returns timestamptz
language sql
volatile
security definer
set search_path = public, pg_temp
as $$
  update public.user_accounts
     set last_login = now()
   where auth_user_id = auth.uid()
     and account_type = 'staff'
     and account_status = 'active'
  returning last_login;
$$;

-- The roles a Council Administrator may hand out. The Council
-- Administrator role is deliberately absent.
create or replace function public.assignable_staff_roles()
returns table (id uuid, role_name text, description text)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select r.id, r.role_name, r.description
  from public.roles r
  where r.role_name <> 'Council Administrator'
    and public.is_active_council_administrator()
  order by r.role_name;
$$;

-- Every staff account, for the Council Administrator's staff list.
-- Row Level Security would already limit an ordinary staff member to
-- their own row; this refuses them outright and keeps the list in one
-- tested place.
create or replace function public.admin_staff_accounts()
returns table (
  account_id            uuid,
  email                 text,
  account_status        text,
  account_created_at    timestamptz,
  last_login            timestamptz,
  staff_id              uuid,
  employee_number       text,
  first_name            text,
  last_name             text,
  contact_number        text,
  role_name             text,
  invitation_completed  boolean
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
           r.role_name, (u.last_sign_in_at is not null)
    from public.user_accounts ua
    join public.staff s on s.id = ua.staff_id
    join public.roles r on r.id = s.role_id
    join auth.users u on u.id = ua.auth_user_id
    order by ua.created_at desc;
end;
$$;

-- Counts for the Council Administrator dashboard.
create or replace function public.admin_dashboard_stats()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_stats jsonb;
begin
  if not public.is_active_council_administrator() then
    raise exception 'Only the Council Administrator may read these statistics.'
      using errcode = '42501';
  end if;

  select jsonb_build_object(
    'staff_records',   (select count(*) from public.staff),
    'active_staff',    (select count(*) from public.user_accounts where account_type = 'staff' and account_status = 'active'),
    'deactivated',     (select count(*) from public.user_accounts where account_type = 'staff' and account_status = 'deactivated'),
    'awaiting_setup',  (
                         select count(*)
                         from public.user_accounts ua
                         join auth.users u on u.id = ua.auth_user_id
                         where ua.account_type = 'staff'
                           and u.last_sign_in_at is null
                       ),
    'active_by_role',  coalesce((
                         select jsonb_agg(x order by x->>'role_name')
                         from (
                           select jsonb_build_object('role_name', r.role_name, 'count', count(*)) as x
                           from public.user_accounts ua
                           join public.staff s on s.id = ua.staff_id
                           join public.roles r on r.id = s.role_id
                           where ua.account_status = 'active'
                           group by r.role_name
                         ) t
                       ), '[]'::jsonb)
  ) into v_stats;

  return v_stats;
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Trusted write paths
--
--    Both functions below are SECURITY DEFINER and are executable by
--    service_role ONLY. They are called from edge functions that run on
--    the server; the browser can never reach them.
--    Each performs all of its inserts in a single transaction, so a
--    failure can never leave a staff record without its user account.
-- ---------------------------------------------------------------------

-- One-time bootstrap of the first Council Administrator.
-- The auth user must already exist (created by hand in Supabase Auth).
create or replace function public.bootstrap_council_administrator(
  p_auth_user_id    uuid,
  p_employee_number text,
  p_first_name      text,
  p_last_name       text,
  p_email           text,
  p_contact_number  text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_admin_role_id uuid := public.council_administrator_role_id();
  v_staff         public.staff;
  v_account       public.user_accounts;
begin
  if v_admin_role_id is null then
    raise exception 'The Council Administrator role is missing from the roles table.'
      using errcode = 'TA003';
  end if;

  -- Refuse outright if a Council Administrator already exists.
  if exists (select 1 from public.staff s where s.role_id = v_admin_role_id) then
    raise exception 'A Council Administrator already exists. The bootstrap process may only be used once.'
      using errcode = 'TA001';
  end if;

  if not exists (select 1 from auth.users u where u.id = p_auth_user_id) then
    raise exception 'No authentication user exists for the supplied identifier.'
      using errcode = 'TA004';
  end if;

  insert into public.staff (employee_number, first_name, last_name, email, contact_number, role_id)
  values (p_employee_number, p_first_name, p_last_name, p_email, p_contact_number, v_admin_role_id)
  returning * into v_staff;

  insert into public.user_accounts (auth_user_id, email, account_type, account_status, staff_id)
  values (p_auth_user_id, p_email, 'staff', 'active', v_staff.id)
  returning * into v_account;

  return jsonb_build_object(
    'staff_id',        v_staff.id,
    'account_id',      v_account.id,
    'employee_number', v_staff.employee_number,
    'email',           v_account.email,
    'role_name',       'Council Administrator',
    'account_status',  v_account.account_status
  );
end;
$$;

-- Create a staff record together with its user account, atomically.
-- The Council Administrator role can never be assigned through here.
create or replace function public.create_staff_with_account(
  p_auth_user_id    uuid,
  p_employee_number text,
  p_first_name      text,
  p_last_name       text,
  p_email           text,
  p_contact_number  text,
  p_role_id         uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_role    public.roles;
  v_staff   public.staff;
  v_account public.user_accounts;
begin
  select * into v_role from public.roles where id = p_role_id;
  if not found then
    raise exception 'The selected role does not exist.'
      using errcode = 'TA003';
  end if;

  -- Backend enforcement: a hand-crafted request carrying the Council
  -- Administrator role id is rejected here, not just hidden in the UI.
  if v_role.role_name = 'Council Administrator' then
    raise exception 'The Council Administrator role cannot be assigned through staff creation.'
      using errcode = 'TA002';
  end if;

  if not exists (select 1 from auth.users u where u.id = p_auth_user_id) then
    raise exception 'No authentication user exists for the supplied identifier.'
      using errcode = 'TA004';
  end if;

  insert into public.staff (employee_number, first_name, last_name, email, contact_number, role_id)
  values (p_employee_number, p_first_name, p_last_name, p_email, p_contact_number, p_role_id)
  returning * into v_staff;

  insert into public.user_accounts (auth_user_id, email, account_type, account_status, staff_id)
  values (p_auth_user_id, p_email, 'staff', 'active', v_staff.id)
  returning * into v_account;

  return jsonb_build_object(
    'staff_id',        v_staff.id,
    'account_id',      v_account.id,
    'employee_number', v_staff.employee_number,
    'email',           v_account.email,
    'role_name',       v_role.role_name,
    'account_status',  v_account.account_status
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Row Level Security
--
--    Reads are allowed for the owner of the record and for the active
--    Council Administrator. There is NO insert, update or delete policy
--    on any table: writes are only possible through the trusted
--    service_role paths above, which bypass RLS.
-- ---------------------------------------------------------------------

alter table public.roles         enable row level security;
alter table public.staff         enable row level security;
alter table public.user_accounts enable row level security;

alter table public.roles         force row level security;
alter table public.staff         force row level security;
alter table public.user_accounts force row level security;

drop policy if exists roles_readable_by_active_staff on public.roles;
create policy roles_readable_by_active_staff
  on public.roles for select
  to authenticated
  using (public.is_active_staff());

drop policy if exists staff_select_own_or_administrator on public.staff;
create policy staff_select_own_or_administrator
  on public.staff for select
  to authenticated
  using (
    public.is_active_council_administrator()
    or exists (
      select 1 from public.user_accounts ua
      where ua.staff_id = staff.id
        and ua.auth_user_id = auth.uid()
        and ua.account_status = 'active'
    )
  );

drop policy if exists user_accounts_select_own_or_administrator on public.user_accounts;
create policy user_accounts_select_own_or_administrator
  on public.user_accounts for select
  to authenticated
  using (
    auth_user_id = auth.uid()
    or public.is_active_council_administrator()
  );

-- ---------------------------------------------------------------------
-- 7. Grants
--
--    anon (a signed-out visitor) gets nothing at all.
-- ---------------------------------------------------------------------

revoke all on public.roles         from anon, authenticated;
revoke all on public.staff         from anon, authenticated;
revoke all on public.user_accounts from anon, authenticated;

grant select on public.roles         to authenticated;
grant select on public.staff         to authenticated;
grant select on public.user_accounts to authenticated;

-- The trusted server side. service_role bypasses Row Level Security and
-- is only ever used by the edge functions, never by the browser.
grant all on public.roles         to service_role;
grant all on public.staff         to service_role;
grant all on public.user_accounts to service_role;

-- Functions: default execute-for-everyone is removed, then handed back
-- only to the roles that legitimately need each function.
revoke all on function public.council_administrator_role_id()        from public, anon, authenticated;
revoke all on function public.is_active_council_administrator()      from public, anon, authenticated;
revoke all on function public.is_active_staff()                      from public, anon, authenticated;
revoke all on function public.current_staff_context()                from public, anon, authenticated;
revoke all on function public.record_login()                         from public, anon, authenticated;
revoke all on function public.assignable_staff_roles()               from public, anon, authenticated;
revoke all on function public.admin_dashboard_stats()                from public, anon, authenticated;
revoke all on function public.admin_staff_accounts()                 from public, anon, authenticated;
revoke all on function public.bootstrap_council_administrator(uuid, text, text, text, text, text)        from public, anon, authenticated;
revoke all on function public.create_staff_with_account(uuid, text, text, text, text, text, uuid)        from public, anon, authenticated;

grant execute on function public.is_active_council_administrator() to authenticated;
grant execute on function public.is_active_staff()                 to authenticated;
grant execute on function public.current_staff_context()           to authenticated;
grant execute on function public.record_login()                    to authenticated;
grant execute on function public.assignable_staff_roles()          to authenticated;
grant execute on function public.admin_dashboard_stats()           to authenticated;
grant execute on function public.admin_staff_accounts()            to authenticated;

-- Trusted server-side paths only.
grant execute on function public.bootstrap_council_administrator(uuid, text, text, text, text, text) to service_role;
grant execute on function public.create_staff_with_account(uuid, text, text, text, text, text, uuid) to service_role;
