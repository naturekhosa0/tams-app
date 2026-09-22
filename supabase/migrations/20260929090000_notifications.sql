-- =====================================================================
-- TAMS — one notification system for the whole application
--
-- Every important thing that happens to somebody is written down as an
-- in-app notification, and an email is queued for it separately. The
-- in-app notification is the authoritative one: it is created inside the
-- same transaction as the business action, so it cannot go missing,
-- while the email is a best effort that is allowed to fail without
-- undoing anything.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Notifications
-- ---------------------------------------------------------------------

create table if not exists public.notifications (
  id                        uuid primary key default gen_random_uuid(),
  recipient_user_account_id uuid not null references public.user_accounts (id) on delete cascade,
  notification_category     text not null,
  title                     text not null,
  message                   text not null,
  -- Where in TAMS this notification is about, if anywhere. Always an
  -- application path, never an external link.
  link_path                 text,
  source_entity_type        text,
  source_entity_id          uuid,
  source_reference          text,
  created_at                timestamptz not null default now(),
  read_at                   timestamptz,
  archived_at               timestamptz,

  constraint notifications_category_allowed check (notification_category in (
    'account', 'land_application', 'land_allocation', 'pto', 'pto_renewal',
    'community', 'official_notice', 'staff_message', 'work_request', 'administration')),
  constraint notifications_title_not_blank   check (btrim(title) <> ''),
  constraint notifications_message_not_blank check (btrim(message) <> ''),
  -- An application path and nothing that could send somebody elsewhere.
  constraint notifications_link_is_internal
    check (link_path is null or link_path ~ '^/[A-Za-z0-9/_.:-]*$')
);

create index if not exists notifications_recipient_idx
  on public.notifications (recipient_user_account_id, created_at desc);
create index if not exists notifications_unread_idx
  on public.notifications (recipient_user_account_id)
  where read_at is null and archived_at is null;

-- ---------------------------------------------------------------------
-- 2. Email delivery
--
--    One row per notification, at most. The unique constraint is what
--    stops a second queueing attempt creating a second email.
-- ---------------------------------------------------------------------

create table if not exists public.notification_email_deliveries (
  id                  uuid primary key default gen_random_uuid(),
  notification_id     uuid not null unique references public.notifications (id) on delete cascade,
  recipient_email     text not null,
  delivery_status     text not null default 'pending',
  attempt_count       int not null default 0,
  last_attempt_at     timestamptz,
  sent_at             timestamptz,
  provider_message_id text,
  -- Short, safe text. Never a provider key, never a stack trace.
  last_error          text,
  created_at          timestamptz not null default now(),

  constraint notification_email_status_allowed
    check (delivery_status in ('pending', 'sent', 'failed')),
  constraint notification_email_sent_shape
    check (delivery_status <> 'sent' or sent_at is not null)
);

create index if not exists notification_email_pending_idx
  on public.notification_email_deliveries (delivery_status, last_attempt_at)
  where delivery_status <> 'sent';

-- ---------------------------------------------------------------------
-- 3. Permission-to-occupy expiry warnings
--
--    One row per permission per threshold. The unique constraint is the
--    whole idempotency mechanism: a threshold can be reached many times
--    by a scheduled run, and only the first one writes anything.
-- ---------------------------------------------------------------------

create table if not exists public.pto_expiry_warnings (
  id              uuid primary key default gen_random_uuid(),
  pto_id          uuid not null references public.ptos (id) on delete cascade,
  threshold_days  int not null,
  notification_id uuid references public.notifications (id),
  expiry_date     date not null,
  created_at      timestamptz not null default now(),

  constraint pto_expiry_threshold_allowed check (threshold_days in (60, 30, 7)),
  constraint pto_expiry_warning_once unique (pto_id, threshold_days)
);

-- ---------------------------------------------------------------------
-- 4. Writing a notification
--
--    Internal only. `notify_user` is the single door: nothing else in
--    TAMS inserts into notifications, and no application role may
--    execute it, so nobody can invent a notification that looks like a
--    system event.
-- ---------------------------------------------------------------------

