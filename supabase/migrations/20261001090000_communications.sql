-- =====================================================================
-- TAMS — official communications and internal staff messaging
--
-- Two separate things that happen to share a delivery mechanism:
--
--   * the Council Secretary writing to residents, officially, on behalf
--     of the Chief or the Traditional Council;
--   * staff writing to each other to get work done across roles that
--     are deliberately kept apart.
--
-- Neither is a chat. Both are records: once sent, the words stand, and
-- a correction is a new message rather than an edit to an old one.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Official communications to residents
-- ---------------------------------------------------------------------

create table if not exists public.resident_communications (
  id                      uuid primary key default gen_random_uuid(),
  communication_reference text not null unique,
  sent_by_staff_id        uuid not null references public.staff (id),
  communication_type      text not null,
  audience_type           text not null,
  subject                 text not null,
  message                 text not null,
  -- Descriptive only. The Chief, a Headman and a Headwoman have no
  -- accounts in TAMS and are not being authenticated here.
  issued_on_behalf_of     text,
  event_date              date,
  event_time              time,
  venue                   text,
  related_entity_type     text,
  related_entity_id       uuid,
  related_reference       text,
  recipient_count         int not null default 0,
  created_at              timestamptz not null default now(),

  constraint resident_communications_type_allowed check (communication_type in (
    'community_announcement', 'individual_notice', 'summons', 'general_notice')),
  constraint resident_communications_audience_allowed check (audience_type in (
    'all_active_residents', 'one_resident', 'selected_residents')),
  constraint resident_communications_subject_not_blank check (btrim(subject) <> ''),
  constraint resident_communications_message_not_blank check (btrim(message) <> ''),
  constraint resident_communications_related_allowed check (
    related_entity_type is null
    or related_entity_type in ('meeting', 'resolution', 'project'))
);

-- Who it actually went to, frozen at the moment it was sent. Somebody
-- verified next month is not retrospectively a recipient of last
-- month's notice.
create table if not exists public.resident_communication_recipients (
  id               uuid primary key default gen_random_uuid(),
  communication_id uuid not null references public.resident_communications (id),
  resident_id      uuid not null references public.residents (id),
  user_account_id  uuid not null references public.user_accounts (id),
  notification_id  uuid references public.notifications (id),
  created_at       timestamptz not null default now(),
  constraint resident_communication_recipient_once unique (communication_id, user_account_id)
);

create index if not exists resident_communication_recipients_account_idx
  on public.resident_communication_recipients (user_account_id);

-- ---------------------------------------------------------------------
-- 2. Internal staff messages
-- ---------------------------------------------------------------------

create table if not exists public.staff_messages (
  id                  uuid primary key default gen_random_uuid(),
  message_reference   text not null unique,
  sender_staff_id     uuid not null references public.staff (id),
  subject             text not null,
  body                text not null,
  message_kind        text not null default 'normal',
  target_type         text not null,
  target_staff_id     uuid references public.staff (id),
  target_role_id      uuid references public.roles (id),

  related_entity_type text,
  related_entity_id   uuid,
  related_reference   text,

  -- Set only on an action_required message.
  action_status           text,
  acknowledged_by_staff_id uuid references public.staff (id),
  acknowledged_at         timestamptz,
  resolved_by_staff_id    uuid references public.staff (id),
  resolved_at             timestamptz,

  created_at          timestamptz not null default now(),

  constraint staff_messages_subject_not_blank check (btrim(subject) <> ''),
  constraint staff_messages_body_not_blank    check (btrim(body) <> ''),
  constraint staff_messages_kind_allowed
    check (message_kind in ('normal', 'action_required', 'announcement')),
  constraint staff_messages_target_allowed
    check (target_type in ('direct', 'role', 'all_staff')),
  constraint staff_messages_target_shape check (
    (target_type = 'direct' and target_staff_id is not null and target_role_id is null)
    or (target_type = 'role' and target_role_id is not null and target_staff_id is null)
    or (target_type = 'all_staff' and target_staff_id is null and target_role_id is null)
  ),
  constraint staff_messages_related_allowed check (
    related_entity_type is null or related_entity_type in (
      'resident', 'household', 'resident_account_request', 'land_application',
      'land_allocation', 'pto', 'meeting', 'resolution', 'project')),
  -- A work request has a lifecycle; an ordinary message has none.
  constraint staff_messages_action_shape check (
    (message_kind = 'action_required' and action_status in ('open', 'acknowledged', 'resolved'))
    or (message_kind <> 'action_required' and action_status is null)
  ),
  constraint staff_messages_acknowledged_shape check (
    action_status is null or action_status = 'open'
    or (acknowledged_by_staff_id is not null and acknowledged_at is not null)
  ),
  constraint staff_messages_resolved_shape check (
    action_status is distinct from 'resolved'
    or (resolved_by_staff_id is not null and resolved_at is not null)
  )
);

