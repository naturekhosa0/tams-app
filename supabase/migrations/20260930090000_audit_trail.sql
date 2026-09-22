-- =====================================================================
-- TAMS — the immutable audit trail
--
-- Who changed what, when, from what, to what, and why.
--
-- The design is deliberately not "every function remembers to write a
-- log line". A function can be changed, or written next year by somebody
-- who forgets. Instead the audit is written by triggers on the tables
-- themselves, so it happens however the row came to be written; a
-- business action may add its own name and reason through a
-- transaction-local context, and nothing else can.
--
-- The actor is read from auth.uid() inside a security definer trigger.
-- No client can supply it, and there is no function anywhere that takes
-- an actor or an action as a parameter from a browser.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. The log
-- ---------------------------------------------------------------------

create table if not exists public.audit_logs (
  id                 uuid primary key default gen_random_uuid(),
  actor_user_id      uuid,          -- auth.users.id, or null for the system
  actor_staff_id     uuid references public.staff (id),
  actor_role         text,          -- the role they held at the moment of the action
  actor_account_type text,
  actor_label        text,          -- a readable name, kept even if records change later

  action             text not null,
  entity_type        text not null,
  entity_id          uuid,
  entity_reference   text,

  old_values         jsonb,
  new_values         jsonb,
  changed_fields     text[],
  reason             text,

  -- Several rows written by one business action share this.
  event_group_id     uuid,
  created_at         timestamptz not null default now(),

  constraint audit_logs_action_not_blank      check (btrim(action) <> ''),
  constraint audit_logs_entity_type_not_blank check (btrim(entity_type) <> '')
);

create index if not exists audit_logs_created_idx  on public.audit_logs (created_at desc);
create index if not exists audit_logs_entity_idx   on public.audit_logs (entity_type, entity_id);
create index if not exists audit_logs_actor_idx    on public.audit_logs (actor_staff_id);
create index if not exists audit_logs_action_idx   on public.audit_logs (action);
create index if not exists audit_logs_group_idx    on public.audit_logs (event_group_id);

-- ---------------------------------------------------------------------
-- 2. Immutability
--
--    Insert only. Not "we try not to update it" — an update or a delete
--    raises, whoever attempts it, so the application cannot rewrite its
--    own history even by mistake. (A database owner can drop a trigger;
--    that is outside the application, and outside what this can
--    promise.)
-- ---------------------------------------------------------------------

create or replace function public.tg_audit_logs_are_immutable()
returns trigger
language plpgsql
as $$
begin
  raise exception 'The audit trail is insert-only. An audit record cannot be % .', lower(tg_op)
    using errcode = 'TA120';
end;
$$;

drop trigger if exists audit_logs_immutable on public.audit_logs;
create trigger audit_logs_immutable
  before update or delete or truncate on public.audit_logs
  for each statement execute function public.tg_audit_logs_are_immutable();

-- ---------------------------------------------------------------------
-- 3. Who is acting
-- ---------------------------------------------------------------------

create or replace function public.audit_actor()
returns jsonb
language sql stable security definer set search_path = public, pg_temp
as $$
  select coalesce(
    (select jsonb_build_object(
              'actor_user_id',      ua.auth_user_id,
              'actor_staff_id',     ua.staff_id,
              'actor_account_type', ua.account_type,
              'actor_role',         coalesce(r.role_name, ua.account_type),
              'actor_label',        coalesce(s.first_name || ' ' || s.last_name,
                                             res.first_name || ' ' || res.last_name,
                                             ua.email))
     from public.user_accounts ua
     left join public.staff s on s.id = ua.staff_id
     left join public.roles r on r.id = s.role_id
     left join public.residents res on res.id = ua.resident_id
     where ua.auth_user_id = auth.uid()),
    -- Nobody signed in: a scheduled worker, a migration, or the
    -- recovery process. Recorded as the system, never as a person.
    jsonb_build_object(
      'actor_user_id', null, 'actor_staff_id', null,
      'actor_account_type', 'system', 'actor_role', 'system', 'actor_label', 'TAMS')
  );
$$;

-- ---------------------------------------------------------------------
-- 4. The context a business action may add
--
--    Transaction-local, so it cannot leak between requests on a pooled
--    connection. A function sets the action it is performing and the
--    reason it was given; the triggers below pick them up.
-- ---------------------------------------------------------------------

