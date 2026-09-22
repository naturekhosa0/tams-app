-- =====================================================================
-- The final quality pass: the security posture of the whole schema,
-- asserted as a property rather than described in a document.
--
-- These tests do not exercise a feature. They exercise the shape of the
-- database itself, so that a future migration that quietly loosens it
-- fails the build instead of shipping.
-- =====================================================================

-- ---------------------------------------------------------------------
-- QA 1. Row Level Security is on for every table, everywhere.
-- ---------------------------------------------------------------------

select tams_test.check(
  'QA 1 — every public table has row level security enabled',
  not exists (
    select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity),
  coalesce((select string_agg(c.relname, ', ') from pg_class c
              join pg_namespace n on n.oid = c.relnamespace
             where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity),
           'all enabled'));

-- Every table but audit_logs is also forced. audit_logs must not be:
-- forcing it would make the schema owner subject to the policies, and
-- there is deliberately no INSERT policy, so the system would stop
-- being able to audit itself. See the migration for the full reasoning.
select tams_test.check(
  'QA 2 — every table except audit_logs forces row level security',
  not exists (
    select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r'
       and c.relname <> 'audit_logs' and not c.relforcerowsecurity),
  coalesce((select string_agg(c.relname, ', ') from pg_class c
              join pg_namespace n on n.oid = c.relnamespace
             where n.nspname = 'public' and c.relkind = 'r'
               and c.relname <> 'audit_logs' and not c.relforcerowsecurity),
           'all forced'));

-- ---------------------------------------------------------------------
-- QA 3-5. The browser can read, and only read.
--
--   Every write in TAMS goes through a security definer function that
--   establishes the caller from auth.uid(). Not one table carries a
--   policy or a grant that would let a browser write directly. That is
--   the single most important property in the whole schema.
-- ---------------------------------------------------------------------

select tams_test.check(
  'QA 3 — no INSERT, UPDATE or DELETE policy exists for any client role',
  not exists (
    select 1 from pg_policies
     where schemaname = 'public'
       and cmd <> 'SELECT'
       and roles::text[] && array['anon', 'authenticated', 'public']),
  coalesce((select string_agg(tablename || '.' || policyname || ' (' || cmd || ')', ', ')
              from pg_policies where schemaname = 'public' and cmd <> 'SELECT'
                and roles::text[] && array['anon', 'authenticated', 'public']),
           'select-only'));

