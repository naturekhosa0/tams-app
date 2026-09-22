-- =====================================================================
-- TAMS — notifications and their emails, official communications,
-- internal staff messaging and work requests, the immutable audit
-- trail, Administrator Transfer and emergency recovery.
--
-- The Administrator Transfer block is deliberately last: it changes who
-- the Council Administrator is, so everything that depends on the
-- original one runs before it.
-- =====================================================================

-- ---- helpers ---------------------------------------------------------

create function tams_test.account_of(p_email text) returns uuid
language sql stable security definer as $$
  select id from public.user_accounts where email = p_email;
$$;

create function tams_test.resident_account(p_id_number text) returns uuid
language sql stable security definer as $$
  select ua.id from public.user_accounts ua
  join public.residents r on r.id = ua.resident_id
  where r.id_number = p_id_number and ua.account_type = 'resident';
$$;

create function tams_test.unread_for(p_account uuid) returns int
language sql stable security definer as $$
  select count(*)::int from public.notifications
  where recipient_user_account_id = p_account and read_at is null and archived_at is null;
$$;

create function tams_test.notifications_for(p_account uuid) returns int
language sql stable security definer as $$
  select count(*)::int from public.notifications where recipient_user_account_id = p_account;
$$;

create function tams_test.latest_notification(p_account uuid) returns uuid
language sql stable security definer as $$
  select id from public.notifications where recipient_user_account_id = p_account
  order by created_at desc, id desc limit 1;
$$;

create function tams_test.notification_titles(p_account uuid) returns text
language sql stable security definer as $$
  select string_agg(title, ' | ' order by created_at)
  from public.notifications where recipient_user_account_id = p_account;
$$;

create function tams_test.delivery_status_of(p_notification uuid) returns text
language sql stable security definer as $$
  select delivery_status from public.notification_email_deliveries where notification_id = p_notification;
$$;

create function tams_test.active_pto(p_land_type text) returns uuid
language sql stable security definer as $$
  select id from public.ptos
  where land_type = p_land_type and pto_status = 'active' and expiry_date is not null
  order by issue_date desc limit 1;
$$;

create function tams_test.set_pto_expiry(p_pto uuid, p_days int) returns void
language sql volatile security definer as $$
  update public.ptos set expiry_date = (current_date + p_days)::date where id = p_pto;
$$;

create function tams_test.warnings_for(p_pto uuid) returns text
language sql stable security definer as $$
  select coalesce(string_agg(threshold_days::text, ',' order by threshold_days), 'none')
  from public.pto_expiry_warnings where pto_id = p_pto;
$$;

create function tams_test.communication_id(p_reference text) returns uuid
language sql stable security definer as $$
  select id from public.resident_communications where communication_reference = p_reference;
$$;

create function tams_test.message_id(p_reference text) returns uuid
language sql stable security definer as $$
  select id from public.staff_messages where message_reference = p_reference;
$$;

create function tams_test.latest_message_of(p_employee text) returns uuid
language sql stable security definer as $$
  select m.id from public.staff_messages m
  join public.staff s on s.id = m.sender_staff_id
  where s.employee_number = p_employee order by m.created_at desc limit 1;
$$;

create function tams_test.audit_count(p_action text) returns int
language sql stable security definer as $$
  select count(*)::int from public.audit_logs where action = p_action;
$$;

create function tams_test.latest_audit(p_action text) returns public.audit_logs
language sql stable security definer as $$
  select * from public.audit_logs where action = p_action order by created_at desc, id desc limit 1;
$$;

create function tams_test.audit_action_for(p_action text, p_reference text) returns public.audit_logs
language sql stable security definer as $$
  select * from public.audit_logs
  where action = p_action and entity_reference = p_reference
  order by created_at desc, id desc limit 1;
$$;

create function tams_test.active_in_role(p_role text) returns int
language sql stable security definer as $$
  select count(*)::int from public.staff s
  join public.roles r on r.id = s.role_id
  join public.user_accounts ua on ua.staff_id = s.id
  where r.role_name = p_role and ua.account_status = 'active';
$$;

create function tams_test.audit_for(p_entity text, p_reference text) returns public.audit_logs
language sql stable security definer as $$
  select * from public.audit_logs
  where entity_type = p_entity and entity_reference = p_reference
  order by created_at desc, id desc limit 1;
$$;

create function tams_test.admin_count() returns int
language sql stable security definer as $$
  select public.active_council_administrator_count();
$$;

create function tams_test.deactivate_account_directly(p_email text) returns void
language sql volatile security definer as $$
  update public.user_accounts set account_status = 'deactivated' where email = p_email;
$$;

-- A resident who becomes active only after the broadcast below.
create function tams_test.latecomer() returns uuid language sql stable security definer as $$
  select auth_user_id from public.user_accounts where email = 'latecomer@village.example';
$$;


-- =====================================================================
-- NOTIFICATIONS
-- =====================================================================

-- The suites before this one already produced notifications through the
-- ordinary work: approvals, allocations, permissions. That is the point
-- of putting them in triggers, so start by proving it.

select tams_test.check(
  'NOTE 11 — approving a resident account tells the applicant',
  (select count(*) > 0 from public.notifications
    where notification_category = 'account'
      and title = 'Your resident account has been approved')
);

select tams_test.check(
  'NOTE 12 — declining one tells them, with the reason the clerk gave',
  (select count(*) > 0 from public.notifications
    where notification_category = 'account'
      and title = 'Your resident account could not be verified'
      and message like '%Reason:%')
);

select tams_test.check(
  'NOTE 13 — a land application approval reaches the applicant',
  (select count(*) > 0 from public.notifications
    where notification_category = 'land_application'
      and title like '%has been approved')
);

select tams_test.check(
  'NOTE 14 — and a decline reaches them with its reason',
  (select count(*) > 0 from public.notifications
    where notification_category = 'land_application'
      and title like '%has been declined'
      and message like '%No farming land is available this season%')
);

select tams_test.check(
  'NOTE 15 — an allocation is notified',
  (select count(*) > 0 from public.notifications
    where notification_category = 'land_allocation' and title like 'Site %allocated')
);

select tams_test.check(
  'NOTE 16 — a permission to occupy being issued is notified',
  (select count(*) > 0 from public.notifications
    where notification_category = 'pto' and title like 'Permission to occupy%issued')
  -- and a perpetual one says so rather than inventing a date
  and (select count(*) > 0 from public.notifications
       where notification_category = 'pto'
         and message like '%perpetual and does not expire%')
);

select tams_test.check(
  'NOTE 19 — revoking a permission is notified, with the reason',
  (select count(*) > 0 from public.notifications
    where notification_category = 'pto' and title like '%has been revoked'
      and message like '%Reason:%')
);

-- A renewal decision of each kind, so both sides can be checked.
select tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000028'), $sql$
  select public.resident_request_pto_renewal(tams_test.pto_for_site('BUS-9501'), 'Still trading')
$sql$);
select tams_test.run_as('authenticated', tams_test.officer(), $sql$
  select public.land_officer_decline_renewal(
    (select id from public.pto_renewal_requests where request_status = 'pending'
      order by requested_at desc limit 1),
    'The site is needed for the new clinic access road')
$sql$);

select tams_test.check(
  'NOTE 17/18 — renewal decisions reach the holder',
  (select count(*) > 0 from public.notifications
    where notification_category = 'pto_renewal' and title like '%has been approved')
  and (select count(*) > 0 from public.notifications
       where notification_category = 'pto_renewal' and title like '%has been declined'
         and message like '%Reason:%')
);

select tams_test.check(
  'NOTE 1 — a resident sees their own notifications',
  tams_test.query_as('authenticated', tams_test.resident_uid('SYN0000000028'), $sql$
    select count(*) > 0 from public.my_notifications('all', 500)
  $sql$) = 'true'
  and tams_test.query_as('authenticated', tams_test.resident_uid('SYN0000000028'), $sql$
    select bool_and(recipient_user_account_id = public.current_user_account_id())
    from public.notifications
  $sql$) = 'true'
);

select tams_test.check(
  'NOTE 2 — and nobody else''s, by the function or by the table',
  tams_test.query_as('authenticated', tams_test.resident_uid('SYN0000000028'), $sql$
    select count(*) from public.notifications
    where recipient_user_account_id = tams_test.resident_account('SYN0000000043')
  $sql$) = '0'
  and tams_test.query_as('authenticated', tams_test.clerk(), $sql$
    select count(*) from public.notifications
    where recipient_user_account_id = tams_test.resident_account('SYN0000000028')
  $sql$) = '0'
  and tams_test.query_as('anon', null, $sql$
    select count(*) from public.notifications
  $sql$) in ('0', 'ERROR:42501')
);

select tams_test.check(
  'NOTE 3 — the unread count is the caller''s own unread, not anybody''s total',
  tams_test.query_as('authenticated', tams_test.resident_uid('SYN0000000028'), $sql$
    select public.my_unread_notification_count()
  $sql$)::int = tams_test.unread_for(tams_test.resident_account('SYN0000000028'))
  and tams_test.unread_for(tams_test.resident_account('SYN0000000028')) > 0
);

select tams_test.check(
  'NOTE 4 — marking one read works, and marking somebody else''s does not',
  tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000028'), $sql$
    select public.mark_notification_read(
      tams_test.latest_notification(tams_test.resident_account('SYN0000000028')))
  $sql$) = 'OK'
  and tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000043'), $sql$
    select public.mark_notification_read(
      tams_test.latest_notification(tams_test.resident_account('SYN0000000028')))
  $sql$) = '42501'
);