create or replace function public.notify_user(
  p_user_account_id uuid,
  p_category        text,
  p_title           text,
  p_message         text,
  p_link_path       text default null,
  p_entity_type     text default null,
  p_entity_id       uuid default null,
  p_reference       text default null
)
returns uuid
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_account      public.user_accounts;
  v_notification public.notifications;
begin
  if p_user_account_id is null then return null; end if;

  select * into v_account from public.user_accounts where id = p_user_account_id;
  if not found then return null; end if;

  insert into public.notifications (
    recipient_user_account_id, notification_category, title, message,
    link_path, source_entity_type, source_entity_id, source_reference)
  values (
    v_account.id, p_category, btrim(p_title), btrim(p_message),
    p_link_path, p_entity_type, p_entity_id, p_reference)
  returning * into v_notification;

  -- The email is queued, never sent from here. A database transaction
  -- must never wait on an email provider, and must never be undone by
  -- one being down.
  insert into public.notification_email_deliveries (notification_id, recipient_email)
  values (v_notification.id, v_account.email)
  on conflict (notification_id) do nothing;

  return v_notification.id;
end;
$$;

-- The account behind a resident, when they have a working one.
create or replace function public.resident_account_id(p_resident_id uuid)
returns uuid
language sql stable security definer set search_path = public, pg_temp
as $$
  select ua.id from public.user_accounts ua
  where ua.resident_id = p_resident_id
    and ua.account_type = 'resident'
    and ua.account_status = 'active'
  limit 1;
$$;

-- The account behind the head of a household, when they have one.
create or replace function public.household_head_account_id(p_household_id uuid)
returns uuid
language sql stable security definer set search_path = public, pg_temp
as $$
  select public.resident_account_id(h.head_resident_id)
  from public.households h where h.id = p_household_id;
$$;

create or replace function public.staff_account_id(p_staff_id uuid)
returns uuid
language sql stable security definer set search_path = public, pg_temp
as $$
  select ua.id from public.user_accounts ua
  where ua.staff_id = p_staff_id
    and ua.account_type = 'staff'
    and ua.account_status = 'active'
  limit 1;
$$;

-- ---------------------------------------------------------------------
-- 5. What a recipient may do with their own notifications
-- ---------------------------------------------------------------------

create or replace function public.current_user_account_id()
returns uuid
language sql stable security definer set search_path = public, pg_temp
as $$
  select id from public.user_accounts
  where auth_user_id = auth.uid() and account_status = 'active';
$$;

create or replace function public.my_notifications(
  p_scope text default 'inbox',    -- 'inbox', 'archived' or 'all'
  p_limit int default 100
)
returns table (
  notification_id uuid, notification_category text, title text, message text,
  link_path text, source_entity_type text, source_reference text,
  created_at timestamptz, read_at timestamptz, archived_at timestamptz
)
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_account uuid := public.current_user_account_id();
begin
  if v_account is null then
    raise exception 'Notifications are for signed-in accounts.' using errcode = '42501';
  end if;
  return query
    select n.id, n.notification_category, n.title, n.message, n.link_path,
           n.source_entity_type, n.source_reference, n.created_at, n.read_at, n.archived_at
    from public.notifications n
    where n.recipient_user_account_id = v_account
      and (p_scope = 'all'
           or (p_scope = 'inbox' and n.archived_at is null)
           or (p_scope = 'archived' and n.archived_at is not null))
    order by n.created_at desc
    limit least(greatest(coalesce(p_limit, 100), 1), 500);
end;
$$;

create or replace function public.my_unread_notification_count()
returns int
language sql stable security definer set search_path = public, pg_temp
as $$
  select count(*)::int from public.notifications n
  where n.recipient_user_account_id = public.current_user_account_id()
    and n.read_at is null and n.archived_at is null;
$$;