select tams_test.check(
  'QA 4 — authenticated holds no write grant on any table',
  not exists (
    select 1 from information_schema.role_table_grants
     where table_schema = 'public' and grantee = 'authenticated'
       and privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE')),
  coalesce((select string_agg(table_name || ':' || privilege_type, ', ')
              from information_schema.role_table_grants
             where table_schema = 'public' and grantee = 'authenticated'
               and privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE')),
           'read only'));

select tams_test.check(
  'QA 5 — anon holds no table grant at all',
  not exists (
    select 1 from information_schema.role_table_grants
     where table_schema = 'public' and grantee = 'anon'),
  coalesce((select string_agg(table_name || ':' || privilege_type, ', ')
              from information_schema.role_table_grants
             where table_schema = 'public' and grantee = 'anon'),
           'nothing'));

-- ---------------------------------------------------------------------
-- QA 6-8. The functions.
-- ---------------------------------------------------------------------

select tams_test.check(
  'QA 6 — every security definer function pins a search path',
  not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prosecdef
       and (p.proconfig is null
            or not exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%'))),
  coalesce((select string_agg(p.proname, ', ') from pg_proc p
              join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.prosecdef
               and (p.proconfig is null
                    or not exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%'))),
           'all pinned'));

-- verify_pto is the one thing a signed-out visitor may call: the whole
-- point of the QR code on a printed permission. Everything else must be
-- closed to anon and to PUBLIC.
select tams_test.check(
  'QA 7 — verify_pto is the only TAMS function a signed-out visitor may call',
  (select coalesce(string_agg(distinct p.proname, ', ' order by p.proname), 'none')
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind = 'f'
      and p.proname not like 'tg\_%'
      and p.proname !~ '^(armor|dearmor|crypt|digest|decrypt|encrypt|gen_|hmac|pgp_)'
      and has_function_privilege('anon', p.oid, 'EXECUTE')) = 'verify_pto',
  (select coalesce(string_agg(distinct p.proname, ', ' order by p.proname), 'none')
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind = 'f'
      and p.proname not like 'tg\_%'
      and p.proname !~ '^(armor|dearmor|crypt|digest|decrypt|encrypt|gen_|hmac|pgp_)'
      and has_function_privilege('anon', p.oid, 'EXECUTE')));

-- A trigger function is never called by name. PostgreSQL's default of
-- EXECUTE to PUBLIC was an inconsistency in a schema whose defence is
-- that its privileges are uniform.
select tams_test.check(
  'QA 8 — no trigger function is executable by PUBLIC, anon or authenticated',
  not exists (
    select 1 from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      join pg_type t on t.oid = p.prorettype
     where n.nspname = 'public' and t.typname = 'trigger'
       and (has_function_privilege('anon', p.oid, 'EXECUTE')
         or has_function_privilege('public', p.oid, 'EXECUTE')
         or has_function_privilege('authenticated', p.oid, 'EXECUTE'))),
  coalesce((select string_agg(p.proname, ', ') from pg_proc p
              join pg_namespace n on n.oid = p.pronamespace
              join pg_type t on t.oid = p.prorettype
             where n.nspname = 'public' and t.typname = 'trigger'
               and (has_function_privilege('anon', p.oid, 'EXECUTE')
                 or has_function_privilege('public', p.oid, 'EXECUTE')
                 or has_function_privilege('authenticated', p.oid, 'EXECUTE'))),
           'all revoked'));

-- ---------------------------------------------------------------------
-- QA 9-10. The audit trail is still insert-only, and still private.
--
--   These are the properties that make leaving audit_logs unforced
--   safe. If either ever stops holding, the decision has to be revisited.
-- ---------------------------------------------------------------------

do $$
declare v_id uuid;
begin
  select id into v_id from public.audit_logs limit 1;
  perform set_config('tams.qa_audit_id', coalesce(v_id::text, ''), false);
end;
$$;

select tams_test.check(
  'QA 9a — an audit row cannot be updated, by anybody',
  tams_test.run_as('postgres', null,
    format('update public.audit_logs set reason = ''tampered'' where id = %L',
           nullif(current_setting('tams.qa_audit_id', true), '')::uuid)) <> 'OK',
  tams_test.run_as('postgres', null,
    format('update public.audit_logs set reason = ''tampered'' where id = %L',
           nullif(current_setting('tams.qa_audit_id', true), '')::uuid)));

select tams_test.check(
  'QA 9b — an audit row cannot be deleted, by anybody',
  tams_test.run_as('postgres', null,
    format('delete from public.audit_logs where id = %L',
           nullif(current_setting('tams.qa_audit_id', true), '')::uuid)) <> 'OK',
  tams_test.run_as('postgres', null,
    format('delete from public.audit_logs where id = %L',
           nullif(current_setting('tams.qa_audit_id', true), '')::uuid)));

select tams_test.check(
  'QA 10 — audit_logs is readable only by the active Council Administrator',
  (select count(*) from pg_policies
    where schemaname = 'public' and tablename = 'audit_logs'
      and qual = 'is_active_council_administrator()') = 1,
  coalesce((select string_agg(policyname || ': ' || qual, '; ') from pg_policies
             where schemaname = 'public' and tablename = 'audit_logs'), 'no policy'));

-- ---------------------------------------------------------------------
-- QA 11-20. Database integrity: the impossible states stay impossible.
--
--   Each of these is a shape the register must never take. They are
--   checked against the real imported village plus everything the
--   earlier suites created, so they run over thousands of rows.
-- ---------------------------------------------------------------------

select tams_test.check(
  'QA 11 — no household is headed by somebody who does not live in it',
  not exists (select 1 from public.households h
               where h.head_resident_id is not null
                 and not exists (select 1 from public.residents r
                                  where r.id = h.head_resident_id and r.household_id = h.id)),
  'checked');

select tams_test.check(
  'QA 12 — no active household is headed by somebody recorded as deceased',
  not exists (select 1 from public.households h
                join public.residents r on r.id = h.head_resident_id
               where h.household_status = 'active' and r.resident_status = 'deceased'),
  'checked');

select tams_test.check(
  'QA 13 — every current family relationship has its inverse recorded',
  not exists (select 1 from public.family_relationships f
               where f.relationship_status = 'active'
                 and not exists (select 1 from public.family_relationships g
                                  where g.relationship_status = 'active'
                                    and g.resident_id = f.related_resident_id
                                    and g.related_resident_id = f.resident_id)),
  'checked');

select tams_test.check(
  'QA 14 — nobody is related to themselves',
  not exists (select 1 from public.family_relationships where resident_id = related_resident_id),
  'checked');

select tams_test.check(
  'QA 15 — no site is held by two open allocations at once',
  not exists (select 1 from (
    select land_site_id from public.land_allocations
     where allocation_status in ('active', 'succession_pending')
     group by land_site_id having count(*) > 1) t),
  'checked');

select tams_test.check(
  'QA 16 — every permission to occupy stands on a real allocation',
  not exists (select 1 from public.ptos p
               where p.land_allocation_id is null
                  or not exists (select 1 from public.land_allocations a where a.id = p.land_allocation_id)),
  'checked');

select tams_test.check(
  'QA 17 — no active permission stands on an allocation that has ended',
  not exists (select 1 from public.ptos p
                join public.land_allocations a on a.id = p.land_allocation_id
               where p.pto_status = 'active'
                 and a.allocation_status not in ('active', 'succession_pending')),
  'checked');

select tams_test.check(
  'QA 18 — every renewal points at a permission that exists',
  not exists (select 1 from public.ptos p
               where p.renewed_from_pto_id is not null
                 and not exists (select 1 from public.ptos q where q.id = p.renewed_from_pto_id)),
  'checked');

select tams_test.check(
  'QA 19 — exactly one active Council Administrator account exists',
  (select count(*) from public.staff s
     join public.roles ro on ro.id = s.role_id
     join public.user_accounts u on u.staff_id = s.id
    where ro.role_name = 'Council Administrator' and u.account_status = 'active') = 1,
  (select count(*)::text from public.staff s
     join public.roles ro on ro.id = s.role_id
     join public.user_accounts u on u.staff_id = s.id
    where ro.role_name = 'Council Administrator' and u.account_status = 'active'));

select tams_test.check(
  'QA 20 — no user account is linked to a staff record and a resident at once',
  not exists (select 1 from public.user_accounts where staff_id is not null and resident_id is not null),
  'checked');

-- Nothing in the register may point at a row that is not there. The
-- foreign keys carry this; the test says so out loud, because these are
-- the references a demonstration would expose first.
select tams_test.check(
  'QA 21 — no orphan minutes, resolutions, milestones or recipients',
  not exists (select 1 from public.meeting_minutes m
               where not exists (select 1 from public.council_meetings c where c.id = m.meeting_id))
  and not exists (select 1 from public.council_resolutions r
                   where not exists (select 1 from public.council_meetings c where c.id = r.meeting_id))
  and not exists (select 1 from public.project_milestones ms
                   where not exists (select 1 from public.community_projects p where p.id = ms.project_id))
  and not exists (select 1 from public.notifications n
                   where not exists (select 1 from public.user_accounts u where u.id = n.recipient_user_account_id))
  and not exists (select 1 from public.resident_communication_recipients rc
                   where not exists (select 1 from public.user_accounts u where u.id = rc.user_account_id))
  and not exists (select 1 from public.staff_message_recipients sm
                   where not exists (select 1 from public.staff s where s.id = sm.recipient_staff_id)),
  'checked');

-- ---------------------------------------------------------------------
-- QA 22-24. Audit privacy, over everything the whole suite has written.
-- ---------------------------------------------------------------------

select tams_test.check(
  'QA 22 — no audited field name is a password, token, secret or file path',
  not exists (
    select 1 from public.audit_logs,
      lateral jsonb_object_keys(coalesce(old_values, '{}'::jsonb) || coalesce(new_values, '{}'::jsonb)) k
     where k ~* '(password|token|secret|api_key|recovery_link|storage_path|file_path|document_content|private_key|credential)'),
  'checked');

select tams_test.check(
  'QA 23 — no real verification token, storage path or message body is in the trail',
  not exists (select 1 from public.audit_logs a
               where exists (select 1 from public.ptos p where p.verification_token is not null
                 and (coalesce(a.old_values::text, '') like '%' || p.verification_token || '%'
                   or coalesce(a.new_values::text, '') like '%' || p.verification_token || '%')))
  and not exists (select 1 from public.audit_logs a
               where exists (select 1 from public.resident_request_documents d where d.storage_path is not null
                 and (coalesce(a.old_values::text, '') like '%' || d.storage_path || '%'
                   or coalesce(a.new_values::text, '') like '%' || d.storage_path || '%')))
  and not exists (select 1 from public.audit_logs a
               where exists (select 1 from public.staff_messages m where length(m.body) > 12
                 and (coalesce(a.old_values::text, '') like '%' || m.body || '%'
                   or coalesce(a.new_values::text, '') like '%' || m.body || '%'))),
  'checked');

select tams_test.check(
  'QA 24 — nothing shaped like a token is anywhere in the trail',
  not exists (select 1 from public.audit_logs
               where coalesce(old_values::text, '') || coalesce(new_values::text, '')
                     ~ 'eyJ[A-Za-z0-9_-]{10,}'),
  'checked');

-- ---------------------------------------------------------------------
-- QA 25-26. An UPDATE really does record what moved, on both sides.
--
--   A creation carries new_values and no old_values, which is right: on
--   a creation nothing moved, everything arrived. An update is the case
--   the Council Administrator actually reads, so it is the case pinned
--   here: every field named in changed_fields must appear on both
--   sides, and must genuinely differ between them.
-- ---------------------------------------------------------------------

select tams_test.check(
  'QA 25 — every recorded update carries both sides of every field it names',
  not exists (
    select 1 from public.audit_logs
     where old_values is not null and new_values is not null
       and coalesce(array_length(changed_fields, 1), 0) > 0
       and not (old_values ?& changed_fields and new_values ?& changed_fields)),
  (select count(*)::text || ' updates checked' from public.audit_logs
    where old_values is not null and new_values is not null
      and coalesce(array_length(changed_fields, 1), 0) > 0));

select tams_test.check(
  'QA 26 — a field is never reported as changed unless it actually moved',
  not exists (
    select 1 from public.audit_logs a,
      lateral unnest(a.changed_fields) f
     where a.old_values is not null and a.new_values is not null
       and a.old_values -> f is not distinct from a.new_values -> f),
  'checked');

-- A creation says so: new_values and nothing on the other side.
select tams_test.check(
  'QA 27 — a creation records what arrived and claims nothing moved',
  not exists (
    select 1 from public.audit_logs
     where action like 'CREATE%' and old_values is not null),
  'checked');