select tams_test.check(
  'NOTE 4a — and that notification is now read',
  (select read_at is not null from public.notifications
   where id = tams_test.latest_notification(tams_test.resident_account('SYN0000000028')))
);

select tams_test.check(
  'NOTE 5 — marking everything read leaves nothing unread',
  tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000028'), $sql$
    select public.mark_all_notifications_read()
  $sql$) = 'OK'
);

select tams_test.check(
  'NOTE 5a — the caller''s unread count is zero and nobody else''s changed',
  tams_test.unread_for(tams_test.resident_account('SYN0000000028')) = 0
  and tams_test.unread_for(tams_test.resident_account('SYN0000000043')) > 0
);

select tams_test.check(
  'NOTE 6 — archiving keeps the row and its history',
  tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000028'), $sql$
    select public.archive_notification(
      tams_test.latest_notification(tams_test.resident_account('SYN0000000028')))
  $sql$) = 'OK'
);

select tams_test.check(
  'NOTE 6a — out of the inbox, still in the history, nothing deleted',
  (select archived_at is not null from public.notifications
   where id = tams_test.latest_notification(tams_test.resident_account('SYN0000000028')))
  and tams_test.query_as('authenticated', tams_test.resident_uid('SYN0000000028'), $sql$
    select count(*) from public.my_notifications('archived', 500)
  $sql$) = '1'
  and tams_test.query_as('authenticated', tams_test.resident_uid('SYN0000000028'), $sql$
    select count(*) from public.my_notifications('all', 500)
  $sql$)::int = tams_test.notifications_for(tams_test.resident_account('SYN0000000028'))
);

select tams_test.check(
  'NOTE 7 — a recipient cannot change what a notification says, or invent one',
  tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000028'), $sql$
    update public.notifications set title = 'Your land was approved'
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000028'), $sql$
    insert into public.notifications (recipient_user_account_id, notification_category, title, message)
    values (public.current_user_account_id(), 'land_allocation', 'A site is mine', 'Really')
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000028'), $sql$
    delete from public.notifications
  $sql$) = '42501'
  -- and the system's own door is closed to them
  and tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000028'), $sql$
    select public.notify_user(public.current_user_account_id(), 'pto', 'Issued', 'To me')
  $sql$) = '42501'
);


-- =====================================================================
-- EMAIL DELIVERY
-- =====================================================================

select tams_test.check(
  'MAIL 8 — every notification queues exactly one email, to the right address',
  (select count(*) = 0 from public.notifications n
    where not exists (select 1 from public.notification_email_deliveries d
                       where d.notification_id = n.id))
  and (select bool_and(d.recipient_email = ua.email)
       from public.notification_email_deliveries d
       join public.notifications n on n.id = d.notification_id
       join public.user_accounts ua on ua.id = n.recipient_user_account_id)
  and (select bool_and(delivery_status = 'pending') from public.notification_email_deliveries)
);

select tams_test.check(
  'MAIL 8a — and a second queueing attempt cannot create a second email',
  tams_test.run_as('service_role', null, $sql$
    insert into public.notification_email_deliveries (notification_id, recipient_email)
    select id, 'somewhere@else.example' from public.notifications limit 1
  $sql$) = '23505'
);

-- One run of the worker: claim a batch, then report on it.
select tams_test.run_as('service_role', null, $sql$
  create temporary table claimed_once as
  select * from public.claim_notification_emails(3)
$sql$);

select tams_test.check(
  'MAIL 10 — the worker claims a batch once, and a second run never re-claims it',
  tams_test.query_as('service_role', null, $sql$
    select count(*) from claimed_once
  $sql$) = '3'
  -- Mark them sent, exactly as the worker does.
  and tams_test.run_as('service_role', null, $sql$
    select public.mark_notification_email_sent(delivery_id, 'provider-msg') from claimed_once
  $sql$) = 'OK'
  and tams_test.query_as('service_role', null, $sql$
    select count(*) from public.claim_notification_emails(3) c
    join claimed_once o on o.delivery_id = c.delivery_id
  $sql$) = '0'
);

select tams_test.check(
  'MAIL 10a — a sent email is recorded as sent, with when and which message',
  tams_test.query_as('service_role', null, $sql$
    select count(*) from public.notification_email_deliveries d
    join claimed_once o on o.delivery_id = d.id
    where d.delivery_status = 'sent' and d.sent_at is not null
      and d.provider_message_id = 'provider-msg' and d.attempt_count = 1
  $sql$) = '3'
);

select tams_test.check(
  'MAIL 9 — a failing email does not undo the business action behind it',
  -- Take the notification that says a permission was issued…
  tams_test.run_as('service_role', null, $sql$
    select public.mark_notification_email_failed(
      (select d.id from public.notification_email_deliveries d
        join public.notifications n on n.id = d.notification_id
        where n.title like 'Permission to occupy%issued' limit 1),
      'Provider returned 500: service unavailable', 1)
  $sql$) = 'OK'
);

select tams_test.check(
  'MAIL 9a — the delivery is failed, the notification is untouched, the permission still stands',
  (select delivery_status = 'failed' and last_error like 'Provider returned 500%'
   from public.notification_email_deliveries d
   join public.notifications n on n.id = d.notification_id
   where n.title like 'Permission to occupy%issued' limit 1)
  and (select count(*) > 0 from public.notifications where title like 'Permission to occupy%issued')
  and (select count(*) > 0 from public.ptos where pto_status = 'active')
);

select tams_test.check(
  'MAIL 6a — nobody signed in through a browser can read a delivery, an error or a provider id',
  tams_test.query_as('authenticated', tams_test.resident_uid('SYN0000000028'), $sql$
    select count(*) from public.notification_email_deliveries
  $sql$) = 'ERROR:42501'
  and tams_test.query_as('authenticated', tams_test.administrator(), $sql$
    select count(*) from public.notification_email_deliveries
  $sql$) = 'ERROR:42501'
  and tams_test.run_as('authenticated', tams_test.administrator(), $sql$
    select count(*) from public.claim_notification_emails(1)
  $sql$) = '42501'
);


-- =====================================================================
-- PERMISSION-TO-OCCUPY EXPIRY WARNINGS
-- =====================================================================

select tams_test.set_pto_expiry(tams_test.active_pto('business'), 60);
select tams_test.run_as('service_role', null, $sql$ select public.queue_pto_expiry_warnings() $sql$);

select tams_test.check(
  'EXP 20 — a business permission sixty days out gets the sixty-day warning',
  tams_test.warnings_for(tams_test.active_pto('business')) = '60'
  and (select count(*) = 1 from public.notifications
        where title like '%expires in 60 days%')
);

select tams_test.check(
  'EXP 24 — running it again writes nothing: each threshold happens once',
  tams_test.run_as('service_role', null, $sql$ select public.queue_pto_expiry_warnings() $sql$) = 'OK'
);

select tams_test.check(
  'EXP 24a — still one warning and one notification',
  tams_test.warnings_for(tams_test.active_pto('business')) = '60'
  and (select count(*) = 1 from public.notifications where title like '%expires in 60 days%')
  -- and the database itself refuses a second one
  and tams_test.run_as('service_role', null, $sql$
    insert into public.pto_expiry_warnings (pto_id, threshold_days, expiry_date)
    values (tams_test.active_pto('business'), 60, current_date + 60)
  $sql$) = '23505'
);

select tams_test.set_pto_expiry(tams_test.active_pto('business'), 30);
select tams_test.run_as('service_role', null, $sql$ select public.queue_pto_expiry_warnings() $sql$);

select tams_test.check(
  'EXP 21 — thirty days out adds the thirty-day warning and no other',
  tams_test.warnings_for(tams_test.active_pto('business')) = '30,60'
);

select tams_test.set_pto_expiry(tams_test.active_pto('business'), 7);
select tams_test.run_as('service_role', null, $sql$ select public.queue_pto_expiry_warnings() $sql$);

select tams_test.check(
  'EXP 22 — seven days out adds the last one',
  tams_test.warnings_for(tams_test.active_pto('business')) = '7,30,60'
  and (select count(*) = 1 from public.notifications where title like '%expires in 7 days%')
);

-- The land suite released its farming site again, so there is no
-- farming permission left to warn about. One is issued here.
select tams_test.run_as('authenticated', tams_test.officer(), $sql$
  select public.land_officer_register_site('FRM-9601', 'farming',
    'Farming block 9601', '9601', 'Section D', 'Mhinga Village')
$sql$);
select tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000054'), $sql$
  select public.resident_submit_land_application('farming',
    jsonb_build_object('reason_for_application', 'To grow maize for the household',
                       'farming_type', 'crop'))
$sql$);
select tams_test.run_as('authenticated', tams_test.officer(), $sql$
  select public.land_officer_approve_application(tams_test.latest_application('SYN0000000054'))
$sql$);
select tams_test.run_as('authenticated', tams_test.officer(), $sql$
  select public.land_officer_allocate_site(tams_test.latest_application('SYN0000000054'),
    tams_test.site_id_of('FRM-9601'))
$sql$);
select tams_test.run_as('authenticated', tams_test.officer(), $sql$
  select public.land_officer_issue_pto(tams_test.allocation_for_site('FRM-9601'))
$sql$);