create index if not exists staff_messages_sender_idx on public.staff_messages (sender_staff_id, created_at desc);

-- The recipients as they were when the message was sent. A role change
-- tomorrow does not rewrite who was written to today.
create table if not exists public.staff_message_recipients (
  id                uuid primary key default gen_random_uuid(),
  message_id        uuid not null references public.staff_messages (id),
  recipient_staff_id uuid not null references public.staff (id),
  notification_id   uuid references public.notifications (id),
  read_at           timestamptz,
  archived_at       timestamptz,
  created_at        timestamptz not null default now(),
  constraint staff_message_recipient_once unique (message_id, recipient_staff_id)
);

create index if not exists staff_message_recipients_staff_idx
  on public.staff_message_recipients (recipient_staff_id, created_at desc);

-- ---------------------------------------------------------------------
-- 3. Sending an official communication
-- ---------------------------------------------------------------------

create or replace function public.secretary_search_residents(p_search text default null)
returns table (
  resident_id uuid, full_name text, id_number text, household_code text,
  street_address text, has_account boolean
)
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_pattern text := public.like_pattern(p_search);
        v_empty boolean := coalesce(btrim(p_search), '') = '';
begin
  perform public.acting_council_secretary_staff_id();
  return query
    select r.id, r.first_name || ' ' || r.last_name, r.id_number, h.household_code,
           ls.street_address, (public.resident_account_id(r.id) is not null)
    from public.residents r
    left join public.households h on h.id = r.household_id
    left join public.land_sites ls on ls.id = h.residential_site_id
    where r.resident_status = 'active'
      and public.resident_account_id(r.id) is not null
      and (v_empty or r.first_name || ' ' || r.last_name ilike v_pattern
           or r.id_number ilike v_pattern
           or coalesce(h.household_code, '') ilike v_pattern
           or coalesce(ls.street_address, '') ilike v_pattern)
    order by r.last_name, r.first_name
    limit 50;
end;
$$;