create or replace function public.audit_context(
  p_action text default null,
  p_reason text default null,
  p_group  uuid default null
)
returns uuid
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare v_group uuid := coalesce(p_group, gen_random_uuid());
begin
  perform set_config('tams.audit_action', coalesce(p_action, ''), true);
  perform set_config('tams.audit_reason', coalesce(p_reason, ''), true);
  perform set_config('tams.audit_group',  v_group::text, true);
  return v_group;
end;
$$;

create or replace function public.audit_context_value(p_key text)
returns text
language sql stable
as $$
  select nullif(btrim(coalesce(current_setting(p_key, true), '')), '');
$$;

-- ---------------------------------------------------------------------
-- 5. What never goes into the log
--
--    Secrets are not audited merely because the row they live on is.
--    Anything that could be replayed — a password, a token, a key — and
--    anything that is the content of somebody's private document is
--    dropped before the values are written.
-- ---------------------------------------------------------------------

create or replace function public.audit_strip(p_values jsonb, p_extra text[] default '{}')
returns jsonb
language sql immutable
as $$
  select coalesce(
    (select jsonb_object_agg(k, v)
     from jsonb_each(coalesce(p_values, '{}'::jsonb)) as e(k, v)
     where not (k = any (p_extra))
       and k not in ('updated_at', 'created_at')
       and k !~* '(password|secret|token|api_key|service_role|private_key|credential)'
       and k !~* '(storage_path|file_path|document_content|file_bytes|raw_document)'),
    '{}'::jsonb);
$$;

-- ---------------------------------------------------------------------
-- 6. The audit trigger
--
--    Arguments, in order:
--      0  entity type            e.g. 'pto'
--      1  reference column       e.g. 'pto_number'    (or '' for none)
--      2  status column          e.g. 'pto_status'    (or '' for none)
--      3  extra excluded columns comma separated      (or '')
--
--    The action is the business action the function announced, if it
--    announced one. Otherwise it is worked out: an insert is a CREATE,
--    and an update that moved the status column is named after where it
--    moved to — PTO_REVOKED, MEETING_CANCELLED, PROJECT_COMPLETED —
--    which is the vocabulary an administrator reading this actually
--    wants.
-- ---------------------------------------------------------------------

create or replace function public.tg_audit()
returns trigger
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v_entity   text := tg_argv[0];
  v_ref_col  text := nullif(tg_argv[1], '');
  v_stat_col text := nullif(tg_argv[2], '');
  v_extra    text[] := case when coalesce(tg_argv[3], '') = '' then '{}'::text[]
                            else string_to_array(tg_argv[3], ',') end;

  v_old      jsonb := case when tg_op = 'INSERT' then null else public.audit_strip(to_jsonb(old), v_extra) end;
  v_new      jsonb := case when tg_op = 'DELETE' then null else public.audit_strip(to_jsonb(new), v_extra) end;
  v_changed  text[] := '{}';
  v_old_out  jsonb;
  v_new_out  jsonb;
  v_action   text := public.audit_context_value('tams.audit_action');
  v_reason   text := public.audit_context_value('tams.audit_reason');
  v_group    uuid := nullif(public.audit_context_value('tams.audit_group'), '')::uuid;
  v_actor    jsonb := public.audit_actor();
  v_ref      text;
  v_id       uuid;
  v_status   text;
  v_key      text;