select tams_test.set_pto_expiry(tams_test.active_pto('farming'), 30);
select tams_test.run_as('service_role', null, $sql$ select public.queue_pto_expiry_warnings() $sql$);

select tams_test.check(
  'EXP 23 — a farming permission is warned about too, and it goes to the household head',
  tams_test.warnings_for(tams_test.active_pto('farming')) like '%30%'
  and (select count(*) > 0 from public.notifications n
        join public.pto_expiry_warnings w on w.notification_id = n.id
        join public.ptos p on p.id = w.pto_id
        where p.land_type = 'farming'
          and n.recipient_user_account_id = public.household_head_account_id(p.holder_household_id))
);

select tams_test.check(
  'EXP 25/26 — residential and burial permissions are perpetual and are never warned about',
  (select count(*) = 0 from public.pto_expiry_warnings w
    join public.ptos p on p.id = w.pto_id
    where p.land_type in ('residential', 'burial'))
  -- because they have no expiry date at all to count down to
  and (select bool_and(expiry_date is null) from public.ptos
       where land_type in ('residential', 'burial'))
  and (select count(*) = 0 from public.notifications n
       where n.title like '%expires in%'
         and n.source_entity_id in (select id from public.ptos
                                     where land_type in ('residential', 'burial')))
);


-- =====================================================================
-- OFFICIAL COMMUNICATIONS TO RESIDENTS
-- =====================================================================

select tams_test.check(
  'COM 36/37 — a Registry Clerk and a Land Officer cannot send an official notice',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.secretary_send_communication('general_notice', 'all_active_residents',
      'From the clerk', 'A notice')
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.secretary_send_communication('general_notice', 'all_active_residents',
      'From the officer', 'A notice')
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000028'), $sql$
    select public.secretary_send_communication('summons', 'one_resident', 'Come in', 'Please',
      array[tams_test.resident_id_of('SYN0000000043')])
  $sql$) = '42501'
);

select tams_test.check(
  'COM 27/19 — the Secretary summons one resident, with a date, a time and a venue',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_send_communication(
      'summons', 'one_resident',
      'Summons to Traditional Council',
      'You are required to attend the Traditional Council regarding a boundary dispute.',
      array[tams_test.resident_id_of('SYN0000000028')],
      'Chief', (current_date + 7)::date, time '10:00', 'Traditional Council Hall')
  $sql$) = 'OK'
);

select tams_test.check(
  'COM 34 — the date, time, venue and capacity are all on the record and in the notice',
  (select communication_type = 'summons' and audience_type = 'one_resident'
          and event_date = (current_date + 7)::date and event_time = time '10:00'
          and venue = 'Traditional Council Hall' and issued_on_behalf_of = 'Chief'
          and recipient_count = 1
   from public.resident_communications
   where communication_reference = tams_test.ref('COM-', 1))
  and (select message like '%Venue: Traditional Council Hall%'
              and message like '%Issued on behalf of: Chief%'
       from public.notifications
       where source_reference = tams_test.ref('COM-', 1))
);

select tams_test.check(
  'COM 28 — that summons reaches only the resident it names',
  tams_test.query_as('authenticated', tams_test.resident_uid('SYN0000000028'), $sql$
    select count(*) from public.my_notifications('all', 500)
    where source_reference = tams_test.ref('COM-', 1)
  $sql$) = '1'
  and tams_test.query_as('authenticated', tams_test.resident_uid('SYN0000000043'), $sql$
    select count(*) from public.my_notifications('all', 500)
    where source_reference = tams_test.ref('COM-', 1)
  $sql$) = '0'
  and tams_test.query_as('authenticated', tams_test.resident_uid('SYN0000000043'), $sql$
    select count(*) from public.notifications where source_reference = tams_test.ref('COM-', 1)
  $sql$) = '0'
);

select tams_test.check(
  'COM 35 — reading a summons is not attending it, and changes nothing else',
  tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000028'), $sql$
    select public.mark_notification_read(
      (select id from public.notifications where source_reference = tams_test.ref('COM-', 1)))
  $sql$) = 'OK'
);

select tams_test.check(
  'COM 35a — read_at is set and nothing about the resident or the summons moved',
  (select read_at is not null from public.notifications
   where source_reference = tams_test.ref('COM-', 1))
  and (select resident_status = 'active' from public.residents where id_number = 'SYN0000000028')
  -- the communication itself carries no attendance, acceptance or compliance of any kind
  and (select count(*) = 0 from information_schema.columns
        where table_schema = 'public' and table_name = 'resident_communications'
          and column_name in ('attended', 'accepted', 'complied', 'acknowledged'))
);

select tams_test.check(
  'COM 29/30 — a selection of residents receives it, and nobody else does',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_send_communication(
      'general_notice', 'selected_residents',
      'Boundary inspection', 'Your section will be inspected next week.',
      array[tams_test.resident_id_of('SYN0000000043'), tams_test.resident_id_of('SYN0000000054')])
  $sql$) = 'OK'
);

select tams_test.check(
  'COM 30a — exactly those two, by the recipient snapshot and by what they can read',
  (select recipient_count = 2 from public.resident_communications
   where communication_reference = tams_test.ref('COM-', 2))
  and tams_test.query_as('authenticated', tams_test.resident_uid('SYN0000000043'), $sql$
    select count(*) from public.my_notifications('all', 500)
    where source_reference = tams_test.ref('COM-', 2)
  $sql$) = '1'
  and tams_test.query_as('authenticated', tams_test.resident_uid('SYN0000000054'), $sql$
    select count(*) from public.my_notifications('all', 500)
    where source_reference = tams_test.ref('COM-', 2)
  $sql$) = '1'
  and tams_test.query_as('authenticated', tams_test.resident_uid('SYN0000000028'), $sql$
    select count(*) from public.my_notifications('all', 500)
    where source_reference = tams_test.ref('COM-', 2)
  $sql$) = '0'
);

select tams_test.check(
  'COM 18a — the resident search offers only active residents who can actually be reached',
  tams_test.query_as('authenticated', tams_test.secretary(), $sql$
    select bool_and(has_account) from public.secretary_search_residents(null)
  $sql$) = 'true'
  and tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select count(*) from public.secretary_search_residents(null)
  $sql$) = '42501'
);

-- A broadcast to everybody active at this moment.
select tams_test.check(
  'COM 31 — a community announcement goes to every active resident there is',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_send_communication(
      'community_announcement', 'all_active_residents',
      'Water interruption on Thursday',
      'The municipality will interrupt the water supply on Thursday from 08:00 to 16:00.')
  $sql$) = 'OK'
);

select tams_test.check(
  'COM 31a — the recipients were written down, and they are the active ones',
  (select recipient_count > 0 from public.resident_communications
   where communication_reference = tams_test.ref('COM-', 3))
  and (select c.recipient_count = (select count(*) from public.user_accounts ua
                                    join public.residents r on r.id = ua.resident_id
                                    where ua.account_type = 'resident'
                                      and ua.account_status = 'active'
                                      and r.resident_status = 'active')
       from public.resident_communications c
       where c.communication_reference = tams_test.ref('COM-', 3))
);

select tams_test.check(
  'COM 33 — a pending, a declined and a deactivated account were not among them',
  tams_test.query_as('authenticated', tams_test.pending_resident(), $sql$
    select count(*) from public.notifications where source_reference = tams_test.ref('COM-', 3)
  $sql$) = '0'
  and tams_test.query_as('authenticated', tams_test.declined_resident(), $sql$
    select count(*) from public.notifications where source_reference = tams_test.ref('COM-', 3)
  $sql$) = '0'
  and (select count(*) = 0 from public.resident_communication_recipients cr
        join public.user_accounts ua on ua.id = cr.user_account_id
        where cr.communication_id = tams_test.communication_id(tams_test.ref('COM-', 3))
          and ua.account_status <> 'active')
);

-- Somebody verified after the announcement went out.
select tams_test.run_as('authenticated', tams_test.clerk(), $sql$
  select public.registry_create_resident('SYN0000000910', 'Late', 'Comer',
    '1992-05-05', 'Male', 'active')
$sql$);
select tams_test.run_as('authenticated', tams_test.clerk(), $sql$
  select public.registry_link_resident_to_household(
    tams_test.resident_id_of('SYN0000000910'), tams_test.household_id_of('HH-0009'))
$sql$);
do $$
declare v_uid uuid;
begin
  insert into auth.users (email, last_sign_in_at) values ('latecomer@village.example', now())
  returning id into v_uid;
  insert into public.user_accounts (auth_user_id, email, account_type, account_status, resident_id)
  values (v_uid, 'latecomer@village.example', 'resident', 'active',
          (select id from public.residents where id_number = 'SYN0000000910'));
end;
$$;

select tams_test.check(
  'COM 32 — a resident activated afterwards does not become a recipient of an old notice',
  tams_test.query_as('authenticated', tams_test.latecomer(), $sql$
    select count(*) from public.my_notifications('all', 500)
    where source_reference = tams_test.ref('COM-', 3)
  $sql$) = '0'
  and (select count(*) = 0 from public.resident_communication_recipients cr
        join public.user_accounts ua on ua.id = cr.user_account_id
        where cr.communication_id = tams_test.communication_id(tams_test.ref('COM-', 3))
          and ua.email = 'latecomer@village.example')
);

