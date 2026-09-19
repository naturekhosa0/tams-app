-- Small assertion harness for the foundation tests.

drop schema if exists tams_test cascade;
create schema tams_test;

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
returns uuid language sql stable as $$
  select id from auth.users where email = p_email;
$$;