begin
  -- ---- what changed -------------------------------------------------
  if tg_op = 'UPDATE' then
    select coalesce(array_agg(k order by k), '{}')
      into v_changed
      from jsonb_object_keys(v_new) as k
     where v_new -> k is distinct from v_old -> k;

    -- Nothing worth recording: a touch of updated_at and no more.
    if array_length(v_changed, 1) is null then return null; end if;

    -- Only the fields that actually moved, on both sides.
    v_old_out := '{}'::jsonb;
    v_new_out := '{}'::jsonb;
    foreach v_key in array v_changed loop
      v_old_out := v_old_out || jsonb_build_object(v_key, v_old -> v_key);
      v_new_out := v_new_out || jsonb_build_object(v_key, v_new -> v_key);
    end loop;
  elsif tg_op = 'INSERT' then
    v_old_out := null;
    v_new_out := v_new;
    select coalesce(array_agg(k order by k), '{}') into v_changed from jsonb_object_keys(v_new) as k;
  else
    v_old_out := v_old;
    v_new_out := null;
  end if;

  -- ---- readable names in place of internal ids ----------------------
  if v_entity = 'staff' and (v_changed @> array['role_id'] or tg_op = 'INSERT') then
    v_old_out := (v_old_out - 'role_id')
      || case when v_old_out is null then '{}'::jsonb
              else jsonb_build_object('role',
                   (select role_name from public.roles where id = (v_old ->> 'role_id')::uuid)) end;
    v_new_out := (v_new_out - 'role_id')
      || jsonb_build_object('role',
           (select role_name from public.roles where id = (v_new ->> 'role_id')::uuid));
    v_changed := array_replace(v_changed, 'role_id', 'role');
  end if;

  if v_entity = 'household' and v_changed @> array['head_resident_id'] then
    v_old_out := (v_old_out - 'head_resident_id') || jsonb_build_object('head',
      coalesce((select r.first_name || ' ' || r.last_name || ' (' || r.id_number || ')'
                from public.residents r where r.id = (v_old ->> 'head_resident_id')::uuid), 'none'));
    v_new_out := (v_new_out - 'head_resident_id') || jsonb_build_object('head',
      coalesce((select r.first_name || ' ' || r.last_name || ' (' || r.id_number || ')'
                from public.residents r where r.id = (v_new ->> 'head_resident_id')::uuid), 'none'));
    v_changed := array_replace(v_changed, 'head_resident_id', 'head');
  end if;

  -- ---- identity of the thing ----------------------------------------
  v_id := coalesce((v_new ->> 'id')::uuid, (v_old ->> 'id')::uuid);
  if v_ref_col is not null then
    v_ref := coalesce(v_new ->> v_ref_col, v_old ->> v_ref_col);
  end if;

  -- ---- the name of the action ---------------------------------------
  if v_action is null then
    if tg_op = 'INSERT' then
      v_action := 'CREATE_' || upper(v_entity);
    elsif tg_op = 'DELETE' then
      v_action := 'DELETE_' || upper(v_entity);
    else
      v_status := case when v_stat_col is null then null
                       when (v_new ->> v_stat_col) is distinct from (v_old ->> v_stat_col)
                       then v_new ->> v_stat_col end;
      v_action := case when v_status is null then 'UPDATE_' || upper(v_entity)
                       else upper(v_entity) || '_' || upper(v_status) end;
    end if;
  end if;

  -- ---- why, when the row itself says why -----------------------------
  if v_reason is null and v_new_out is not null then
    select v_new_out ->> k into v_reason
      from jsonb_object_keys(v_new_out) as k
     where k ~ '_reason$' and nullif(btrim(coalesce(v_new_out ->> k, '')), '') is not null
     limit 1;
  end if;

  insert into public.audit_logs (
    actor_user_id, actor_staff_id, actor_role, actor_account_type, actor_label,
    action, entity_type, entity_id, entity_reference,
    old_values, new_values, changed_fields, reason, event_group_id)
  values (
    nullif(v_actor ->> 'actor_user_id', '')::uuid,
    nullif(v_actor ->> 'actor_staff_id', '')::uuid,
    v_actor ->> 'actor_role',
    v_actor ->> 'actor_account_type',
    v_actor ->> 'actor_label',
    v_action, v_entity, v_id, v_ref,
    v_old_out, v_new_out, v_changed, v_reason, v_group);

  return null;
end;
$$;

-- An event with no row behind it: a document being looked at, an
-- administrator being transferred, the recovery process running.
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
  v_actor jsonb := public.audit_actor();
  v_group uuid := nullif(public.audit_context_value('tams.audit_group'), '')::uuid;
  v_old   jsonb := public.audit_strip(p_old);
  v_new   jsonb := public.audit_strip(p_new);
  v_id    uuid;
begin
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
    case when p_new is null then null
         else (select coalesce(array_agg(k order by k), '{}') from jsonb_object_keys(v_new) as k) end,
    nullif(btrim(coalesce(p_reason, '')), ''),
    v_group)
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Where the triggers go
--
--    Everything official. Notifications themselves are deliberately not
--    audited — they are an effect of the actions below, and auditing
--    them would only fill the trail with copies of people's messages.
-- ---------------------------------------------------------------------

do $$
declare
  v_spec record;