select tams_test.check(
  'COM 20 — an announcement may point at a meeting without publishing that meeting',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_send_communication(
      'community_announcement', 'all_active_residents',
      'Community meeting', 'A community meeting will be held.',
      null, 'Traditional Council', null, null, null,
      'meeting', tams_test.meeting_id(tams_test.ref('MTG-', 3)))
  $sql$) = 'OK'
);

select tams_test.check(
  'COM 20a — the notice carries the reference and the meeting itself stays unreachable',
  (select related_reference = tams_test.ref('MTG-', 3)
   from public.resident_communications where communication_reference = tams_test.ref('COM-', 4))
  and tams_test.query_as('authenticated', tams_test.resident_uid('SYN0000000028'), $sql$
    select count(*) from public.council_meetings
  $sql$) = '0'
);

select tams_test.check(
  'COM 21 — the Secretary sees what was sent, who received it, and nobody else does',
  tams_test.query_as('authenticated', tams_test.secretary(), $sql$
    select count(*) from public.secretary_communications(null, null)
  $sql$) = '4'
  and tams_test.query_as('authenticated', tams_test.secretary(), $sql$
    select count(*) from public.secretary_communication_recipients(
      tams_test.communication_id(tams_test.ref('COM-', 2)))
  $sql$) = '2'
  and tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select count(*) from public.secretary_communications(null, null)
  $sql$) = '42501'
  and tams_test.query_as('authenticated', tams_test.resident_uid('SYN0000000028'), $sql$
    select count(*) from public.resident_communications
  $sql$) = '0'
);

select tams_test.check(
  'COM 21a — a sent communication cannot be deleted or rewritten',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    delete from public.resident_communications
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    update public.resident_communications set message = 'Something else'
  $sql$) = '42501'
);


-- =====================================================================
-- INTERNAL STAFF MESSAGING
-- =====================================================================

select tams_test.check(
  'MSG 39 — a resident cannot use staff messaging at all',
  tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000028'), $sql$
    select public.staff_send_message('Hello', 'Let me in', 'all_staff')
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000028'), $sql$
    select count(*) from public.staff_messages_list('inbox')
  $sql$) = '42501'
  and tams_test.query_as('authenticated', tams_test.resident_uid('SYN0000000028'), $sql$
    select count(*) from public.staff_messages
  $sql$) = '0'
);

select tams_test.check(
  'MSG 40 — a staff member whose account was deactivated is refused',
  tams_test.run_as('authenticated', tams_test.ex_secretary(), $sql$
    select public.staff_send_message('Still here', 'Am I?', 'all_staff')
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.ex_secretary(), $sql$
    select count(*) from public.staff_messages_list('inbox')
  $sql$) = '42501'
);

select tams_test.check(
  'MSG 38 — a Land Officer writes to a Registry Clerk about a record',
  tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.staff_send_message(
      'Household membership needs correcting',
      'The applicant on this land application is not recorded in the household they claim. ' ||
      'Please correct the membership before the application can continue.',
      'direct', 'normal', tams_test.staff_id_of('2026070'), null,
      'land_application', tams_test.latest_application('SYN0000000028'))
  $sql$) = 'OK'
);

select tams_test.check(
  'MSG 38a — it is in the clerk''s inbox, with the sender, the kind and the reference',
  tams_test.query_as('authenticated', tams_test.clerk(), $sql$
    select count(*) from public.staff_messages_list('inbox')
    where message_reference = tams_test.ref('MSG-', 1)
      and sender_name = 'Lance Officer' and sender_role = 'Land Officer'
      and message_kind = 'normal' and related_reference like 'APP-%'
  $sql$) = '1'
  and tams_test.query_as('authenticated', tams_test.officer(), $sql$
    select count(*) from public.staff_messages_list('sent')
    where message_reference = tams_test.ref('MSG-', 1)
  $sql$) = '1'
);

select tams_test.check(
  'MSG 30a — an incoming message raises a notification that says who and what, and no more',
  (select count(*) = 1 from public.notifications
    where source_reference = tams_test.ref('MSG-', 1)
      and notification_category = 'staff_message'
      and recipient_user_account_id = tams_test.staff_account_id_of('2026070'))
  -- the body of the message is not in the alert
  and (select message not like '%not recorded in the household%' and message like '%Lance Officer%'
       from public.notifications where source_reference = tams_test.ref('MSG-', 1))
);

select tams_test.check(
  'MSG 48 — an unrelated staff member cannot read a private message',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.staff_message(tams_test.message_id(tams_test.ref('MSG-', 1)))
  $sql$) = '42501'
  and tams_test.query_as('authenticated', tams_test.secretary(), $sql$
    select count(*) from public.staff_messages
    where message_reference = tams_test.ref('MSG-', 1)
  $sql$) = '0'
  -- and not the Council Administrator either: this is not their post
  and tams_test.run_as('authenticated', tams_test.administrator(), $sql$
    select public.staff_message(tams_test.message_id(tams_test.ref('MSG-', 1)))
  $sql$) = '42501'
  and tams_test.query_as('authenticated', tams_test.administrator(), $sql$
    select count(*) from public.staff_messages
    where message_reference = tams_test.ref('MSG-', 1)
  $sql$) = '0'
);

select tams_test.check(
  'MSG 49 — a link to a record grants the recipient nothing at all',
  -- The clerk can read the message and see the reference…
  tams_test.query_as('authenticated', tams_test.clerk(), $sql$
    select public.staff_message(tams_test.message_id(tams_test.ref('MSG-', 1))) ->> 'related_reference'
  $sql$) like 'APP-%'
  -- …and still cannot do a single Land Officer thing with it.
  and tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.land_officer_application(tams_test.latest_application('SYN0000000028'))
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.land_officer_approve_application(tams_test.latest_application('SYN0000000028'))
  $sql$) = '42501'
);

select tams_test.check(
  'MSG 47 — a sent message cannot be edited or deleted by anybody',
  tams_test.run_as('authenticated', tams_test.officer(), $sql$
    update public.staff_messages set body = 'I never said that'
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    update public.staff_messages set subject = 'Something else'
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.officer(), $sql$
    delete from public.staff_messages
  $sql$) = '42501'
);

select tams_test.check(
  'MSG 46 — a recipient may archive their own copy without deleting anything',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.staff_archive_message(tams_test.message_id(tams_test.ref('MSG-', 1)))
  $sql$) = 'OK'
);

select tams_test.check(
  'MSG 46a — out of their inbox, into their archive, and still in the sender''s sent box',
  tams_test.query_as('authenticated', tams_test.clerk(), $sql$
    select count(*) from public.staff_messages_list('inbox')
    where message_reference = tams_test.ref('MSG-', 1)
  $sql$) = '0'
  and tams_test.query_as('authenticated', tams_test.clerk(), $sql$
    select count(*) from public.staff_messages_list('archived')
    where message_reference = tams_test.ref('MSG-', 1)
  $sql$) = '1'
  and tams_test.query_as('authenticated', tams_test.officer(), $sql$
    select count(*) from public.staff_messages_list('sent')
    where message_reference = tams_test.ref('MSG-', 1)
  $sql$) = '1'
);

select tams_test.check(
  'MSG 41 — a message to a role reaches everybody holding it now',
  tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.staff_send_message(
      'Please confirm the register is up to date',
      'Before the next allocation round, please confirm the household register is current.',
      'role', 'normal', null, tams_test.role_id_of('Council Secretary'))
  $sql$) = 'OK'
);

select tams_test.check(
  'MSG 41a — every active Council Secretary received it, and the deactivated one did not',
  (select count(*) from public.staff_message_recipients
    where message_id = tams_test.message_id(tams_test.ref('MSG-', 2)))
   = tams_test.active_in_role('Council Secretary')
  and tams_test.query_as('authenticated', tams_test.secretary(), $sql$
    select count(*) from public.staff_messages_list('inbox')
    where message_reference = tams_test.ref('MSG-', 2)
  $sql$) = '1'
  and (select count(*) = 0 from public.staff_message_recipients r
        join public.staff s on s.id = r.recipient_staff_id
        where r.message_id = tams_test.message_id(tams_test.ref('MSG-', 2))
          and s.employee_number = '2026074')
);

select tams_test.check(
  'MSG 43 — the Council Administrator may write to all staff',
  tams_test.run_as('authenticated', tams_test.administrator(), $sql$
    select public.staff_send_message(
      'Office closed on Friday', 'The traditional authority office will be closed on Friday.',
      'all_staff', 'announcement')
  $sql$) = 'OK'
);

select tams_test.check(
  'MSG 44 — so may the Council Secretary',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.staff_send_message(
      'Minutes are ready', 'The minutes of the last meeting are now final.',
      'all_staff', 'announcement')
  $sql$) = 'OK'
);

select tams_test.check(
  'MSG 45 — an ordinary role may not',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.staff_send_message('Everyone', 'Listen to me', 'all_staff', 'announcement')
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.staff_send_message('Everyone', 'Listen to me', 'all_staff', 'announcement')
  $sql$) = '42501'
);

select tams_test.check(
  'MSG 43a — an all-staff announcement reached every active staff member but its sender',
  (select count(*) from public.staff_message_recipients
    where message_id = tams_test.message_id(tams_test.ref('MSG-', 3)))
   = (select count(*) - 1 from public.user_accounts
      where account_type = 'staff' and account_status = 'active')
);