create or replace function public.secretary_send_communication(
  p_communication_type text,
  p_audience_type      text,
  p_subject            text,
  p_message            text,
  p_resident_ids       uuid[] default null,
  p_issued_on_behalf_of text default null,
  p_event_date         date default null,
  p_event_time         time default null,
  p_venue              text default null,
  p_related_entity_type text default null,
  p_related_entity_id  uuid default null
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id      uuid := public.acting_council_secretary_staff_id();
  v_communication public.resident_communications;
  v_reference     text;
  v_row           record;
  v_notification  uuid;
  v_count         int := 0;
  v_group         uuid;
  v_related_ref   text;
begin
  if p_communication_type is null or p_communication_type not in (
       'community_announcement', 'individual_notice', 'summons', 'general_notice') then
    raise exception 'That is not a kind of communication TAMS sends.' using errcode = 'TA110';
  end if;
  if p_audience_type is null or p_audience_type not in (
       'all_active_residents', 'one_resident', 'selected_residents') then
    raise exception 'A communication goes to all active residents, one resident, or a selection.'
      using errcode = 'TA111';
  end if;
  if btrim(coalesce(p_subject, '')) = '' or btrim(coalesce(p_message, '')) = '' then
    raise exception 'A communication needs a subject and a message.' using errcode = 'TA112';
  end if;
  if p_audience_type in ('one_resident', 'selected_residents')
     and coalesce(array_length(p_resident_ids, 1), 0) = 0 then
    raise exception 'Choose at least one resident to send this to.' using errcode = 'TA113';
  end if;
  if p_audience_type = 'one_resident' and array_length(p_resident_ids, 1) <> 1 then
    raise exception 'An individual notice goes to exactly one resident.' using errcode = 'TA113';
  end if;

  -- A linked record is referred to by its reference and nothing more.
  -- Linking a meeting never publishes that meeting.
  if p_related_entity_type is not null then
    v_related_ref := case p_related_entity_type
      when 'meeting'    then (select meeting_reference from public.council_meetings where id = p_related_entity_id)
      when 'resolution' then (select resolution_reference from public.council_resolutions where id = p_related_entity_id)
      when 'project'    then (select project_reference from public.community_projects where id = p_related_entity_id)
      end;
    if v_related_ref is null then
      raise exception 'That linked record could not be found.' using errcode = 'TA114';
    end if;
  end if;

  v_reference := public.council_reference('COM-', 'communication_reference', 'resident_communications');
  v_group := public.audit_context('SEND_RESIDENT_COMMUNICATION', null, null);

  insert into public.resident_communications (
    communication_reference, sent_by_staff_id, communication_type, audience_type,
    subject, message, issued_on_behalf_of, event_date, event_time, venue,
    related_entity_type, related_entity_id, related_reference)
  values (
    v_reference, v_staff_id, p_communication_type, p_audience_type,
    btrim(p_subject), btrim(p_message),
    nullif(btrim(coalesce(p_issued_on_behalf_of, '')), ''),
    p_event_date, p_event_time, nullif(btrim(coalesce(p_venue, '')), ''),
    p_related_entity_type, p_related_entity_id, v_related_ref)
  returning * into v_communication;

  -- The recipients, worked out now and written down now. Everything
  -- below reads only accounts that are verified and active at this
  -- moment: pending, declined and deactivated accounts are not
  -- recipients, and never become recipients later.
  for v_row in
    select r.id as resident_id, ua.id as account_id
    from public.residents r
    join public.user_accounts ua on ua.resident_id = r.id
    where ua.account_type = 'resident'
      and ua.account_status = 'active'
      and r.resident_status = 'active'
      and (p_audience_type = 'all_active_residents' or r.id = any (p_resident_ids))
  loop
    v_notification := public.notify_user(
      v_row.account_id, 'official_notice',
      v_communication.subject,
      v_communication.message
        || case when v_communication.event_date is not null
                then E'\n\nDate: ' || to_char(v_communication.event_date, 'DD Mon YYYY') else '' end
        || case when v_communication.event_time is not null
                then E'\nTime: ' || to_char(v_communication.event_time, 'HH24:MI') else '' end
        || case when v_communication.venue is not null
                then E'\nVenue: ' || v_communication.venue else '' end
        || case when v_communication.issued_on_behalf_of is not null
                then E'\n\nIssued on behalf of: ' || v_communication.issued_on_behalf_of else '' end,
      '/resident/notifications', 'resident_communication', v_communication.id, v_reference);

    insert into public.resident_communication_recipients (
      communication_id, resident_id, user_account_id, notification_id)
    values (v_communication.id, v_row.resident_id, v_row.account_id, v_notification)
    on conflict (communication_id, user_account_id) do nothing;

    v_count := v_count + 1;
  end loop;

  update public.resident_communications set recipient_count = v_count
   where id = v_communication.id;

  return jsonb_build_object(
    'communication_id', v_communication.id,
    'communication_reference', v_reference,
    'recipient_count', v_count,
    'event_group_id', v_group);
end;
$$;

create or replace function public.secretary_communications(
  p_type text default null,
  p_search text default null
)
returns table (
  communication_id uuid, communication_reference text, communication_type text,
  audience_type text, subject text, message text, issued_on_behalf_of text,
  event_date date, event_time time, venue text, related_reference text,
  recipient_count int, created_at timestamptz, sent_by text
)
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_pattern text := public.like_pattern(p_search);
        v_empty boolean := coalesce(btrim(p_search), '') = '';
begin
  perform public.acting_council_secretary_staff_id();
  return query
    select c.id, c.communication_reference, c.communication_type, c.audience_type,
           c.subject, c.message, c.issued_on_behalf_of, c.event_date, c.event_time,
           c.venue, c.related_reference, c.recipient_count, c.created_at,
           s.first_name || ' ' || s.last_name
    from public.resident_communications c
    join public.staff s on s.id = c.sent_by_staff_id
    where (p_type is null or c.communication_type = p_type)
      and (v_empty or c.communication_reference ilike v_pattern or c.subject ilike v_pattern)
    order by c.created_at desc;
end;
$$;

create or replace function public.secretary_communication_recipients(p_communication_id uuid)
returns table (full_name text, id_number text, household_code text, read_at timestamptz)
language plpgsql stable security definer set search_path = public, pg_temp
as $$
begin
  perform public.acting_council_secretary_staff_id();
  return query
    select r.first_name || ' ' || r.last_name, r.id_number, h.household_code, n.read_at
    from public.resident_communication_recipients cr
    join public.residents r on r.id = cr.resident_id
    left join public.households h on h.id = r.household_id
    left join public.notifications n on n.id = cr.notification_id
    where cr.communication_id = p_communication_id
    order by r.last_name, r.first_name;
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Staff messaging
-- ---------------------------------------------------------------------

create or replace function public.acting_staff_id()
returns uuid
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_staff_id uuid;
begin
  select ua.staff_id into v_staff_id
  from public.user_accounts ua
  where ua.auth_user_id = auth.uid()
    and ua.account_type = 'staff'
    and ua.account_status = 'active'
    and ua.staff_id is not null;

  if v_staff_id is null then
    raise exception 'Only an active staff member may use internal messaging.'
      using errcode = '42501';
  end if;
  return v_staff_id;
end;
$$;

create or replace function public.staff_role_name(p_staff_id uuid)
returns text
language sql stable security definer set search_path = public, pg_temp
as $$
  select r.role_name from public.staff s join public.roles r on r.id = s.role_id
  where s.id = p_staff_id;
$$;

create or replace function public.staff_send_message(
  p_subject             text,
  p_body                text,
  p_target_type         text,
  p_message_kind        text default 'normal',
  p_target_staff_id     uuid default null,
  p_target_role_id      uuid default null,
  p_related_entity_type text default null,
  p_related_entity_id   uuid default null
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_sender      uuid := public.acting_staff_id();
  v_sender_role text := public.staff_role_name(v_sender);
  v_message     public.staff_messages;
  v_reference   text;
  v_related_ref text;
  v_row         record;
  v_count       int := 0;
  v_group       uuid;
  v_notification uuid;
begin
  if btrim(coalesce(p_subject, '')) = '' or btrim(coalesce(p_body, '')) = '' then
    raise exception 'A message needs a subject and a body.' using errcode = 'TA115';
  end if;
  if p_target_type is null or p_target_type not in ('direct', 'role', 'all_staff') then
    raise exception 'A message goes to one staff member, to a role, or to all staff.'
      using errcode = 'TA116';
  end if;
  if p_message_kind is null or p_message_kind not in ('normal', 'action_required', 'announcement') then
    raise exception 'A message is normal, action required, or an announcement.' using errcode = 'TA117';
  end if;

  -- An announcement to everybody is the Council Administrator's or the
  -- Council Secretary's to make.
  if p_target_type = 'all_staff'
     and v_sender_role not in ('Council Administrator', 'Council Secretary') then
    raise exception 'Only the Council Administrator or the Council Secretary may write to all staff.'
      using errcode = '42501';
  end if;

  if p_target_type = 'direct' then
    if p_target_staff_id is null then
      raise exception 'Choose the staff member to write to.' using errcode = 'TA116';
    end if;
    if p_target_staff_id = v_sender then
      raise exception 'There is no point writing to yourself.' using errcode = 'TA116';
    end if;
    if public.staff_account_id(p_target_staff_id) is null then
      raise exception 'That staff member''s account is not active.' using errcode = 'TA118';
    end if;
  elsif p_target_type = 'role' then
    if p_target_role_id is null
       or not exists (select 1 from public.roles where id = p_target_role_id) then
      raise exception 'Choose the role to write to.' using errcode = 'TA116';
    end if;
  end if;

  -- A link is a reference, never a key. It grants the recipient nothing
  -- at all; whether they may open it is decided where that record
  -- lives, exactly as it was before the message existed.
  if p_related_entity_type is not null then
    v_related_ref := case p_related_entity_type
      when 'resident'                 then (select id_number from public.residents where id = p_related_entity_id)
      when 'household'                then (select household_code from public.households where id = p_related_entity_id)
      when 'resident_account_request' then (select id_number from public.resident_account_requests where id = p_related_entity_id)
      when 'land_application'         then (select application_reference from public.land_applications where id = p_related_entity_id)
      when 'land_allocation'          then (select allocation_reference from public.land_allocations where id = p_related_entity_id)
      when 'pto'                      then (select pto_number from public.ptos where id = p_related_entity_id)
      when 'meeting'                  then (select meeting_reference from public.council_meetings where id = p_related_entity_id)
      when 'resolution'               then (select resolution_reference from public.council_resolutions where id = p_related_entity_id)
      when 'project'                  then (select project_reference from public.community_projects where id = p_related_entity_id)
      end;
    if v_related_ref is null then
      raise exception 'That linked record could not be found.' using errcode = 'TA114';
    end if;
  end if;

  v_reference := public.council_reference('MSG-', 'message_reference', 'staff_messages');
  v_group := public.audit_context('SEND_STAFF_MESSAGE', null, null);

  insert into public.staff_messages (
    message_reference, sender_staff_id, subject, body, message_kind, target_type,
    target_staff_id, target_role_id, related_entity_type, related_entity_id,
    related_reference, action_status)
  values (
    v_reference, v_sender, btrim(p_subject), btrim(p_body), p_message_kind, p_target_type,
    p_target_staff_id, p_target_role_id, p_related_entity_type, p_related_entity_id,
    v_related_ref,
    case when p_message_kind = 'action_required' then 'open' end)
  returning * into v_message;

  -- The recipients as they are now. Whoever holds the role tomorrow is
  -- not retrospectively a recipient of this.
  for v_row in
    select s.id as staff_id, ua.id as account_id
    from public.staff s
    join public.user_accounts ua on ua.staff_id = s.id
    where ua.account_type = 'staff'
      and ua.account_status = 'active'
      and s.id <> v_sender
      and (p_target_type = 'all_staff'
           or (p_target_type = 'direct' and s.id = p_target_staff_id)
           or (p_target_type = 'role' and s.role_id = p_target_role_id))
  loop
    -- The alert says who wrote, about what, and how urgent. The body
    -- itself stays inside TAMS; an email inbox is not the place for it.
    v_notification := public.notify_user(
      v_row.account_id,
      case when p_message_kind = 'action_required' then 'work_request' else 'staff_message' end,
      case when p_message_kind = 'action_required' then 'Action required: ' else '' end
        || v_message.subject,
      (select s.first_name || ' ' || s.last_name from public.staff s where s.id = v_sender)
        || ' (' || v_sender_role || ') has sent you '
        || case p_message_kind
             when 'action_required' then 'a work request'
             when 'announcement'    then 'an announcement'
             else 'a message' end
        || ' in TAMS'
        || case when v_related_ref is not null then ' about ' || v_related_ref else '' end
        || '. Open TAMS to read it.',
      '/messages/' || v_message.id::text, 'staff_message', v_message.id, v_reference);

    insert into public.staff_message_recipients (message_id, recipient_staff_id, notification_id)
    values (v_message.id, v_row.staff_id, v_notification)
    on conflict (message_id, recipient_staff_id) do nothing;

    v_count := v_count + 1;
  end loop;

  if v_count = 0 then
    raise exception 'There is nobody active to send that to.' using errcode = 'TA118';
  end if;

  return jsonb_build_object(
    'message_id', v_message.id, 'message_reference', v_reference,
    'recipient_count', v_count, 'event_group_id', v_group);
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Work requests
--
--    A role request goes to everybody who holds that role, and the
--    first of them to acknowledge it claims it. The row is locked for
--    the duration, so two people pressing at the same moment cannot
--    both win: the second one is told who did.
-- ---------------------------------------------------------------------

create or replace function public.staff_acknowledge_request(p_message_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff   uuid := public.acting_staff_id();
  v_message public.staff_messages;
begin
  select * into v_message from public.staff_messages where id = p_message_id for update;
  if not found then
    raise exception 'That message could not be found.' using errcode = 'TA119';
  end if;
  if not exists (select 1 from public.staff_message_recipients
                  where message_id = v_message.id and recipient_staff_id = v_staff) then
    raise exception 'That work request was not sent to you.' using errcode = '42501';
  end if;
  if v_message.message_kind <> 'action_required' then
    raise exception 'That message is not a work request.' using errcode = 'TA119';
  end if;
  if v_message.action_status <> 'open' then
    raise exception 'That work request has already been claimed by %.',
      coalesce((select s.first_name || ' ' || s.last_name from public.staff s
                 where s.id = v_message.acknowledged_by_staff_id), 'somebody else')
      using errcode = 'TA119';
  end if;

  perform public.audit_context('ACKNOWLEDGE_WORK_REQUEST', null, null);

  update public.staff_messages
     set action_status = 'acknowledged',
         acknowledged_by_staff_id = v_staff, acknowledged_at = now()
   where id = v_message.id
  returning * into v_message;

  perform public.notify_user(
    public.staff_account_id(v_message.sender_staff_id), 'work_request',
    'Work request ' || v_message.message_reference || ' has been acknowledged',
    (select s.first_name || ' ' || s.last_name from public.staff s where s.id = v_staff)
      || ' has taken on "' || v_message.subject || '".',
    '/messages/' || v_message.id::text, 'staff_message', v_message.id, v_message.message_reference);

  return jsonb_build_object(
    'message_reference', v_message.message_reference,
    'action_status', v_message.action_status,
    'acknowledged_by', (select s.first_name || ' ' || s.last_name from public.staff s where s.id = v_staff));
end;
$$;

create or replace function public.staff_resolve_request(p_message_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff   uuid := public.acting_staff_id();
  v_message public.staff_messages;
begin
  select * into v_message from public.staff_messages where id = p_message_id for update;
  if not found then
    raise exception 'That message could not be found.' using errcode = 'TA119';
  end if;
  if v_message.message_kind <> 'action_required' then
    raise exception 'That message is not a work request.' using errcode = 'TA119';
  end if;
  if v_message.action_status = 'open' then
    raise exception 'That work request has not been acknowledged yet.' using errcode = 'TA119';
  end if;
  if v_message.action_status = 'resolved' then
    raise exception 'That work request is already resolved.' using errcode = 'TA119';
  end if;
  -- Only whoever took it on may put it down.
  if v_message.acknowledged_by_staff_id <> v_staff then
    raise exception 'That work request belongs to %.',
      coalesce((select s.first_name || ' ' || s.last_name from public.staff s
                 where s.id = v_message.acknowledged_by_staff_id), 'somebody else')
      using errcode = '42501';
  end if;

  perform public.audit_context('RESOLVE_WORK_REQUEST', null, null);

  update public.staff_messages
     set action_status = 'resolved', resolved_by_staff_id = v_staff, resolved_at = now()
   where id = v_message.id
  returning * into v_message;

  perform public.notify_user(
    public.staff_account_id(v_message.sender_staff_id), 'work_request',
    'Work request ' || v_message.message_reference || ' has been resolved',
    (select s.first_name || ' ' || s.last_name from public.staff s where s.id = v_staff)
      || ' has resolved "' || v_message.subject || '".',
    '/messages/' || v_message.id::text, 'staff_message', v_message.id, v_message.message_reference);

  return jsonb_build_object(
    'message_reference', v_message.message_reference,
    'action_status', v_message.action_status);
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Reading messages
-- ---------------------------------------------------------------------

create or replace function public.staff_messages_list(p_box text default 'inbox')
returns table (
  message_id uuid, message_reference text, subject text, message_kind text,
  target_type text, related_entity_type text, related_reference text,
  action_status text, created_at timestamptz,
  sender_name text, sender_role text,
  read_at timestamptz, archived_at timestamptz, recipient_count int,
  acknowledged_by text, resolved_by text
)
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_staff uuid := public.acting_staff_id();
begin
  return query
    select m.id, m.message_reference, m.subject, m.message_kind, m.target_type,
           m.related_entity_type, m.related_reference, m.action_status, m.created_at,
           s.first_name || ' ' || s.last_name, r.role_name,
           mr.read_at, mr.archived_at,
           (select count(*)::int from public.staff_message_recipients x where x.message_id = m.id),
           (select a.first_name || ' ' || a.last_name from public.staff a where a.id = m.acknowledged_by_staff_id),
           (select b.first_name || ' ' || b.last_name from public.staff b where b.id = m.resolved_by_staff_id)
    from public.staff_messages m
    join public.staff s on s.id = m.sender_staff_id
    left join public.roles r on r.id = s.role_id
    left join public.staff_message_recipients mr
      on mr.message_id = m.id and mr.recipient_staff_id = v_staff
    where (p_box = 'sent' and m.sender_staff_id = v_staff)
       or (p_box = 'inbox' and mr.id is not null and mr.archived_at is null)
       or (p_box = 'archived' and mr.id is not null and mr.archived_at is not null)
    order by m.created_at desc;
end;
$$;

create or replace function public.staff_message(p_message_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare
  v_staff  uuid := public.acting_staff_id();
  v_result jsonb;
begin
  select jsonb_build_object(
    'message_id', m.id, 'message_reference', m.message_reference,
    'subject', m.subject, 'body', m.body, 'message_kind', m.message_kind,
    'target_type', m.target_type, 'created_at', m.created_at,
    'sender_name', s.first_name || ' ' || s.last_name,
    'sender_role', r.role_name,
    'is_sender', (m.sender_staff_id = v_staff),
    'target_role', (select ro.role_name from public.roles ro where ro.id = m.target_role_id),
    'related_entity_type', m.related_entity_type,
    'related_entity_id', m.related_entity_id,
    'related_reference', m.related_reference,
    'action_status', m.action_status,
    'acknowledged_by', (select a.first_name || ' ' || a.last_name from public.staff a
                         where a.id = m.acknowledged_by_staff_id),
    'acknowledged_at', m.acknowledged_at,
    'acknowledged_by_me', (m.acknowledged_by_staff_id = v_staff),
    'resolved_by', (select b.first_name || ' ' || b.last_name from public.staff b
                     where b.id = m.resolved_by_staff_id),
    'resolved_at', m.resolved_at,
    'am_recipient', exists (select 1 from public.staff_message_recipients x
                             where x.message_id = m.id and x.recipient_staff_id = v_staff),
    'read_at', (select x.read_at from public.staff_message_recipients x
                 where x.message_id = m.id and x.recipient_staff_id = v_staff),
    'archived_at', (select x.archived_at from public.staff_message_recipients x
                     where x.message_id = m.id and x.recipient_staff_id = v_staff),
    'recipients', coalesce((
      select jsonb_agg(jsonb_build_object(
               'name', rs.first_name || ' ' || rs.last_name,
               'role', rr.role_name,
               'read_at', x.read_at) order by rs.last_name)
      from public.staff_message_recipients x
      join public.staff rs on rs.id = x.recipient_staff_id
      left join public.roles rr on rr.id = rs.role_id
      where x.message_id = m.id), '[]'::jsonb)
  ) into v_result
  from public.staff_messages m
  join public.staff s on s.id = m.sender_staff_id
  left join public.roles r on r.id = s.role_id
  where m.id = p_message_id
    and (m.sender_staff_id = v_staff
         or exists (select 1 from public.staff_message_recipients x
                     where x.message_id = m.id and x.recipient_staff_id = v_staff));

  if v_result is null then
    raise exception 'That message is not yours to read.' using errcode = '42501';
  end if;

  return v_result;
end;
$$;

create or replace function public.staff_mark_message_read(p_message_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare v_staff uuid := public.acting_staff_id();
        v_updated int;
begin
  update public.staff_message_recipients set read_at = coalesce(read_at, now())
   where message_id = p_message_id and recipient_staff_id = v_staff;
  get diagnostics v_updated = row_count;
  if v_updated = 0 then
    raise exception 'That message was not sent to you.' using errcode = '42501';
  end if;
  return jsonb_build_object('message_id', p_message_id, 'read', true);
end;
$$;

-- Archiving takes the recipient's own copy out of their inbox. The
-- message itself is untouched, and stays in everybody else's.
create or replace function public.staff_archive_message(p_message_id uuid, p_archived boolean default true)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare v_staff uuid := public.acting_staff_id();
        v_updated int;
begin
  update public.staff_message_recipients
     set archived_at = case when p_archived then coalesce(archived_at, now()) else null end,
         read_at = case when p_archived then coalesce(read_at, now()) else read_at end
   where message_id = p_message_id and recipient_staff_id = v_staff;
  get diagnostics v_updated = row_count;
  if v_updated = 0 then
    raise exception 'That message was not sent to you.' using errcode = '42501';
  end if;
  return jsonb_build_object('message_id', p_message_id, 'archived', p_archived);
end;
$$;

-- Who a message may be addressed to: active staff, and the roles.
create or replace function public.staff_message_targets()
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_staff uuid := public.acting_staff_id();
begin
  return jsonb_build_object(
    'may_announce', public.staff_role_name(v_staff) in ('Council Administrator', 'Council Secretary'),
    'staff', coalesce((
      select jsonb_agg(jsonb_build_object(
               'staff_id', s.id,
               'full_name', s.first_name || ' ' || s.last_name,
               'role', r.role_name) order by s.last_name, s.first_name)
      from public.staff s
      join public.roles r on r.id = s.role_id
      join public.user_accounts ua on ua.staff_id = s.id
      where ua.account_status = 'active' and s.id <> v_staff), '[]'::jsonb),
    'roles', coalesce((
      select jsonb_agg(jsonb_build_object(
               'role_id', r.id, 'role_name', r.role_name,
               'active_members', (select count(*) from public.staff s2
                                   join public.user_accounts u2 on u2.staff_id = s2.id
                                   where s2.role_id = r.id and u2.account_status = 'active'))
             order by r.role_name)
      from public.roles r), '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Row Level Security
-- ---------------------------------------------------------------------

do $$
declare v_table text;
begin
  foreach v_table in array array[
    'resident_communications', 'resident_communication_recipients',
    'staff_messages', 'staff_message_recipients'
  ]
  loop
    execute format('alter table public.%I enable row level security', v_table);
    execute format('alter table public.%I force row level security', v_table);
    execute format('revoke all on public.%I from anon, authenticated', v_table);
    execute format('grant select on public.%I to authenticated', v_table);
    execute format('grant all on public.%I to service_role', v_table);
  end loop;
end;
$$;

-- The Secretary reads what they have sent. A resident does not read
-- this table at all: their copy is the notification.
drop policy if exists resident_communications_secretary on public.resident_communications;
create policy resident_communications_secretary
  on public.resident_communications for select to authenticated
  using (public.is_active_council_secretary());

drop policy if exists resident_communication_recipients_secretary on public.resident_communication_recipients;
create policy resident_communication_recipients_secretary
  on public.resident_communication_recipients for select to authenticated
  using (public.is_active_council_secretary()
         or user_account_id = public.current_user_account_id());

-- Read through a definer helper rather than through each other's
-- policies: two policies that each consult the other table recurse, and
-- Postgres refuses the query outright.
create or replace function public.staff_message_ids_for_me()
returns setof uuid
language sql stable security definer set search_path = public, pg_temp
as $$
  select m.id from public.staff_messages m
  where m.sender_staff_id = (select ua.staff_id from public.user_accounts ua
                              where ua.auth_user_id = auth.uid() and ua.account_status = 'active')
  union
  select x.message_id from public.staff_message_recipients x
  where x.recipient_staff_id = (select ua.staff_id from public.user_accounts ua
                                 where ua.auth_user_id = auth.uid() and ua.account_status = 'active');
$$;

-- A staff message is readable by the person who wrote it and by the
-- people it was actually sent to. The Council Administrator gets no
-- special key to other people's post.
drop policy if exists staff_messages_sender_or_recipient on public.staff_messages;
create policy staff_messages_sender_or_recipient
  on public.staff_messages for select to authenticated
  using (id in (select public.staff_message_ids_for_me()));

drop policy if exists staff_message_recipients_own on public.staff_message_recipients;
create policy staff_message_recipients_own
  on public.staff_message_recipients for select to authenticated
  using (message_id in (select public.staff_message_ids_for_me()));

-- Addressing an official notice means finding the person it is for.
-- The Secretary reads the register for that, and writes none of it:
-- every change to a resident or a household is still the Registry
-- Clerk's alone.
drop policy if exists residents_readable_by_council_secretary on public.residents;
create policy residents_readable_by_council_secretary
  on public.residents for select to authenticated
  using (public.is_active_council_secretary());

drop policy if exists households_readable_by_council_secretary on public.households;
create policy households_readable_by_council_secretary
  on public.households for select to authenticated
  using (public.is_active_council_secretary());

drop policy if exists land_sites_readable_by_council_secretary on public.land_sites;
create policy land_sites_readable_by_council_secretary
  on public.land_sites for select to authenticated
  using (public.is_active_council_secretary());

-- ---------------------------------------------------------------------
-- 8. Audit triggers for the two new records
--
--    Metadata only. The body of a private staff message and the wording
--    of an official notice are not copied into the audit trail.
-- ---------------------------------------------------------------------

drop trigger if exists audit_resident_communications on public.resident_communications;
create trigger audit_resident_communications
  after insert or update or delete on public.resident_communications
  for each row execute function public.tg_audit(
    'resident_communication', 'communication_reference', '', 'subject,message');

drop trigger if exists audit_staff_messages on public.staff_messages;
create trigger audit_staff_messages
  after insert or update or delete on public.staff_messages
  for each row execute function public.tg_audit(
    'staff_message', 'message_reference', 'action_status', 'subject,body');

-- ---------------------------------------------------------------------
-- 9. Grants
-- ---------------------------------------------------------------------

do $$
declare v_signature text;
begin
  foreach v_signature in array array[
    'public.secretary_search_residents(text)',
    'public.secretary_send_communication(text, text, text, text, uuid[], text, date, time, text, text, uuid)',
    'public.secretary_communications(text, text)',
    'public.secretary_communication_recipients(uuid)',
    'public.staff_send_message(text, text, text, text, uuid, uuid, text, uuid)',
    'public.staff_acknowledge_request(uuid)',
    'public.staff_resolve_request(uuid)',
    'public.staff_messages_list(text)',
    'public.staff_message(uuid)',
    'public.staff_mark_message_read(uuid)',
    'public.staff_archive_message(uuid, boolean)',
    'public.staff_message_targets()'
  ]
  loop
    execute format('revoke all on function %s from public, anon, authenticated', v_signature);
    execute format('grant execute on function %s to authenticated', v_signature);
  end loop;
end;
$$;

revoke all on function public.acting_staff_id() from public, anon, authenticated;
revoke all on function public.staff_role_name(uuid) from public, anon, authenticated;
revoke all on function public.staff_message_ids_for_me() from public, anon;
-- Used inside a policy, so the querying role must be able to run it.
grant execute on function public.staff_message_ids_for_me() to authenticated;