begin
  for v_spec in
    select * from (values
      -- table,                       entity,                 reference,             status,               extra excluded
      ('staff',                       'staff',                'employee_number',     '',                   ''),
      ('user_accounts',               'user_account',         'email',               'account_status',     ''),
      ('residents',                   'resident',             'id_number',           'resident_status',    ''),
      ('households',                  'household',            'household_code',      'household_status',   ''),
      ('family_relationships',        'family_relationship',  '',                    'relationship_status',''),
      ('resident_account_requests',   'resident_account_request', 'id_number',       'request_status',     ''),
      ('resident_request_documents',  'verification_document','document_type',       '',                   'file_name'),
      ('land_sites',                  'land_site',            'site_code',           'site_status',        ''),
      ('land_applications',           'land_application',     'application_reference','application_status', ''),
      ('land_allocations',            'land_allocation',      'allocation_reference','allocation_status',   ''),
      ('ptos',                        'pto',                  'pto_number',          'pto_status',          'verification_token'),
      ('pto_renewal_requests',        'pto_renewal_request',  '',                    'request_status',      ''),
      ('council_meetings',            'meeting',              'meeting_reference',   'meeting_status',      ''),
      ('meeting_attendance',          'meeting_attendance',   'attendee_name',       'attendance_status',   ''),
      ('meeting_minutes',             'meeting_minutes',      '',                    'minutes_status',      'minutes_content'),
      ('meeting_minutes_amendments',  'minutes_amendment',    'amendment_reference', '',                    'amendment_text'),
      ('council_resolutions',         'resolution',           'resolution_reference','resolution_status',   ''),
      ('community_projects',          'project',              'project_reference',   'project_status',      ''),
      ('project_milestones',          'project_milestone',    'title',               'milestone_status',    ''),
      ('visibility_changes',          'visibility_change',    '',                    '',                    '')
    ) as t(table_name, entity, reference, status, extra)
  loop
    execute format('drop trigger if exists audit_%1$s on public.%1$I', v_spec.table_name);
    execute format(
      'create trigger audit_%1$s after insert or update or delete on public.%1$I ' ||
      'for each row execute function public.tg_audit(%2$L, %3$L, %4$L, %5$L)',
      v_spec.table_name, v_spec.entity, v_spec.reference, v_spec.status, v_spec.extra);
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- 8. Looking at a verification document
--
--    The documents live in a private storage bucket and the browser
--    fetches them with a short-lived signed link. Asking for that link
--    now goes through here, so that the asking is on the record. Only
--    the metadata is: never a byte of the document itself.
-- ---------------------------------------------------------------------

