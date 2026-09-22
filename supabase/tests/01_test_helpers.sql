-- Small assertion harness for the foundation tests.

drop schema if exists tams_test cascade;
create schema tams_test;

-- Tests act as anon, authenticated and service_role, and their dynamic
-- SQL reaches for these helpers, so the schema has to be visible to
-- them. The helpers only ever read the test database.
grant usage on schema tams_test to public;

create table tams_test.results (
  id     serial primary key,
  name   text not null,
  passed boolean not null,
  detail text
);

create function tams_test.check(p_name text, p_passed boolean, p_detail text default '')
returns void language plpgsql as $$
begin
  insert into tams_test.results (name, passed, detail)
  values (p_name, coalesce(p_passed, false), p_detail);
end;
$$;

-- Runs a statement as a given database role with a given signed-in user,
-- and reports 'OK' or the SQLSTATE it failed with.
create function tams_test.run_as(p_role text, p_uid uuid, p_sql text)
returns text language plpgsql as $$
declare
  v_outcome text;
begin
  perform set_config('tams.test_auth_uid', coalesce(p_uid::text, ''), true);
  execute format('set local role %I', p_role);
  begin
    execute p_sql;
    v_outcome := 'OK';
  exception when others then
    v_outcome := sqlstate;
  end;
  reset role;
  return v_outcome;
end;
$$;

-- Same, but returns the first column of the first row as text.
create function tams_test.query_as(p_role text, p_uid uuid, p_sql text)
returns text language plpgsql as $$
declare
  v_value text;
begin
  perform set_config('tams.test_auth_uid', coalesce(p_uid::text, ''), true);
  execute format('set local role %I', p_role);
  begin
    execute p_sql into v_value;
  exception when others then
    v_value := 'ERROR:' || sqlstate;
  end;
  reset role;
  return v_value;
end;
$$;

create function tams_test.uid_of(p_email text)
returns uuid language sql stable security definer as $$
  select id from auth.users where email = p_email;
$$;

-- Resolved as the definer, so a test can look up a staff member's
-- account even while acting as somebody who could not.
create function tams_test.staff_account_id_of(p_employee_number text)
returns uuid language sql stable security definer as $$
  select ua.id from public.user_accounts ua
  join public.staff s on s.id = ua.staff_id
  where s.employee_number = p_employee_number;
$$;

-- Runs a statement as the database owner and reports what stopped it.
-- Used only to show that a rule holds even for the most privileged
-- thing the application ever runs as.
create function tams_test.try_sql(p_sql text)
returns text language plpgsql as $$
begin
  execute p_sql;
  return 'OK';
exception when others then
  return sqlstate;
end;
$$;
