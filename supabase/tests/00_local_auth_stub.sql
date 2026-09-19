-- =====================================================================
-- Local test stub ONLY. Never applied to a Supabase project.
--
-- Supabase supplies the auth schema, the auth.uid() helper and the
-- anon / authenticated / service_role database roles. This file
-- recreates just enough of them to run the foundation migration and its
-- tests against a plain PostgreSQL server.
-- =====================================================================

create extension if not exists pgcrypto;

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin bypassrls;
  end if;
end;
$$;

create schema if not exists auth;

create table if not exists auth.users (
  id              uuid primary key default gen_random_uuid(),
  email           text unique,
  last_sign_in_at timestamptz,
  created_at      timestamptz not null default now()
);

-- Supabase derives this from the request JWT; the tests set it directly.
create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select nullif(current_setting('tams.test_auth_uid', true), '')::uuid;
$$;

grant usage on schema public to anon, authenticated, service_role;
grant usage on schema auth to authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;
grant select on auth.users to service_role;