create or replace function public.registry_open_verification_document(
  p_request_id    uuid,
  p_document_type text
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id uuid := public.acting_registry_clerk_staff_id();
  v_document public.resident_request_documents;
  v_request  public.resident_account_requests;
begin
  select * into v_request from public.resident_account_requests where id = p_request_id;
  if not found then
    raise exception 'That verification request could not be found.' using errcode = 'TA050';
  end if;

  select * into v_document from public.resident_request_documents
   where request_id = p_request_id and document_type = p_document_type;
  if not found then
    raise exception 'That document was not submitted with this request.' using errcode = 'TA050';
  end if;

  perform public.audit_event(
    'VIEWED_VERIFICATION_DOCUMENT', 'verification_document', v_document.id,
    v_document.document_type, null,
    jsonb_build_object(
      'document_type',    v_document.document_type,
      'request_id_number', v_request.id_number,
      'applicant',        v_request.first_name || ' ' || v_request.last_name),
    null);

  return jsonb_build_object(
    'storage_path', v_document.storage_path,
    'document_type', v_document.document_type,
    'file_name', v_document.file_name);
end;
$$;

-- ---------------------------------------------------------------------
-- 9. Reading the trail
--
--    The Council Administrator, and nobody else. A Registry Clerk, a
--    Land Officer, a Council Secretary and a resident each get nothing.
-- ---------------------------------------------------------------------

create or replace function public.admin_audit_logs(
  p_from        date default null,
  p_to          date default null,
  p_actor       text default null,   -- name, employee number or email
  p_actor_role  text default null,
  p_action      text default null,
  p_entity_type text default null,
  p_reference   text default null,
  p_limit       int  default 200
)
returns table (
  audit_id uuid, created_at timestamptz, actor_label text, actor_role text,
  action text, entity_type text, entity_id uuid, entity_reference text,
  changed_fields text[], reason text, event_group_id uuid
)
language plpgsql stable security definer set search_path = public, pg_temp
as $$
begin
  if not public.is_active_council_administrator() then
    raise exception 'Only the active Council Administrator may read the audit trail.'
      using errcode = '42501';
  end if;
  return query
    select a.id, a.created_at, a.actor_label, a.actor_role, a.action, a.entity_type,
           a.entity_id, a.entity_reference, a.changed_fields, a.reason, a.event_group_id
    from public.audit_logs a
    left join public.staff s on s.id = a.actor_staff_id
    where (p_from is null or a.created_at >= p_from::timestamptz)
      and (p_to is null or a.created_at < (p_to + 1)::timestamptz)
      and (p_actor_role is null or a.actor_role = p_actor_role)
      and (p_action is null or a.action = p_action)
      and (p_entity_type is null or a.entity_type = p_entity_type)
      and (coalesce(btrim(p_reference), '') = ''
           or a.entity_reference ilike public.like_pattern(p_reference))
      and (coalesce(btrim(p_actor), '') = ''
           or a.actor_label ilike public.like_pattern(p_actor)
           or coalesce(s.employee_number, '') ilike public.like_pattern(p_actor)
           or coalesce(s.email, '') ilike public.like_pattern(p_actor))
    order by a.created_at desc
    limit least(greatest(coalesce(p_limit, 200), 1), 2000);
end;
$$;

create or replace function public.admin_audit_log(p_audit_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_result jsonb;
begin
  if not public.is_active_council_administrator() then
    raise exception 'Only the active Council Administrator may read the audit trail.'
      using errcode = '42501';
  end if;

  select jsonb_build_object(
    'audit_id', a.id, 'created_at', a.created_at,
    'actor_label', a.actor_label, 'actor_role', a.actor_role,
    'actor_account_type', a.actor_account_type,
    'actor_employee_number', s.employee_number,
    'action', a.action, 'entity_type', a.entity_type,
    'entity_id', a.entity_id, 'entity_reference', a.entity_reference,
    'old_values', a.old_values, 'new_values', a.new_values,
    'changed_fields', a.changed_fields, 'reason', a.reason,
    'event_group_id', a.event_group_id,
    -- The other rows written by the same business action.
    'related', coalesce((
      select jsonb_agg(jsonb_build_object(
               'audit_id', b.id, 'action', b.action, 'entity_type', b.entity_type,
               'entity_reference', b.entity_reference) order by b.created_at)
      from public.audit_logs b
      where a.event_group_id is not null
        and b.event_group_id = a.event_group_id and b.id <> a.id), '[]'::jsonb)
  ) into v_result
  from public.audit_logs a
  left join public.staff s on s.id = a.actor_staff_id
  where a.id = p_audit_id;

  if v_result is null then
    raise exception 'That audit record could not be found.' using errcode = 'TA121';
  end if;
  return v_result;
end;
$$;

-- The distinct values behind the filters, so the viewer offers what
-- actually exists rather than a guess.
create or replace function public.admin_audit_filters()
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
begin
  if not public.is_active_council_administrator() then
    raise exception 'Only the active Council Administrator may read the audit trail.'
      using errcode = '42501';
  end if;
  return jsonb_build_object(
    'actions',      coalesce((select jsonb_agg(distinct action order by action) from public.audit_logs), '[]'::jsonb),
    'entity_types', coalesce((select jsonb_agg(distinct entity_type order by entity_type) from public.audit_logs), '[]'::jsonb),
    'actor_roles',  coalesce((select jsonb_agg(distinct actor_role order by actor_role)
                              from public.audit_logs where actor_role is not null), '[]'::jsonb),
    'total',        (select count(*) from public.audit_logs));
end;
$$;

-- ---------------------------------------------------------------------
-- 10. Row Level Security
-- ---------------------------------------------------------------------

alter table public.audit_logs enable row level security;
revoke all on public.audit_logs from anon, authenticated;
grant select on public.audit_logs to authenticated;
grant select, insert on public.audit_logs to service_role;

drop policy if exists audit_logs_administrator_reads on public.audit_logs;
create policy audit_logs_administrator_reads
  on public.audit_logs for select to authenticated
  using (public.is_active_council_administrator());

-- ---------------------------------------------------------------------
-- 11. Grants
-- ---------------------------------------------------------------------

do $$
declare v_signature text;
begin
  foreach v_signature in array array[
    'public.audit_actor()',
    'public.audit_context(text, text, uuid)',
    'public.audit_strip(jsonb, text[])',
    'public.audit_event(text, text, uuid, text, jsonb, jsonb, text)',
    'public.tg_audit()',
    'public.audit_context_value(text)',
    'public.tg_audit_logs_are_immutable()'
  ]
  loop
    execute format('revoke all on function %s from public, anon, authenticated', v_signature);
  end loop;
end;
$$;

do $$
declare v_signature text;
begin
  foreach v_signature in array array[
    'public.admin_audit_logs(date, date, text, text, text, text, text, int)',
    'public.admin_audit_log(uuid)',
    'public.admin_audit_filters()',
    'public.registry_open_verification_document(uuid, text)'
  ]
  loop
    execute format('revoke all on function %s from public, anon, authenticated', v_signature);
    execute format('grant execute on function %s to authenticated', v_signature);
  end loop;
end;
$$;