-- Marking read and archiving touch only those two columns, and only on
-- the caller's own rows. There is no way in here to change a title, a
-- message, a link or a source: those are the system's, not the
-- recipient's.
create or replace function public.mark_notification_read(p_notification_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare v_account uuid := public.current_user_account_id();
        v_updated int;
begin
  if v_account is null then
    raise exception 'Notifications are for signed-in accounts.' using errcode = '42501';
  end if;
  update public.notifications set read_at = coalesce(read_at, now())
   where id = p_notification_id and recipient_user_account_id = v_account;
  get diagnostics v_updated = row_count;
  if v_updated = 0 then
    raise exception 'That notification is not yours.' using errcode = '42501';
  end if;
  return jsonb_build_object('notification_id', p_notification_id, 'read', true);
end;
$$;

create or replace function public.mark_all_notifications_read()
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare v_account uuid := public.current_user_account_id();
        v_updated int;
begin
  if v_account is null then
    raise exception 'Notifications are for signed-in accounts.' using errcode = '42501';
  end if;
  update public.notifications set read_at = now()
   where recipient_user_account_id = v_account and read_at is null and archived_at is null;
  get diagnostics v_updated = row_count;
  return jsonb_build_object('marked_read', v_updated);
end;
$$;

-- Archiving takes a notification out of the everyday inbox. It is not a
-- deletion: the row and its history stay exactly where they are.
create or replace function public.archive_notification(p_notification_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare v_account uuid := public.current_user_account_id();
        v_updated int;
begin
  if v_account is null then
    raise exception 'Notifications are for signed-in accounts.' using errcode = '42501';
  end if;
  update public.notifications
     set archived_at = coalesce(archived_at, now()), read_at = coalesce(read_at, now())
   where id = p_notification_id and recipient_user_account_id = v_account;
  get diagnostics v_updated = row_count;
  if v_updated = 0 then
    raise exception 'That notification is not yours.' using errcode = '42501';
  end if;
  return jsonb_build_object('notification_id', p_notification_id, 'archived', true);
end;
$$;

-- ---------------------------------------------------------------------
-- 6. The email worker's own doors
--
--    Only service_role may execute these: the worker runs as an edge
--    function with the service key, never as a browser.
-- ---------------------------------------------------------------------

-- Hands the worker a batch and records the attempt in the same
-- statement, so two workers running at once cannot take the same row.
create or replace function public.claim_notification_emails(
  p_limit        int default 25,
  p_max_attempts int default 5,
  p_retry_after  interval default interval '10 minutes'
)
returns table (
  delivery_id uuid, notification_id uuid, recipient_email text,
  title text, message text, link_path text, notification_category text, attempt_count int
)
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
begin
  return query
    with claimed as (
      select d.id
      from public.notification_email_deliveries d
      where d.delivery_status <> 'sent'
        and d.attempt_count < greatest(coalesce(p_max_attempts, 5), 1)
        and (d.last_attempt_at is null or d.last_attempt_at < now() - p_retry_after)
      order by d.created_at
      limit least(greatest(coalesce(p_limit, 25), 1), 200)
      for update skip locked
    )
    update public.notification_email_deliveries d
       set attempt_count = d.attempt_count + 1,
           last_attempt_at = now(),
           delivery_status = 'pending'
     from claimed c, public.notifications n
    where d.id = c.id and n.id = d.notification_id
    returning d.id, n.id, d.recipient_email, n.title, n.message, n.link_path,
              n.notification_category, d.attempt_count;
end;
$$;

create or replace function public.mark_notification_email_sent(
  p_delivery_id uuid,
  p_provider_message_id text default null
)
returns void
language sql volatile security definer set search_path = public, pg_temp
as $$
  update public.notification_email_deliveries
     set delivery_status = 'sent', sent_at = now(),
         provider_message_id = p_provider_message_id, last_error = null
   where id = p_delivery_id and delivery_status <> 'sent';
$$;

-- The error text is trimmed hard on the way in. Nothing a provider says
-- is allowed to become a long, quotable blob in the database.
create or replace function public.mark_notification_email_failed(
  p_delivery_id  uuid,
  p_error        text,
  p_max_attempts int default 5
)
returns void
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
begin
  update public.notification_email_deliveries
     set delivery_status = case when attempt_count >= greatest(coalesce(p_max_attempts, 5), 1)
                                then 'failed' else 'pending' end,
         last_error = left(regexp_replace(coalesce(p_error, 'Unknown error'), '\s+', ' ', 'g'), 300)
   where id = p_delivery_id and delivery_status <> 'sent';
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Expiry warnings for the permissions that have a term
--
--    Residential and burial permissions are perpetual and are never
--    warned about — they have no expiry date at all, so they cannot
--    match. Each permission gets each threshold exactly once, which the
--    unique constraint guarantees no matter how often this runs.
-- ---------------------------------------------------------------------

create or replace function public.queue_pto_expiry_warnings()
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_threshold int;
  v_row       record;
  v_account   uuid;
  v_created   int := 0;
  v_notification uuid;
begin
  foreach v_threshold in array array[60, 30, 7]
  loop
    for v_row in
      select p.id, p.pto_number, p.land_type, p.expiry_date,
             p.holder_resident_id, p.holder_household_id,
             s.site_code
      from public.ptos p
      join public.land_allocations a on a.id = p.land_allocation_id
      join public.land_sites s on s.id = a.land_site_id
      where p.land_type in ('farming', 'business')
        and p.pto_status = 'active'
        and p.expiry_date is not null
        and p.expiry_date >= current_date
        and p.expiry_date <= current_date + v_threshold
        and not exists (select 1 from public.pto_expiry_warnings w
                         where w.pto_id = p.id and w.threshold_days = v_threshold)
    loop
      -- Business is held by the person; farming by the household, so it
      -- goes to whoever heads that household today.
      v_account := case
        when v_row.holder_resident_id is not null then public.resident_account_id(v_row.holder_resident_id)
        else public.household_head_account_id(v_row.holder_household_id) end;

      v_notification := public.notify_user(
        v_account, 'pto',
        v_row.pto_number || ' expires in ' || v_threshold || ' days',
        'Your ' || v_row.land_type || ' permission to occupy ' || v_row.pto_number ||
          ' for site ' || v_row.site_code || ' expires on ' ||
          to_char(v_row.expiry_date, 'DD Mon YYYY') ||
          '. You may ask the Land Officer to renew it.',
        '/resident', 'pto', v_row.id, v_row.pto_number);

      -- Written whether or not there was an account to notify, so the
      -- threshold is never reconsidered for this permission.
      insert into public.pto_expiry_warnings (pto_id, threshold_days, notification_id, expiry_date)
      values (v_row.id, v_threshold, v_notification, v_row.expiry_date)
      on conflict (pto_id, threshold_days) do nothing;

      v_created := v_created + 1;
    end loop;
  end loop;

  return jsonb_build_object('warnings_created', v_created);
end;
$$;

-- ---------------------------------------------------------------------
-- 8. Row Level Security
--
--    A recipient reads their own notifications and nothing else, and
--    changes nothing directly: marking read and archiving go through
--    the functions above, which touch only those two columns.
--
--    Email deliveries are the worker's business alone. Nobody signed in
--    through a browser can read a provider message id or an error.
-- ---------------------------------------------------------------------

alter table public.notifications enable row level security;
alter table public.notifications force row level security;
revoke all on public.notifications from anon, authenticated;
grant select on public.notifications to authenticated;
grant all on public.notifications to service_role;

drop policy if exists notifications_own_only on public.notifications;
create policy notifications_own_only
  on public.notifications for select to authenticated
  using (recipient_user_account_id = public.current_user_account_id());

alter table public.notification_email_deliveries enable row level security;
alter table public.notification_email_deliveries force row level security;
revoke all on public.notification_email_deliveries from anon, authenticated;
grant all on public.notification_email_deliveries to service_role;

alter table public.pto_expiry_warnings enable row level security;
alter table public.pto_expiry_warnings force row level security;
revoke all on public.pto_expiry_warnings from anon, authenticated;
grant all on public.pto_expiry_warnings to service_role;

-- ---------------------------------------------------------------------
-- 9. Grants
-- ---------------------------------------------------------------------

do $$
declare v_signature text;
begin
  foreach v_signature in array array[
    'public.my_notifications(text, int)',
    'public.my_unread_notification_count()',
    'public.mark_notification_read(uuid)',
    'public.mark_all_notifications_read()',
    'public.archive_notification(uuid)',
    'public.current_user_account_id()'
  ]
  loop
    execute format('revoke all on function %s from public, anon, authenticated', v_signature);
    execute format('grant execute on function %s to authenticated', v_signature);
  end loop;
end;
$$;

-- The system's own doors. No browser role may open any of them.
do $$
declare v_signature text;
begin
  foreach v_signature in array array[
    'public.notify_user(uuid, text, text, text, text, text, uuid, text)',
    'public.resident_account_id(uuid)',
    'public.household_head_account_id(uuid)',
    'public.staff_account_id(uuid)',
    'public.claim_notification_emails(int, int, interval)',
    'public.mark_notification_email_sent(uuid, text)',
    'public.mark_notification_email_failed(uuid, text, int)',
    'public.queue_pto_expiry_warnings()'
  ]
  loop
    execute format('revoke all on function %s from public, anon, authenticated', v_signature);
  end loop;
end;
$$;

grant execute on function public.claim_notification_emails(int, int, interval) to service_role;
grant execute on function public.mark_notification_email_sent(uuid, text) to service_role;
grant execute on function public.mark_notification_email_failed(uuid, text, int) to service_role;
grant execute on function public.queue_pto_expiry_warnings() to service_role;

-- ---------------------------------------------------------------------
-- 10. The events a person is told about
--
--     These are triggers rather than calls added to each function, for
--     one reason: a trigger cannot be forgotten. However the row comes
--     to be written — through the ordinary function, through a later
--     one, or by hand in the SQL editor — the person it concerns is
--     told, in the same transaction.
-- ---------------------------------------------------------------------

create or replace function public.tg_notify_resident_account_decision()
returns trigger
language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  if new.request_status = old.request_status then return null; end if;

  if new.request_status = 'approved' then
    perform public.notify_user(
      new.user_account_id, 'account',
      'Your resident account has been approved',
      'Your account has been verified and linked to your record on the village register. ' ||
      'You can now apply for land and read the community updates.',
      '/resident', 'resident_account_request', new.id, null);
  elsif new.request_status = 'declined' then
    perform public.notify_user(
      new.user_account_id, 'account',
      'Your resident account could not be verified',
      'The Registry Clerk could not verify your details. Reason: ' ||
      coalesce(new.decline_reason, 'no reason was recorded') ||
      '. You can correct your details and apply again with this same account.',
      '/resident', 'resident_account_request', new.id, null);
  end if;
  return null;
end;
$$;

drop trigger if exists notify_resident_account_decision on public.resident_account_requests;
create trigger notify_resident_account_decision
  after update of request_status on public.resident_account_requests
  for each row execute function public.tg_notify_resident_account_decision();

create or replace function public.tg_notify_land_application_decision()
returns trigger
language plpgsql security definer set search_path = public, pg_temp
as $$
declare v_account uuid := public.resident_account_id(new.applicant_resident_id);
begin
  if new.application_status = old.application_status then return null; end if;

  if new.application_status = 'approved' then
    perform public.notify_user(
      v_account, 'land_application',
      'Land application ' || new.application_reference || ' has been approved',
      'Your ' || new.land_type || ' land application has been approved. ' ||
      'The Land Officer will allocate a site to you.',
      '/resident', 'land_application', new.id, new.application_reference);
  elsif new.application_status = 'declined' then
    perform public.notify_user(
      v_account, 'land_application',
      'Land application ' || new.application_reference || ' has been declined',
      'Your ' || new.land_type || ' land application has been declined. Reason: ' ||
      coalesce(new.decline_reason, 'no reason was recorded') || '.',
      '/resident', 'land_application', new.id, new.application_reference);
  end if;
  return null;
end;
$$;

drop trigger if exists notify_land_application_decision on public.land_applications;
create trigger notify_land_application_decision
  after update of application_status on public.land_applications
  for each row execute function public.tg_notify_land_application_decision();

create or replace function public.tg_notify_land_allocated()
returns trigger
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v_account uuid := case
    when new.resident_id is not null then public.resident_account_id(new.resident_id)
    else public.household_head_account_id(new.household_id) end;
  v_site text := (select site_code from public.land_sites where id = new.land_site_id);
begin
  if new.allocation_status <> 'active' then return null; end if;

  perform public.notify_user(
    v_account, 'land_allocation',
    'Site ' || v_site || ' has been allocated',
    'Site ' || v_site || ' has been allocated to you as ' || new.allocation_reference ||
    ' for ' || new.land_type || ' use. A permission to occupy will be issued for it.',
    '/resident', 'land_allocation', new.id, new.allocation_reference);
  return null;
end;
$$;

drop trigger if exists notify_land_allocated on public.land_allocations;
create trigger notify_land_allocated
  after insert on public.land_allocations
  for each row execute function public.tg_notify_land_allocated();

create or replace function public.tg_notify_pto_issued()
returns trigger
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v_account uuid := case
    when new.holder_resident_id is not null then public.resident_account_id(new.holder_resident_id)
    else public.household_head_account_id(new.holder_household_id) end;
begin
  if new.pto_status <> 'active' then return null; end if;

  perform public.notify_user(
    v_account, 'pto',
    'Permission to occupy ' || new.pto_number || ' has been issued',
    'Your ' || new.land_type || ' permission to occupy has been issued. ' ||
    case when new.expiry_date is null
         then 'It is perpetual and does not expire.'
         else 'It runs until ' || to_char(new.expiry_date, 'DD Mon YYYY') || '.' end,
    '/pto/' || new.id::text, 'pto', new.id, new.pto_number);
  return null;
end;
$$;

drop trigger if exists notify_pto_issued on public.ptos;
create trigger notify_pto_issued
  after insert on public.ptos
  for each row execute function public.tg_notify_pto_issued();

create or replace function public.tg_notify_pto_revoked()
returns trigger
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v_account uuid := case
    when new.holder_resident_id is not null then public.resident_account_id(new.holder_resident_id)
    else public.household_head_account_id(new.holder_household_id) end;
begin
  if new.pto_status <> 'revoked' or old.pto_status = 'revoked' then return null; end if;

  perform public.notify_user(
    v_account, 'pto',
    'Permission to occupy ' || new.pto_number || ' has been revoked',
    'Your permission to occupy ' || new.pto_number || ' has been revoked. Reason: ' ||
    coalesce(new.revocation_reason, 'no reason was recorded') ||
    '. Contact the traditional authority office if you need to discuss it.',
    '/resident', 'pto', new.id, new.pto_number);
  return null;
end;
$$;

drop trigger if exists notify_pto_revoked on public.ptos;
create trigger notify_pto_revoked
  after update of pto_status on public.ptos
  for each row execute function public.tg_notify_pto_revoked();

create or replace function public.tg_notify_renewal_decision()
returns trigger
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v_account uuid := public.resident_account_id(new.requested_by_resident_id);
  v_number  text := (select pto_number from public.ptos where id = new.pto_id);
  v_new     text := (select pto_number from public.ptos where id = new.resulting_pto_id);
begin
  if new.request_status = old.request_status then return null; end if;

  if new.request_status = 'approved' then
    perform public.notify_user(
      v_account, 'pto_renewal',
      'Your renewal of ' || v_number || ' has been approved',
      'A new permission to occupy, ' || coalesce(v_new, '(pending)') ||
      ', has been issued in place of ' || v_number || '. The site does not change.',
      case when new.resulting_pto_id is not null then '/pto/' || new.resulting_pto_id::text else '/resident' end,
      'pto_renewal_request', new.id, v_number);
  elsif new.request_status = 'declined' then
    perform public.notify_user(
      v_account, 'pto_renewal',
      'Your renewal of ' || v_number || ' has been declined',
      'The Land Officer has declined the renewal of ' || v_number || '. Reason: ' ||
      coalesce(new.decline_reason, 'no reason was recorded') ||
      '. Your existing permission is unchanged.',
      '/resident', 'pto_renewal_request', new.id, v_number);
  end if;
  return null;
end;
$$;

drop trigger if exists notify_renewal_decision on public.pto_renewal_requests;
create trigger notify_renewal_decision
  after update of request_status on public.pto_renewal_requests
  for each row execute function public.tg_notify_renewal_decision();