select tams_test.check(
  'MSG 24a — a direct message to a deactivated staff member is refused, and so is one to yourself',
  tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.staff_send_message('Hello', 'Are you there', 'direct', 'normal',
      tams_test.staff_id_of('2026074'))
  $sql$) = 'TA118'
  and tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.staff_send_message('Note to self', 'Remember', 'direct', 'normal',
      tams_test.staff_id_of('2026071'))
  $sql$) = 'TA116'
);


-- =====================================================================
-- WORK REQUESTS
-- =====================================================================

select tams_test.check(
  'WORK 50 — a work request starts open',
  tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.staff_send_message(
      'Correct the household membership on HH-0009',
      'Please move the resident into the correct household so the application can continue.',
      'direct', 'action_required', tams_test.staff_id_of('2026070'), null,
      'household', tams_test.household_id_of('HH-0009'))
  $sql$) = 'OK'
);

select tams_test.check(
  'WORK 50a — open, unclaimed, and the recipient was told it needs action',
  (select action_status = 'open' and acknowledged_by_staff_id is null
   from public.staff_messages where message_reference = tams_test.ref('MSG-', 5))
  and (select count(*) = 1 from public.notifications
        where source_reference = tams_test.ref('MSG-', 5)
          and notification_category = 'work_request'
          and title like 'Action required:%')
);

select tams_test.check(
  'WORK 52 — a staff member it was not sent to cannot acknowledge it',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.staff_acknowledge_request(tams_test.message_id(tams_test.ref('MSG-', 5)))
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.administrator(), $sql$
    select public.staff_acknowledge_request(tams_test.message_id(tams_test.ref('MSG-', 5)))
  $sql$) = '42501'
);

select tams_test.check(
  'WORK 53a — and it cannot be resolved before it has been acknowledged',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.staff_resolve_request(tams_test.message_id(tams_test.ref('MSG-', 5)))
  $sql$) = 'TA119'
);

select tams_test.check(
  'WORK 51 — the recipient acknowledges it',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.staff_acknowledge_request(tams_test.message_id(tams_test.ref('MSG-', 5)))
  $sql$) = 'OK'
);

select tams_test.check(
  'WORK 51a — it is theirs now, and the sender was told',
  (select action_status = 'acknowledged' and acknowledged_at is not null
          and acknowledged_by_staff_id = tams_test.staff_id_of('2026070')
   from public.staff_messages where message_reference = tams_test.ref('MSG-', 5))
  and (select count(*) = 1 from public.notifications
        where source_reference = tams_test.ref('MSG-', 5)
          and title like '%has been acknowledged'
          and recipient_user_account_id = tams_test.staff_account_id_of('2026071'))
);

select tams_test.check(
  'WORK 53 — and they resolve it',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.staff_resolve_request(tams_test.message_id(tams_test.ref('MSG-', 5)))
  $sql$) = 'OK'
);

select tams_test.check(
  'WORK 58 — the resolved request is kept, with who did what and when',
  (select action_status = 'resolved'
          and acknowledged_by_staff_id = tams_test.staff_id_of('2026070')
          and resolved_by_staff_id = tams_test.staff_id_of('2026070')
          and acknowledged_at is not null and resolved_at is not null
   from public.staff_messages where message_reference = tams_test.ref('MSG-', 5))
  and tams_test.run_as('authenticated', tams_test.officer(), $sql$
    delete from public.staff_messages where message_reference = tams_test.ref('MSG-', 5)
  $sql$) = '42501'
);

-- A work request to a whole role: the first to take it on claims it.
select tams_test.check(
  'WORK 54 — a role work request reaches everybody holding that role',
  tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.staff_send_message(
      'Confirm the minutes reference for RESO follow-up',
      'Whoever is free: please confirm which minutes carry this resolution.',
      'role', 'action_required', null, tams_test.role_id_of('Council Secretary'))
  $sql$) = 'OK'
);

select tams_test.check(
  'WORK 54a — every active Council Secretary has it, and it is open',
  (select count(*) from public.staff_message_recipients
    where message_id = tams_test.message_id(tams_test.ref('MSG-', 6)))
   = tams_test.active_in_role('Council Secretary')
  and (select action_status = 'open' from public.staff_messages
       where message_reference = tams_test.ref('MSG-', 6))
);

select tams_test.check(
  'WORK 55 — the first of them to acknowledge it claims it',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.staff_acknowledge_request(tams_test.message_id(tams_test.ref('MSG-', 6)))
  $sql$) = 'OK'
);

select tams_test.check(
  'WORK 56 — the second is told who has it, and cannot claim it as well',
  tams_test.run_as('authenticated', tams_test.uid_of('newstaff@ta.example'), $sql$
    select public.staff_acknowledge_request(tams_test.message_id(tams_test.ref('MSG-', 6)))
  $sql$) = 'TA119'
  and (select acknowledged_by_staff_id = tams_test.staff_id_of('2026072')
       from public.staff_messages where message_reference = tams_test.ref('MSG-', 6))
);

select tams_test.check(
  'WORK 57 — and only the one who claimed it may resolve it',
  tams_test.run_as('authenticated', tams_test.uid_of('newstaff@ta.example'), $sql$
    select public.staff_resolve_request(tams_test.message_id(tams_test.ref('MSG-', 6)))
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.staff_resolve_request(tams_test.message_id(tams_test.ref('MSG-', 6)))
  $sql$) = 'OK'
);

select tams_test.check(
  'WORK 34a — the sender sees the whole lifecycle on the message itself',
  tams_test.query_as('authenticated', tams_test.officer(), $sql$
    select public.staff_message(tams_test.message_id(tams_test.ref('MSG-', 6))) ->> 'action_status'
  $sql$) = 'resolved'
  and tams_test.query_as('authenticated', tams_test.officer(), $sql$
    select public.staff_message(tams_test.message_id(tams_test.ref('MSG-', 6))) ->> 'acknowledged_by'
  $sql$) = 'Cynthia Secretary'
);


-- =====================================================================
-- THE AUDIT TRAIL
-- =====================================================================

select tams_test.check(
  'AUD 59 — a create records the new values and no old ones',
  (select old_values is null
          and new_values ->> 'household_code' is not null
          and new_values ->> 'household_status' = 'active'
          and array_length(changed_fields, 1) > 0
   from tams_test.audit_action_for('CREATE_HOUSEHOLD', 'HH-0021'))
);

select tams_test.check(
  'AUD 60/61/62 — an update records the old, the new, and exactly what moved',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_update_resident(tams_test.resident_id_of('SYN0000000910'),
      'SYN0000000910', 'Late', 'Comer', '1992-05-05', 'Male', 'active', '0799876543', null)
  $sql$) = 'OK'
);

select tams_test.check(
  'AUD 62a — only the field that changed, on both sides',
  (select changed_fields = array['contact_number']
          and old_values -> 'contact_number' is not null
          and new_values ->> 'contact_number' = '0799876543'
          and (new_values ? 'first_name') = false
   from tams_test.audit_for('resident', 'SYN0000000910'))
);

select tams_test.check(
  'AUD 64 — the actor is the signed-in person, worked out server side',
  (select actor_role = 'Registry Clerk'
          and actor_label = 'Rita Clerk'
          and actor_staff_id = tams_test.staff_id_of('2026070')
          and actor_user_id = tams_test.clerk()
   from tams_test.audit_for('resident', 'SYN0000000910'))
);

select tams_test.check(
  'AUD 85 — and there is no way for a caller to claim to be somebody else',
  -- no function anywhere takes an actor or an action from a browser
  (select count(*) = 0 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and has_function_privilege('authenticated', p.oid, 'execute')
      and p.proname in ('audit_event', 'audit_context', 'audit_actor', 'tg_audit'))
  and tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.audit_event('I_AM_THE_ADMINISTRATOR', 'staff', null, 'anything')
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.administrator(), $sql$
    select public.audit_context('WHATEVER_I_WANT', 'because')
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    insert into public.audit_logs (action, entity_type, actor_role, actor_label)
    values ('DELETED_EVERYTHING', 'staff', 'Council Administrator', 'Somebody else')
  $sql$) = '42501'
);

select tams_test.check(
  'AUD 83/84 — nobody can update or delete an audit record',
  tams_test.run_as('authenticated', tams_test.administrator(), $sql$
    update public.audit_logs set action = 'NOTHING_HAPPENED'
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.administrator(), $sql$
    delete from public.audit_logs
  $sql$) = '42501'
  -- not with the service key either, which is what the servers hold
  and tams_test.run_as('service_role', null, $sql$
    update public.audit_logs set action = 'NOTHING_HAPPENED'
  $sql$) in ('TA120', '42501')
  and tams_test.run_as('service_role', null, $sql$
    delete from public.audit_logs
  $sql$) in ('TA120', '42501')
);

select tams_test.check(
  'AUD 50a — and the table itself refuses, so even the owner cannot rewrite history',
  (select tams_test.try_sql('update public.audit_logs set action = ''NOTHING_HAPPENED''')) = 'TA120'
  and (select tams_test.try_sql('delete from public.audit_logs')) = 'TA120'
  and (select tams_test.try_sql('truncate public.audit_logs')) = 'TA120'
);

select tams_test.check(
  'AUD 65 — a staff role change is audited, in role names rather than identifiers',
  (select action = 'STAFF_ROLE_CHANGED'
          and old_values ->> 'role' is not null
          and new_values ->> 'role' is not null
          and (new_values ? 'role_id') = false
          and changed_fields @> array['role']
   from tams_test.latest_audit('STAFF_ROLE_CHANGED'))
);

