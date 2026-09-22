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
  id                 uuid primary key default gen_random_uuid(),
  email              text unique,
  -- Supabase keeps the password here, hashed. TAMS never reads it and
  -- never writes it; it is in the stub only so the tests can prove that
  -- changing it moves nothing on the TAMS side.
  encrypted_password text,
  last_sign_in_at    timestamptz,
  created_at         timestamptz not null default now()
);

-- Supabase derives this from the request JWT; the tests set it directly.
create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select nullif(current_setting('tams.test_auth_uid', true), '')::uuid;
$$;

-- Supabase Storage, reduced to what the resident document policies need:
-- a bucket list, an object list, and Row Level Security over the
-- objects so the policies in the migration can be exercised.
create schema if not exists storage;

create table if not exists storage.buckets (
  id                 text primary key,
  name               text not null,
  public             boolean not null default false,
  file_size_limit    bigint,
  allowed_mime_types text[],
  created_at         timestamptz not null default now()
);

create table if not exists storage.objects (
  id         uuid primary key default gen_random_uuid(),
  bucket_id  text not null references storage.buckets (id),
  name       text not null,
  owner      uuid,
  metadata   jsonb,
  created_at timestamptz not null default now(),
  unique (bucket_id, name)
);

alter table storage.objects enable row level security;
alter table storage.objects force row level security;

grant usage on schema storage to anon, authenticated, service_role;
grant select, insert on storage.objects to authenticated;
grant select on storage.buckets to authenticated;
grant all on storage.objects to service_role;
grant all on storage.buckets to service_role;

grant usage on schema public to anon, authenticated, service_role;
grant usage on schema auth to authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;
grant select on auth.users to service_role;