select tams_test.check(
  'AUD 63 — a reason is stored where one was given',
  (select reason is not null and length(reason) > 0
   from tams_test.latest_audit('STAFF_DEACTIVATED'))
  and (select reason = 'No farming land is available this season'
       from public.audit_logs
       where action = 'LAND_APPLICATION_DECLINED' order by created_at desc limit 1)
);

select tams_test.check(
  'AUD 66 — a resident status change is audited from and to',
  (select count(*) > 0 from public.audit_logs
    where action = 'RESIDENT_DECEASED'
      and old_values ->> 'resident_status' = 'active'
      and new_values ->> 'resident_status' = 'deceased')
);

select tams_test.check(
  'AUD 67 — a household head change is audited by name, not by identifier',
  (select count(*) > 0 from public.audit_logs
    where entity_type = 'household' and changed_fields @> array['head']
      and new_values ->> 'head' is not null
      and (new_values ? 'head_resident_id') = false)
);

select tams_test.check(
  'AUD 68 — family relationships, created and ended, are both audited',
  tams_test.audit_count('CREATE_FAMILY_RELATIONSHIP') > 0
  and (select count(*) > 0 from public.audit_logs
        where entity_type = 'family_relationship'
          and old_values ->> 'relationship_status' = 'active'
          and new_values ->> 'relationship_status' <> 'active'
          and changed_fields @> array['relationship_status'])
);

select tams_test.check(
  'AUD 69 — resident account approvals and declines are both audited',
  tams_test.audit_count('RESIDENT_ACCOUNT_REQUEST_APPROVED') > 0
  and tams_test.audit_count('RESIDENT_ACCOUNT_REQUEST_DECLINED') > 0
);

select tams_test.check(
  'AUD 70/71 — land decisions and allocations are audited',
  tams_test.audit_count('LAND_APPLICATION_APPROVED') > 0
  and tams_test.audit_count('LAND_APPLICATION_DECLINED') > 0
  and tams_test.audit_count('CREATE_LAND_ALLOCATION') > 0
  and (select entity_reference like 'ALLOC-%'
       from tams_test.latest_audit('CREATE_LAND_ALLOCATION'))
);

select tams_test.check(
  'AUD 72/73/74 — permissions being issued, renewed and revoked are audited',
  tams_test.audit_count('CREATE_PTO') > 0
  and tams_test.audit_count('PTO_RENEWED') > 0
  and tams_test.audit_count('PTO_REVOKED') > 0
  and (select old_values ->> 'pto_status' = 'active'
              and new_values ->> 'pto_status' = 'revoked'
              and reason is not null
       from tams_test.latest_audit('PTO_REVOKED'))
);

select tams_test.check(
  'AUD 75 — residential succession is audited on both sides of the handover',
  tams_test.audit_count('LAND_ALLOCATION_SUPERSEDED') > 0
  and tams_test.audit_count('PTO_SUPERSEDED') > 0
);

select tams_test.check(
  'AUD 76 — minutes being finalised is audited, without copying the minutes',
  (select count(*) > 0 from public.audit_logs
    where entity_type = 'meeting_minutes'
      and new_values ->> 'minutes_status' = 'final')
  and (select count(*) = 0 from public.audit_logs
        where entity_type = 'meeting_minutes'
          and (new_values ? 'minutes_content' or old_values ? 'minutes_content'))
);

select tams_test.check(
  'AUD 77 — a resolution''s visibility change is audited',
  (select count(*) > 0 from public.audit_logs
    where entity_type = 'resolution' and changed_fields @> array['visibility']
      and old_values ->> 'visibility' = 'public'
      and new_values ->> 'visibility' = 'internal')
  and tams_test.audit_count('CREATE_VISIBILITY_CHANGE') > 0
);

select tams_test.check(
  'AUD 78 — a project''s status and visibility changes are audited',
  tams_test.audit_count('PROJECT_CANCELLED') > 0
  and tams_test.audit_count('PROJECT_COMPLETED') > 0
  and (select count(*) > 0 from public.audit_logs
        where entity_type = 'project' and changed_fields @> array['visibility'])
  and tams_test.audit_count('PROJECT_MILESTONE_COMPLETED') > 0
);

select tams_test.check(
  'AUD 79 — the whole work request lifecycle is audited',
  tams_test.audit_count('SEND_STAFF_MESSAGE') > 0
  and tams_test.audit_count('ACKNOWLEDGE_WORK_REQUEST') > 0
  and tams_test.audit_count('RESOLVE_WORK_REQUEST') > 0
);

select tams_test.check(
  'AUD 80 — every official communication is audited by reference',
  (select count(distinct entity_reference) = 4 from public.audit_logs
    where action = 'SEND_RESIDENT_COMMUNICATION')
  and (select bool_and(entity_reference like 'COM-%') from public.audit_logs
       where action = 'SEND_RESIDENT_COMMUNICATION')
  and (select new_values ->> 'communication_type' = 'summons'
       from public.audit_logs
       where action = 'SEND_RESIDENT_COMMUNICATION'
         and entity_reference = tams_test.ref('COM-', 1)
         and new_values ? 'communication_type')
);

select tams_test.check(
  'AUD 48a — but not a word of what the notice or the private message said',
  (select count(*) = 0 from public.audit_logs
    where entity_type in ('resident_communication', 'staff_message')
      and (new_values ?| array['message', 'body', 'subject']
           or old_values ?| array['message', 'body', 'subject']))
  and (select count(*) = 0 from public.audit_logs
        where new_values::text like '%not recorded in the household they claim%')
);

select tams_test.check(
  'AUD 81 — no password, token, key or secret is anywhere in the trail',
  -- No audited field is even named like one…
  (select count(*) = 0 from public.audit_logs a,
     lateral (select k from jsonb_object_keys(coalesce(a.new_values, '{}'::jsonb)) as k
              union all
              select k from jsonb_object_keys(coalesce(a.old_values, '{}'::jsonb)) as k) as keys
    where keys.k ~* '(password|secret|token|api_key|service_role|private_key|credential)')
  -- specifically, the token that makes a permission verifiable is never copied
  and (select count(*) = 0 from public.audit_logs
        where entity_type = 'pto'
          and (new_values ? 'verification_token' or old_values ? 'verification_token'))
  and (select count(*) = 0 from public.audit_logs a, public.ptos p
        where coalesce(a.new_values::text, '') like '%' || p.verification_token || '%')
);

select tams_test.check(
  'AUD 82 — and no document path or content, only that somebody looked',
  (select count(*) = 0 from public.audit_logs
    where new_values ? 'storage_path' or old_values ? 'storage_path')
  and (select count(*) = 0 from public.audit_logs a, public.resident_request_documents d
        where coalesce(a.new_values::text, '') like '%' || d.storage_path || '%')
);

select tams_test.check(
  'AUD 43 — asking to see a verification document is itself audited, as metadata',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_open_verification_document(
      (select request_id from public.resident_request_documents limit 1),
      (select document_type from public.resident_request_documents limit 1))
  $sql$) = 'OK'
);

select tams_test.check(
  'AUD 43a — the record says who looked at what, and nothing of the document',
  (select actor_role = 'Registry Clerk'
          and new_values ->> 'document_type' is not null
          and new_values ->> 'applicant' is not null
          and (new_values ? 'storage_path') = false
          and (new_values ? 'file_name') = false
   from tams_test.latest_audit('VIEWED_VERIFICATION_DOCUMENT'))
  and tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.registry_open_verification_document(
      (select request_id from public.resident_request_documents limit 1), 'certified_id_copy')
  $sql$) = '42501'
);

select tams_test.check(
  'AUD 86/87/88 — no ordinary role may browse the trail',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select count(*) from public.admin_audit_logs()
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select count(*) from public.admin_audit_logs()
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select count(*) from public.admin_audit_logs()
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000028'), $sql$
    select count(*) from public.admin_audit_logs()
  $sql$) = '42501'
  -- and not by going round the function either
  and tams_test.query_as('authenticated', tams_test.clerk(), $sql$
    select count(*) from public.audit_logs
  $sql$) = '0'
  and tams_test.query_as('authenticated', tams_test.secretary(), $sql$
    select count(*) from public.audit_logs
  $sql$) = '0'
  and tams_test.query_as('anon', null, $sql$
    select count(*) from public.audit_logs
  $sql$) in ('0', 'ERROR:42501')
);

select tams_test.check(
  'AUD 89 — the Council Administrator reads it, and the filters work',
  tams_test.query_as('authenticated', tams_test.administrator(), $sql$
    select count(*) > 0 from public.admin_audit_logs()
  $sql$) = 'true'
  and tams_test.query_as('authenticated', tams_test.administrator(), $sql$
    select bool_and(actor_role = 'Registry Clerk')
    from public.admin_audit_logs(null, null, null, 'Registry Clerk')
  $sql$) = 'true'
  and tams_test.query_as('authenticated', tams_test.administrator(), $sql$
    select bool_and(action = 'PTO_REVOKED')
    from public.admin_audit_logs(null, null, null, null, 'PTO_REVOKED')
  $sql$) = 'true'
  and tams_test.query_as('authenticated', tams_test.administrator(), $sql$
    select bool_and(entity_type = 'household')
    from public.admin_audit_logs(null, null, null, null, null, 'household')
  $sql$) = 'true'
  and tams_test.query_as('authenticated', tams_test.administrator(), $sql$
    select count(*) > 0 from public.admin_audit_logs(current_date, current_date)
  $sql$) = 'true'
  and tams_test.query_as('authenticated', tams_test.administrator(), $sql$
    select count(*) > 0 from public.admin_audit_logs(null, null, 'Rita')
  $sql$) = 'true'
);

select tams_test.check(
  'AUD 52a — one event opens with its old and new values side by side',
  tams_test.query_as('authenticated', tams_test.administrator(), $sql$
    select public.admin_audit_log(
      (select audit_id from public.admin_audit_logs(null, null, null, null, 'PTO_REVOKED') limit 1))
      -> 'old_values' ->> 'pto_status'
  $sql$) = 'active'
  and tams_test.query_as('authenticated', tams_test.administrator(), $sql$
    select public.admin_audit_log(
      (select audit_id from public.admin_audit_logs(null, null, null, null, 'PTO_REVOKED') limit 1))
      -> 'new_values' ->> 'pto_status'
  $sql$) = 'revoked'
  and tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.admin_audit_log((select id from public.audit_logs limit 1))
  $sql$) = '42501'
);


-- =====================================================================
-- REGRESSION — before the administrator changes hands
-- =====================================================================

select tams_test.check(
  'REG 117 — Council Administrator staff management still works',
  tams_test.run_as('authenticated', tams_test.administrator(), $sql$
    select count(*) from public.admin_staff_accounts()
  $sql$) = 'OK'
  and tams_test.run_as('authenticated', tams_test.administrator(), $sql$
    select public.deactivate_staff_account(tams_test.staff_id_of('2026075'), 'Seconded elsewhere')
  $sql$) = 'OK'
  and tams_test.run_as('authenticated', tams_test.administrator(), $sql$
    select public.reactivate_staff_account(tams_test.staff_id_of('2026075'), 'Returned')
  $sql$) = 'OK'
);

select tams_test.check(
  'REG 118 — Registry Clerk functions still work',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_search_residents('Ndlovu')
  $sql$) = 'OK'
  and tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_search_households('HH-0009')
  $sql$) = 'OK'
);

select tams_test.check(
  'REG 119 — resident verification still works',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select count(*) from public.registry_pending_resident_requests()
  $sql$) = 'OK'
  and (select count(*) > 0 from public.resident_account_requests where request_status = 'approved')
);

select tams_test.check(
  'REG 120/121 — the Land Officer and the whole permission lifecycle still work',
  tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_dashboard()
  $sql$) = 'OK'
  and tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select count(*) from public.land_officer_ptos(null, null)
  $sql$) = 'OK'
  and tams_test.query_as('anon', null, $sql$
    select (public.verify_pto(tams_test.token_for_site('BUS-9501')) ->> 'found')
  $sql$) = 'true'
);

select tams_test.check(
  'REG 122/123 — the Council Secretary and Community Updates still work',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_dashboard()
  $sql$) = 'OK'
  and tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000028'), $sql$
    select public.resident_community_updates()
  $sql$) = 'OK'
  and tams_test.query_as('authenticated', tams_test.resident_uid('SYN0000000028'), $sql$
    select jsonb_array_length(public.resident_community_updates() -> 'projects') > 0
  $sql$) = 'true'
);

select tams_test.check(
  'REG 124 — the imported village register is untouched by any of this',
  (select count(*) = 20
   from public.land_allocations a join tams_test.imported_allocations i on i.id = a.id
   where a.allocation_reference = i.allocation_reference and a.resident_id = i.resident_id)
  and (select count(*) = 20
       from public.land_sites s join tams_test.imported_sites i on i.id = s.id
       where s.site_code = i.site_code and s.site_type = i.site_type)
  and (select count(*) = 200
       from public.family_relationships f join tams_test.imported_relationships i on i.id = f.id
       where f.relationship_status = 'active')
);


-- =====================================================================
-- ADMINISTRATOR TRANSFER
-- =====================================================================

select tams_test.check(
  'XFER 90 — only the current active Council Administrator may start one',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.transfer_council_administrator(
      tams_test.staff_id_of('2026071'), 'remain_staff', 'I would like to', tams_test.role_id_of('Land Officer'))
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.transfer_council_administrator(
      tams_test.staff_id_of('2026072'), 'deactivate', 'Me please')
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000028'), $sql$
    select public.transfer_council_administrator(
      tams_test.staff_id_of('2026071'), 'deactivate', 'Me please')
  $sql$) = '42501'
  and tams_test.run_as('anon', null, $sql$
    select public.transfer_council_administrator(
      tams_test.staff_id_of('2026071'), 'deactivate', 'Me please')
  $sql$) in ('42501', '42883')
);

select tams_test.check(
  'XFER 92 — the administrator cannot transfer to themselves',
  tams_test.run_as('authenticated', tams_test.administrator(), $sql$
    select public.transfer_council_administrator(
      tams_test.staff_id_of('2026011'), 'remain_staff', 'Keeping it', tams_test.role_id_of('Land Officer'))
  $sql$) = 'TA132'
);

select tams_test.check(
  'XFER 93/94 — the incoming administrator must be active, existing, ordinary staff',
  -- deactivated
  tams_test.run_as('authenticated', tams_test.administrator(), $sql$
    select public.transfer_council_administrator(
      tams_test.staff_id_of('2026073'), 'remain_staff', 'End of term', tams_test.role_id_of('Land Officer'))
  $sql$) = 'TA133'
  -- somebody who is not staff at all
  and tams_test.run_as('authenticated', tams_test.administrator(), $sql$
    select public.transfer_council_administrator(
      gen_random_uuid(), 'remain_staff', 'End of term', tams_test.role_id_of('Land Officer'))
  $sql$) = 'TA132'
);

select tams_test.check(
  'XFER 105 — a reason is required, and so is a decision about the outgoing one',
  tams_test.run_as('authenticated', tams_test.administrator(), $sql$
    select public.transfer_council_administrator(
      tams_test.staff_id_of('2026071'), 'remain_staff', '   ', tams_test.role_id_of('Registry Clerk'))
  $sql$) = 'TA130'
  and tams_test.run_as('authenticated', tams_test.administrator(), $sql$
    select public.transfer_council_administrator(
      tams_test.staff_id_of('2026071'), 'vanish', 'End of term')
  $sql$) = 'TA131'
  -- remaining as staff means choosing one of the three ordinary roles
  and tams_test.run_as('authenticated', tams_test.administrator(), $sql$
    select public.transfer_council_administrator(
      tams_test.staff_id_of('2026071'), 'remain_staff', 'End of term')
  $sql$) = 'TA134'
  and tams_test.run_as('authenticated', tams_test.administrator(), $sql$
    select public.transfer_council_administrator(
      tams_test.staff_id_of('2026071'), 'remain_staff', 'End of term',
      tams_test.role_id_of('Council Administrator'))
  $sql$) = 'TA134'
);

select tams_test.check(
  'XFER 96 — the ordinary role change still refuses to hand out the administrator role',
  tams_test.run_as('authenticated', tams_test.administrator(), $sql$
    select public.change_staff_role(tams_test.staff_id_of('2026071'),
      tams_test.role_id_of('Council Administrator'))
  $sql$) = 'TA014'
  -- and the database refuses a second active one however the row is written
  -- and the database refuses a second active one however the row is
  -- written: the service key is stopped by the table, and the owner by
  -- the trigger.
  and tams_test.run_as('service_role', null, $sql$
    update public.staff set role_id = (select id from public.roles
                                        where role_name = 'Council Administrator')
     where employee_number = '2026071'
  $sql$) in ('TA001', '42501')
  and tams_test.try_sql(
    'update public.staff set role_id = public.council_administrator_role_id()
       where employee_number = ''2026071''') = 'TA001'
);

select tams_test.check(
  'XFER 102 — nothing above changed anything: one administrator, still the same one',
  tams_test.admin_count() = 1
  and tams_test.role_of('2026011') = 'Council Administrator'
  and tams_test.role_of('2026071') = 'Land Officer'
);

-- ---- the real thing, three times over -------------------------------

select tams_test.check(
  'XFER 97 — the role is transferred and the outgoing administrator becomes a Registry Clerk',
  tams_test.run_as('authenticated', tams_test.administrator(), $sql$
    select public.transfer_council_administrator(
      tams_test.staff_id_of('2026071'), 'remain_staff',
      'End of term of office', tams_test.role_id_of('Registry Clerk'))
  $sql$) = 'OK'
);

select tams_test.check(
  'XFER 101/103/104 — exactly one administrator, and both authorisations moved at once',
  tams_test.admin_count() = 1
  and tams_test.role_of('2026071') = 'Council Administrator'
  and tams_test.role_of('2026011') = 'Registry Clerk'
  -- the outgoing one is no longer the administrator, in the same breath
  and tams_test.query_as('authenticated', tams_test.administrator(), $sql$
    select public.is_active_council_administrator()
  $sql$) = 'false'
  and tams_test.run_as('authenticated', tams_test.administrator(), $sql$
    select count(*) from public.admin_audit_logs()
  $sql$) = '42501'
  -- and the incoming one is, immediately
  and tams_test.query_as('authenticated', tams_test.officer(), $sql$
    select public.is_active_council_administrator()
  $sql$) = 'true'
  and tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select count(*) from public.admin_audit_logs()
  $sql$) = 'OK'
);

select tams_test.check(
  'XFER 106/107 — the transfer is permanently audited and both sides were told',
  (select actor_role = 'Council Administrator'
          and actor_label = 'Nature Khosa'
          and reason = 'End of term of office'
          and old_values ->> 'administrator' = 'Nature Khosa'
          and new_values ->> 'administrator' = 'Lance Officer'
          and new_values ->> 'outgoing_new_role' = 'Registry Clerk'
   from (select * from public.audit_logs
          where action = 'TRANSFER_COUNCIL_ADMINISTRATOR'
            and new_values ? 'outgoing_outcome'
          order by created_at desc, id desc limit 1) as t)
  and (select count(*) = 1 from public.notifications
        where title = 'You are now the Council Administrator'
          and recipient_user_account_id = tams_test.staff_account_id_of('2026071'))
  and (select count(*) = 1 from public.notifications
        where title = 'You are no longer the Council Administrator'
          and recipient_user_account_id = tams_test.staff_account_id_of('2026011'))
);

select tams_test.check(
  'XFER 95 — the new administrator cannot transfer to somebody who already holds the role',
  tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.transfer_council_administrator(
      tams_test.staff_id_of('2026071'), 'remain_staff', 'Circular', tams_test.role_id_of('Land Officer'))
  $sql$) = 'TA132'
);

select tams_test.check(
  'XFER 98 — a second transfer, with the outgoing one becoming a Land Officer',
  tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.transfer_council_administrator(
      tams_test.staff_id_of('2026070'), 'remain_staff',
      'Staff restructuring', tams_test.role_id_of('Land Officer'))
  $sql$) = 'OK'
);

select tams_test.check(
  'XFER 98a — and again exactly one administrator',
  tams_test.admin_count() = 1
  and tams_test.role_of('2026070') = 'Council Administrator'
  and tams_test.role_of('2026071') = 'Land Officer'
);

select tams_test.check(
  'XFER 99 — a third, with the outgoing one becoming a Council Secretary, handing it back',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.transfer_council_administrator(
      tams_test.staff_id_of('2026011'), 'remain_staff',
      'Returning to the substantive post holder', tams_test.role_id_of('Council Secretary'))
  $sql$) = 'OK'
);

select tams_test.check(
  'XFER 99a — the original administrator has it back, and still only one',
  tams_test.admin_count() = 1
  and tams_test.role_of('2026011') = 'Council Administrator'
  and tams_test.role_of('2026070') = 'Council Secretary'
  and tams_test.query_as('authenticated', tams_test.administrator(), $sql$
    select public.is_active_council_administrator()
  $sql$) = 'true'
);

select tams_test.check(
  'XFER 91 — the incoming one must hold an ordinary role now, not have held one once',
  -- 2026070 is a Council Secretary at this moment, so they qualify…
  tams_test.query_as('authenticated', tams_test.administrator(), $sql$
    select count(*) from public.admin_transfer_candidates()
    where employee_number = '2026070'
  $sql$) = '1'
  -- …and a deactivated staff member never appears among the candidates
  and tams_test.query_as('authenticated', tams_test.administrator(), $sql$
    select count(*) from public.admin_transfer_candidates()
    where employee_number in ('2026073', '2026074')
  $sql$) = '0'
  and tams_test.query_as('authenticated', tams_test.administrator(), $sql$
    select count(*) from public.admin_transfer_candidates()
    where role_name = 'Council Administrator'
  $sql$) = '0'
);

select tams_test.check(
  'XFER 100 — the outgoing administrator may instead be deactivated',
  tams_test.run_as('authenticated', tams_test.administrator(), $sql$
    select public.transfer_council_administrator(
      tams_test.staff_id_of('2026072'), 'deactivate',
      'Outgoing administrator is leaving employment')
  $sql$) = 'OK'
);

select tams_test.check(
  'XFER 100a — their account is deactivated, the record still says who they were, and one administrator remains',
  tams_test.status_of('2026011') = 'deactivated'
  and tams_test.role_of('2026011') = 'Council Administrator'
  and tams_test.role_of('2026072') = 'Council Administrator'
  and tams_test.admin_count() = 1
  and tams_test.query_as('authenticated', tams_test.administrator(), $sql$
    select public.is_active_council_administrator()
  $sql$) = 'false'
  and tams_test.query_as('authenticated', tams_test.secretary(), $sql$
    select public.is_active_council_administrator()
  $sql$) = 'true'
);

select tams_test.check(
  'XFER 61a — and the deactivated former administrator cannot simply be switched back on',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.reactivate_staff_account(tams_test.staff_id_of('2026011'), 'Back please')
  $sql$) = 'TA011'
  and tams_test.run_as('service_role', null, $sql$
    update public.user_accounts set account_status = 'active'
     where email = 'admin@ta.example'
  $sql$) = 'TA001'
);


-- =====================================================================
-- EMERGENCY RECOVERY
-- =====================================================================

select tams_test.check(
  'REC 108 — recovery refuses while an administrator who can sign in exists',
  (select (public.administrator_health() ->> 'valid_administrators')::int = 1)
  and tams_test.run_as('service_role', null, $sql$
    select public.emergency_promote_administrator(
      tams_test.staff_id_of('2026070'), 'I would like to be the administrator')
  $sql$) = 'TA137'
);

select tams_test.check(
  'REC 110/111 — and it is not reachable from a browser at any privilege',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.emergency_promote_administrator(tams_test.staff_id_of('2026070'), 'Please')
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.administrator_health()
  $sql$) = '42501'
  and tams_test.run_as('anon', null, $sql$
    select public.emergency_promote_administrator(tams_test.staff_id_of('2026070'), 'Please')
  $sql$) in ('42501', '42883')
);

-- The emergency itself: the last administrator's account is gone.
select tams_test.deactivate_account_directly('councilsec@ta.example');

select tams_test.check(
  'REC 109a — with nobody able to sign in as administrator, the database says so',
  (select (public.administrator_health() ->> 'valid_administrators')::int = 0)
);

select tams_test.check(
  'REC 112 — recovery still refuses anybody who is not active ordinary staff',
  tams_test.run_as('service_role', null, $sql$
    select public.emergency_promote_administrator(tams_test.staff_id_of('2026073'), 'They were here once')
  $sql$) = 'TA138'
  and tams_test.run_as('service_role', null, $sql$
    select public.emergency_promote_administrator(tams_test.staff_id_of('2026011'), 'The old one')
  $sql$) = 'TA138'
  and tams_test.run_as('service_role', null, $sql$
    select public.emergency_promote_administrator(gen_random_uuid(), 'Anybody')
  $sql$) = 'TA138'
  and tams_test.run_as('service_role', null, $sql$
    select public.emergency_promote_administrator(tams_test.staff_id_of('2026070'), '   ')
  $sql$) = 'TA136'
);

select tams_test.check(
  'REC 109/113 — recovery promotes an existing ordinary staff member',
  tams_test.run_as('service_role', null, $sql$
    select public.emergency_promote_administrator(
      tams_test.staff_id_of('2026070'),
      'The last administrator left and their sign-in was removed')
  $sql$) = 'OK'
);

select tams_test.check(
  'REC 113a — exactly one active administrator again, and normal rules resume',
  tams_test.admin_count() = 1
  and tams_test.role_of('2026070') = 'Council Administrator'
  and tams_test.query_as('authenticated', tams_test.clerk(), $sql$
    select public.is_active_council_administrator()
  $sql$) = 'true'
  and tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select count(*) from public.admin_audit_logs()
  $sql$) = 'OK'
);

select tams_test.check(
  'REC 114 — and it refuses again the moment there is an administrator',
  tams_test.run_as('service_role', null, $sql$
    select public.emergency_promote_administrator(tams_test.staff_id_of('2026071'), 'Me as well')
  $sql$) = 'TA137'
  and tams_test.admin_count() = 1
);

select tams_test.check(
  'REC 116 — the recovery is audited, with who, from what, and why',
  (select action = 'EMERGENCY_ADMIN_RECOVERY'
          and entity_reference = '2026070'
          and old_values ->> 'role' = 'Council Secretary'
          and new_values ->> 'role' = 'Council Administrator'
          and new_values ->> 'recovered_by' = 'emergency recovery process'
          and reason = 'The last administrator left and their sign-in was removed'
          and actor_role = 'system'
   from (select * from public.audit_logs
          where action = 'EMERGENCY_ADMIN_RECOVERY' and new_values ? 'recovered_by'
          order by created_at desc, id desc limit 1) as t)
);

select tams_test.check(
  'REC 115 — and the recovery secret is nowhere in the trail, because it never reached the database',
  (select count(*) = 0 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'emergency_promote_administrator'
      and pg_get_function_arguments(p.oid) ilike '%secret%')
  and (select count(*) = 0 from public.audit_logs a,
         lateral (select k from jsonb_object_keys(coalesce(a.new_values, '{}'::jsonb)) as k
                  union all
                  select k from jsonb_object_keys(coalesce(a.old_values, '{}'::jsonb)) as k) as keys
        where keys.k ~* '(secret|token|password)')
  -- and the promoted staff member was told, in words that give nothing away
  and (select count(*) > 0 from public.notifications
        where title = 'You are now the Council Administrator'
          and recipient_user_account_id = tams_test.staff_account_id_of('2026070')
          and message like '%emergency recovery%'
          and message not ilike '%secret%')
);
