-- =====================================================================
-- TAMS — the Council Secretary: meetings, attendance, minutes,
-- amendments, resolutions, projects, milestones, and what a resident
-- may see of any of it.
-- =====================================================================

create function tams_test.secretary() returns uuid language sql stable as $$
  select tams_test.uid_of('councilsec@ta.example');
$$;

-- A Council Secretary whose account has since been deactivated.
insert into auth.users (email, last_sign_in_at) values ('exsec@ta.example', now());
select public.create_staff_with_account(
  tams_test.uid_of('exsec@ta.example'), '2026074', 'Sipho', 'Wasasecretary',
  'exsec@ta.example', '0728210074', tams_test.role_id_of('Council Secretary'));
update public.user_accounts set account_status = 'deactivated' where email = 'exsec@ta.example';

create function tams_test.ex_secretary() returns uuid language sql stable as $$
  select tams_test.uid_of('exsec@ta.example');
$$;

-- A staff member of this suite's own, so the administrator regression
-- test disturbs nobody else's fixture.
insert into auth.users (email, last_sign_in_at) values ('newstaff@ta.example', now());
select public.create_staff_with_account(
  tams_test.uid_of('newstaff@ta.example'), '2026075', 'Nandi', 'Newstaff',
  'newstaff@ta.example', '0728210075', tams_test.role_id_of('Land Officer'));

create function tams_test.administrator() returns uuid language sql stable as $$
  select tams_test.uid_of('admin@ta.example');
$$;

-- Resident accounts that never got through verification.
create function tams_test.make_resident_account(p_email text, p_status text)
returns uuid language plpgsql volatile security definer as $$
declare v_uid uuid;
begin
  insert into auth.users (email, last_sign_in_at) values (p_email, now()) returning id into v_uid;
  insert into public.user_accounts (auth_user_id, email, account_type, account_status)
  values (v_uid, p_email, 'resident', p_status);
  return v_uid;
end; $$;

select tams_test.make_resident_account('stillwaiting@village.example', 'pending');
select tams_test.make_resident_account('turneddown@village.example',  'declined');

create function tams_test.pending_resident() returns uuid language sql stable security definer as $$
  select auth_user_id from public.user_accounts where email = 'stillwaiting@village.example';
$$;
create function tams_test.declined_resident() returns uuid language sql stable security definer as $$
  select auth_user_id from public.user_accounts where email = 'turneddown@village.example';
$$;

-- A verified resident from the land suite, still active.
create function tams_test.villager() returns uuid language sql stable as $$
  select tams_test.resident_uid('SYN0000000028');
$$;

-- Definer lookups, so a test can hand a function a real id even when
-- the caller being tested could never look it up.
create function tams_test.meeting_id(p_reference text) returns uuid
language sql stable security definer as $$
  select id from public.council_meetings where meeting_reference = p_reference;
$$;

create function tams_test.minutes_id(p_meeting_reference text) returns uuid
language sql stable security definer as $$
  select mm.id from public.meeting_minutes mm
  join public.council_meetings m on m.id = mm.meeting_id
  where m.meeting_reference = p_meeting_reference;
$$;

create function tams_test.resolution_id(p_reference text) returns uuid
language sql stable security definer as $$
  select id from public.council_resolutions where resolution_reference = p_reference;
$$;

create function tams_test.project_id(p_reference text) returns uuid
language sql stable security definer as $$
  select id from public.community_projects where project_reference = p_reference;
$$;

create function tams_test.milestone_id(p_project_reference text, p_title text) returns uuid
language sql stable security definer as $$
  select ms.id from public.project_milestones ms
  join public.community_projects p on p.id = ms.project_id
  where p.project_reference = p_project_reference and ms.title = p_title;
$$;

create function tams_test.token_for_site(p_site_code text) returns text
language sql stable security definer as $$
  select p.verification_token from public.ptos p
  join public.land_allocations a on a.id = p.land_allocation_id
  join public.land_sites s on s.id = a.land_site_id
  where s.site_code = p_site_code order by p.issue_date desc limit 1;
$$;

create function tams_test.this_year() returns text language sql stable as $$
  select to_char(current_date, 'YYYY');
$$;

create function tams_test.ref(p_prefix text, p_number int) returns text
language sql stable as $$
  select p_prefix || tams_test.this_year() || '-' || lpad(p_number::text, 4, '0');
$$;


-- =====================================================================
-- AUTHORIZATION
-- =====================================================================

select tams_test.check(
  'SEC 1 — an active Council Secretary may schedule a meeting',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_schedule_meeting(
      'First ordinary council meeting', 'ordinary',
      (current_date + 14)::date, time '10:00', 'Traditional Council Hall',
      'Opening, apologies, land matters, closing')
  $sql$) = 'OK'
);

select tams_test.check(
  'SEC 2 — a signed-out request is refused',
  tams_test.run_as('anon', null, $sql$
    select public.secretary_schedule_meeting('Sneaky', 'ordinary', current_date + 1,
      time '09:00', 'Nowhere', 'Nothing')
  $sql$) in ('42501', '42883')
  and tams_test.query_as('anon', null, $sql$
    select count(*) from public.council_meetings
  $sql$) in ('0', 'ERROR:42501')
);

select tams_test.check(
  'SEC 3 — a resident is refused every Secretary write',
  tams_test.run_as('authenticated', tams_test.villager(), $sql$
    select public.secretary_schedule_meeting('Resident meeting', 'special', current_date + 1,
      time '09:00', 'Hall', 'Agenda')
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.villager(), $sql$
    select public.secretary_record_resolution(
      tams_test.meeting_id(tams_test.ref('MTG-', 1)), 'We resolve', 'public')
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.villager(), $sql$
    select public.secretary_create_project('Mine', 'Mine', current_date, null, null, 'public')
  $sql$) = '42501'
);

select tams_test.check(
  'SEC 4 — a Registry Clerk is refused',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.secretary_schedule_meeting('Clerk meeting', 'ordinary', current_date + 1,
      time '09:00', 'Hall', 'Agenda')
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.secretary_save_minutes(tams_test.meeting_id(tams_test.ref('MTG-', 1)), 'Notes')
  $sql$) = '42501'
);

select tams_test.check(
  'SEC 5 — a Land Officer is refused',
  tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.secretary_schedule_meeting('Officer meeting', 'ordinary', current_date + 1,
      time '09:00', 'Hall', 'Agenda')
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.secretary_dashboard()
  $sql$) = '42501'
);

select tams_test.check(
  'SEC 6 — the Council Administrator does not gain Secretary writes by being the administrator',
  tams_test.run_as('authenticated', tams_test.administrator(), $sql$
    select public.secretary_schedule_meeting('Administrator meeting', 'ordinary', current_date + 1,
      time '09:00', 'Hall', 'Agenda')
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.administrator(), $sql$
    select public.secretary_record_resolution(
      tams_test.meeting_id(tams_test.ref('MTG-', 1)), 'By order of the administrator', 'public')
  $sql$) = '42501'
  and tams_test.query_as('authenticated', tams_test.administrator(), $sql$
    select count(*) from public.council_meetings
  $sql$) = '0'
);

select tams_test.check(
  'SEC 7 — a Council Secretary whose account was deactivated is refused at once',
  tams_test.run_as('authenticated', tams_test.ex_secretary(), $sql$
    select public.secretary_schedule_meeting('Former secretary', 'ordinary', current_date + 1,
      time '09:00', 'Hall', 'Agenda')
  $sql$) = '42501'
  and tams_test.query_as('authenticated', tams_test.ex_secretary(), $sql$
    select count(*) from public.council_meetings
  $sql$) = '0'
);


-- =====================================================================
-- MEETINGS
-- =====================================================================

select tams_test.check(
  'MTG 8 — an ordinary meeting is scheduled',
  (select meeting_type = 'ordinary' and meeting_status = 'scheduled'
          and title = 'First ordinary council meeting'
   from public.council_meetings where meeting_reference = tams_test.ref('MTG-', 1))
);

select tams_test.check(
  'MTG 9 — a special meeting is scheduled',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_schedule_meeting('Special meeting on the burial grounds', 'special',
      (current_date + 21)::date, time '14:30', 'Traditional Council Hall', 'Burial grounds')
  $sql$) = 'OK'
);

select tams_test.check(
  'MTG 9a — and it is stored as special',
  (select meeting_type = 'special' from public.council_meetings
   where meeting_reference = tams_test.ref('MTG-', 2))
);

select tams_test.check(
  'MTG 10 — an emergency meeting is scheduled',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_schedule_meeting('Emergency meeting on the water supply', 'emergency',
      current_date, time '08:00', 'Traditional Council Hall', 'Water supply')
  $sql$) = 'OK'
);

select tams_test.check(
  'MTG 10a — and it is stored as emergency',
  (select meeting_type = 'emergency' from public.council_meetings
   where meeting_reference = tams_test.ref('MTG-', 3))
);

select tams_test.check(
  'MTG 11 — a kind of meeting that does not exist is refused',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_schedule_meeting('Imaginary', 'informal', current_date + 1,
      time '09:00', 'Hall', 'Agenda')
  $sql$) = 'TA082'
  and tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_schedule_meeting('Imaginary', null, current_date + 1,
      time '09:00', 'Hall', 'Agenda')
  $sql$) = 'TA082'
);

select tams_test.check(
  'MTG 11a — a meeting needs a title, a venue and an agenda',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_schedule_meeting('   ', 'ordinary', current_date + 1,
      time '09:00', 'Hall', 'Agenda')
  $sql$) = 'TA081'
  and tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_schedule_meeting('Titled', 'ordinary', current_date + 1,
      time '09:00', 'Hall', '  ')
  $sql$) = 'TA081'
);

select tams_test.check(
  'MTG 12 — every meeting reference is unique, and carries the year',
  (select count(distinct meeting_reference) = count(*) from public.council_meetings)
  and (select count(*) = 3 from public.council_meetings
       where meeting_reference like 'MTG-' || tams_test.this_year() || '-%')
);

select tams_test.check(
  'MTG 12a — the browser cannot set a reference, because it is not a parameter',
  (select count(*) = 0 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'secretary_schedule_meeting'
      and pg_get_function_arguments(p.oid) ilike '%reference%')
);

select tams_test.check(
  'MTG 6a — a date nobody could have meant is refused',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_schedule_meeting('Far future', 'ordinary',
      (current_date + make_interval(years => 40))::date, time '09:00', 'Hall', 'Agenda')
  $sql$) = 'TA083'
  and tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_schedule_meeting('Long ago', 'ordinary',
      (current_date - make_interval(years => 40))::date, time '09:00', 'Hall', 'Agenda')
  $sql$) = 'TA083'
  and tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_schedule_meeting('No time', 'ordinary', current_date + 1,
      null, 'Hall', 'Agenda')
  $sql$) = 'TA083'
);

select tams_test.check(
  'MTG 13 — a scheduled meeting becomes held',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_set_meeting_status(tams_test.meeting_id(tams_test.ref('MTG-', 3)), 'held')
  $sql$) = 'OK'
);

select tams_test.check(
  'MTG 13a — and who recorded that, and when, is kept',
  (select meeting_status = 'held' and held_recorded_at is not null
          and held_recorded_by_staff_id = (select id from public.staff where employee_number = '2026072')
   from public.council_meetings where meeting_reference = tams_test.ref('MTG-', 3))
);

select tams_test.check(
  'MTG 14 — cancelling a meeting needs a reason',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_set_meeting_status(
      tams_test.meeting_id(tams_test.ref('MTG-', 2)), 'cancelled')
  $sql$) = 'TA087'
  and tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_set_meeting_status(
      tams_test.meeting_id(tams_test.ref('MTG-', 2)), 'cancelled', '   ')
  $sql$) = 'TA087'
  and tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_set_meeting_status(
      tams_test.meeting_id(tams_test.ref('MTG-', 2)), 'cancelled',
      'The Chief could not attend and the matter was carried over')
  $sql$) = 'OK'
);

select tams_test.check(
  'MTG 15 — the cancelled meeting is still there, with its reason and who cancelled it',
  (select meeting_status = 'cancelled'
          and cancellation_reason = 'The Chief could not attend and the matter was carried over'
          and cancelled_at is not null and cancelled_by_staff_id is not null
          and title = 'Special meeting on the burial grounds'
   from public.council_meetings where meeting_reference = tams_test.ref('MTG-', 2))
);

select tams_test.check(
  'MTG 16 — a held meeting cannot go back to scheduled, and a cancelled one cannot become held',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_set_meeting_status(
      tams_test.meeting_id(tams_test.ref('MTG-', 3)), 'scheduled')
  $sql$) = 'TA086'
  and tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_set_meeting_status(
      tams_test.meeting_id(tams_test.ref('MTG-', 2)), 'held')
  $sql$) = 'TA086'
  and tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_set_meeting_status(
      tams_test.meeting_id(tams_test.ref('MTG-', 3)), 'nonsense')
  $sql$) = 'TA086'
);

select tams_test.check(
  'MTG 16a — a held meeting''s own details cannot be rewritten',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_update_meeting(tams_test.meeting_id(tams_test.ref('MTG-', 3)),
      'Rewritten history', 'ordinary', current_date, time '23:00', 'Elsewhere', 'Something else')
  $sql$) = 'TA085'
  and (select title = 'Emergency meeting on the water supply' and meeting_type = 'emergency'
       from public.council_meetings where meeting_reference = tams_test.ref('MTG-', 3))
);

select tams_test.check(
  'MTG 16b — a scheduled meeting can still be corrected',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_update_meeting(tams_test.meeting_id(tams_test.ref('MTG-', 1)),
      'First ordinary council meeting', 'ordinary', (current_date + 15)::date,
      time '11:00', 'Traditional Council Hall', 'Opening, apologies, land matters, projects, closing')
  $sql$) = 'OK'
);

-- A separate statement: a read in the same statement as the write above
-- would use the snapshot taken before it.
select tams_test.check(
  'MTG 16c — and the correction is in the record',
  (select start_time = time '11:00' and agenda like '%projects%'
   from public.council_meetings where meeting_reference = tams_test.ref('MTG-', 1))
);


-- =====================================================================
-- ATTENDANCE
-- =====================================================================

select tams_test.check(
  'ATT 17 — an attendee needs no TAMS account of any kind',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_add_attendee(tams_test.meeting_id(tams_test.ref('MTG-', 3)),
      'Hosi Mhinga', 'Chief', 'present')
  $sql$) = 'OK'
  and tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_add_attendee(tams_test.meeting_id(tams_test.ref('MTG-', 3)),
      'Ndhuna Baloyi', 'Headman', 'present')
  $sql$) = 'OK'
  and tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_add_attendee(tams_test.meeting_id(tams_test.ref('MTG-', 3)),
      'Mrs Chauke', 'Community representative', 'apology')
  $sql$) = 'OK'
);

select tams_test.check(
  'ATT 17a — and the table has no column that could demand one',
  (select count(*) = 0 from information_schema.columns
    where table_schema = 'public' and table_name = 'meeting_attendance'
      and column_name in ('user_account_id', 'resident_id', 'staff_id', 'auth_user_id'))
  and (select count(*) = 3 from public.meeting_attendance a
       join public.council_meetings m on m.id = a.meeting_id
       where m.meeting_reference = tams_test.ref('MTG-', 3))
);

select tams_test.check(
  'ATT 17b — only present, absent or apology',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_add_attendee(tams_test.meeting_id(tams_test.ref('MTG-', 3)),
      'Somebody', 'Guest', 'maybe')
  $sql$) = 'TA089'
  and tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_add_attendee(tams_test.meeting_id(tams_test.ref('MTG-', 3)),
      '   ', 'Guest', 'present')
  $sql$) = 'TA088'
);

select tams_test.check(
  'ATT 18 — attendance belongs to the meeting it was recorded against, and no other',
  (select count(*) = 0 from public.meeting_attendance a
    join public.council_meetings m on m.id = a.meeting_id
    where m.meeting_reference <> tams_test.ref('MTG-', 3))
  and (select bool_and(m.meeting_reference = tams_test.ref('MTG-', 3))
       from public.meeting_attendance a join public.council_meetings m on m.id = a.meeting_id)
);

select tams_test.check(
  'ATT 19 — a resident cannot read attendance at all',
  tams_test.query_as('authenticated', tams_test.villager(), $sql$
    select count(*) from public.meeting_attendance
  $sql$) = '0'
  and tams_test.query_as('anon', null, $sql$
    select count(*) from public.meeting_attendance
  $sql$) in ('0', 'ERROR:42501')
  and tams_test.query_as('authenticated', tams_test.clerk(), $sql$
    select count(*) from public.meeting_attendance
  $sql$) = '0'
);

select tams_test.check(
  'ATT 18a — an attendee can be corrected while the minutes are still a draft',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_update_attendee(
      (select a.id from public.meeting_attendance a
        join public.council_meetings m on m.id = a.meeting_id
        where m.meeting_reference = tams_test.ref('MTG-', 3) and a.attendee_name = 'Mrs Chauke'),
      'Mrs N Chauke', 'Community representative', 'present')
  $sql$) = 'OK'
);


-- =====================================================================
-- MINUTES
-- =====================================================================

select tams_test.check(
  'MIN 22 — a draft is created and can then be edited',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_save_minutes(tams_test.meeting_id(tams_test.ref('MTG-', 3)),
      'The council met to discuss the water supply.')
  $sql$) = 'OK'
  and tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_save_minutes(tams_test.meeting_id(tams_test.ref('MTG-', 3)),
      'The council met to discuss the water supply. Three boreholes were reported dry.')
  $sql$) = 'OK'
);

select tams_test.check(
  'MIN 22a — and the draft holds the later wording, with no finalisation recorded',
  (select minutes_content = 'The council met to discuss the water supply. Three boreholes were reported dry.'
          and minutes_status = 'draft'
          and finalized_at is null and finalized_by_staff_id is null
   from public.meeting_minutes mm join public.council_meetings m on m.id = mm.meeting_id
   where m.meeting_reference = tams_test.ref('MTG-', 3))
);

select tams_test.check(
  'MIN 21 — a meeting has at most one minutes record, however many times it is saved',
  (select count(*) = 1 from public.meeting_minutes mm
    join public.council_meetings m on m.id = mm.meeting_id
    where m.meeting_reference = tams_test.ref('MTG-', 3))
  -- and the database itself would refuse a second one
  and tams_test.run_as('service_role', null, $sql$
    insert into public.meeting_minutes (meeting_id, minutes_content)
    values (tams_test.meeting_id(tams_test.ref('MTG-', 3)), 'A rival set of minutes')
  $sql$) = '23505'
);

select tams_test.check(
  'MIN 21a — a cancelled meeting has no minutes to write',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_save_minutes(tams_test.meeting_id(tams_test.ref('MTG-', 2)), 'Notes')
  $sql$) = 'TA092'
);

select tams_test.check(
  'MIN 23a — minutes of a meeting that was never held cannot be finalised',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_finalize_minutes(tams_test.meeting_id(tams_test.ref('MTG-', 1)))
  $sql$) = 'TA092'
);

-- A second meeting that was held, so that a draft survives to the end
-- of the suite for the resident tests to look for.
select tams_test.run_as('authenticated', tams_test.secretary(), $sql$
  select public.secretary_schedule_meeting('Ordinary meeting on community projects', 'ordinary',
    (current_date - 7)::date, time '10:00', 'Traditional Council Hall',
    'Projects, resolutions, closing')
$sql$);
select tams_test.run_as('authenticated', tams_test.secretary(), $sql$
  select public.secretary_set_meeting_status(tams_test.meeting_id(tams_test.ref('MTG-', 4)), 'held')
$sql$);
select tams_test.run_as('authenticated', tams_test.secretary(), $sql$
  select public.secretary_save_minutes(tams_test.meeting_id(tams_test.ref('MTG-', 4)),
    'The council considered the community projects for the coming year.')
$sql$);

select tams_test.check(
  'MIN 23 — finalising records the status, the moment and the Secretary who did it',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_finalize_minutes(tams_test.meeting_id(tams_test.ref('MTG-', 3)))
  $sql$) = 'OK'
);

select tams_test.check(
  'MIN 23b — and those three things are all in the record',
  (select minutes_status = 'final' and finalized_at is not null
          and finalized_by_staff_id = (select id from public.staff where employee_number = '2026072')
   from public.meeting_minutes mm join public.council_meetings m on m.id = mm.meeting_id
   where m.meeting_reference = tams_test.ref('MTG-', 3))
);

select tams_test.check(
  'MIN 24 — final minutes cannot be edited, and cannot be finalised twice',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_save_minutes(tams_test.meeting_id(tams_test.ref('MTG-', 3)),
      'Something quite different')
  $sql$) = 'TA093'
  and tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_finalize_minutes(tams_test.meeting_id(tams_test.ref('MTG-', 3)))
  $sql$) = 'TA093'
);

select tams_test.check(
  'MIN 24a — and the wording is untouched by the attempt',
  (select minutes_content = 'The council met to discuss the water supply. Three boreholes were reported dry.'
   from public.meeting_minutes mm join public.council_meetings m on m.id = mm.meeting_id
   where m.meeting_reference = tams_test.ref('MTG-', 3))
);

select tams_test.check(
  'MIN 25 — final minutes cannot be deleted, and nobody can write to the table directly',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    delete from public.meeting_minutes
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    update public.meeting_minutes set minutes_content = 'Rewritten'
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    insert into public.meeting_minutes (meeting_id, minutes_content)
    values (tams_test.meeting_id(tams_test.ref('MTG-', 1)), 'By hand')
  $sql$) = '42501'
);

select tams_test.check(
  'MIN 25a — there is no insert, update or delete policy on any Council Secretary table',
  (select count(*) = 0 from pg_policies
    where schemaname = 'public'
      and tablename in ('council_meetings', 'meeting_attendance', 'meeting_minutes',
                        'meeting_minutes_amendments', 'council_resolutions',
                        'community_projects', 'project_milestones', 'visibility_changes')
      and cmd <> 'SELECT')
);

select tams_test.check(
  'ATT 20 — attendance is kept once the minutes are final, and closed to further change',
  (select count(*) = 3 from public.meeting_attendance a
    join public.council_meetings m on m.id = a.meeting_id
    where m.meeting_reference = tams_test.ref('MTG-', 3))
  and tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_add_attendee(tams_test.meeting_id(tams_test.ref('MTG-', 3)),
      'Latecomer', 'Guest', 'present')
  $sql$) = 'TA090'
  and tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_update_attendee(
      (select a.id from public.meeting_attendance a
        join public.council_meetings m on m.id = a.meeting_id
        where m.meeting_reference = tams_test.ref('MTG-', 3) and a.attendee_name = 'Hosi Mhinga'),
      'Somebody else', 'Chief', 'absent')
  $sql$) = 'TA090'
);


-- =====================================================================
-- AMENDMENTS
-- =====================================================================

select tams_test.check(
  'AMD 26 — a draft cannot be amended; it is simply edited',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_add_amendment(tams_test.minutes_id(tams_test.ref('MTG-', 4)),
      'A correction', 'Because')
  $sql$) = 'TA095'
);

select tams_test.check(
  'AMD 28 — an amendment needs both the correction and a reason',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_add_amendment(tams_test.minutes_id(tams_test.ref('MTG-', 3)),
      'Four boreholes, not three', '   ')
  $sql$) = 'TA096'
  and tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_add_amendment(tams_test.minutes_id(tams_test.ref('MTG-', 3)),
      '  ', 'A number was wrong')
  $sql$) = 'TA096'
);

select tams_test.check(
  'AMD 27 — final minutes can receive an amendment',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_add_amendment(tams_test.minutes_id(tams_test.ref('MTG-', 3)),
      'Four boreholes were reported dry, not three.',
      'The number was taken down wrongly at the meeting')
  $sql$) = 'OK'
);

select tams_test.check(
  'AMD 29 — the original final minutes are word for word what they were',
  (select minutes_content = 'The council met to discuss the water supply. Three boreholes were reported dry.'
          and minutes_status = 'final'
   from public.meeting_minutes mm join public.council_meetings m on m.id = mm.meeting_id
   where m.meeting_reference = tams_test.ref('MTG-', 3))
);

select tams_test.check(
  'AMD 30 — the amendment is stored with its reference, its reason and its author',
  (select count(*) = 1 from public.meeting_minutes_amendments am
    where am.minutes_id = tams_test.minutes_id(tams_test.ref('MTG-', 3)))
  and (select amendment_reference = tams_test.ref('AMD-', 1)
              and reason = 'The number was taken down wrongly at the meeting'
              and created_by_staff_id is not null
       from public.meeting_minutes_amendments
       where minutes_id = tams_test.minutes_id(tams_test.ref('MTG-', 3)))
);

select tams_test.check(
  'AMD 30a — and an amendment cannot be deleted or edited directly',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    delete from public.meeting_minutes_amendments
  $sql$) = '42501'
);


-- =====================================================================
-- RESOLUTIONS
-- =====================================================================

select tams_test.check(
  'RES 31 — one meeting may produce several resolutions',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_record_resolution(tams_test.meeting_id(tams_test.ref('MTG-', 3)),
      'The council resolves to repair the three dry boreholes before the end of the season.',
      'public')
  $sql$) = 'OK'
  and tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_record_resolution(tams_test.meeting_id(tams_test.ref('MTG-', 3)),
      'The council resolves to ask the municipality for a water tanker in the interim.',
      'public')
  $sql$) = 'OK'
  and tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_record_resolution(tams_test.meeting_id(tams_test.ref('MTG-', 3)),
      'The council resolves to review the borehole contractor''s fees in closed session.',
      'internal')
  $sql$) = 'OK'
);

select tams_test.check(
  'RES 31a — all three belong to that meeting',
  (select count(*) = 3 from public.council_resolutions r
    join public.council_meetings m on m.id = r.meeting_id
    where m.meeting_reference = tams_test.ref('MTG-', 3))
);

select tams_test.check(
  'RES 32 — references are unique and carry the year',
  (select count(distinct resolution_reference) = count(*) from public.council_resolutions)
  and (select count(*) = 3 from public.council_resolutions
       where resolution_reference like 'RES-' || tams_test.this_year() || '-%')
);

select tams_test.check(
  'RES 18a — the decision date comes from the meeting, and is not a parameter at all',
  (select decision_date = (select meeting_date from public.council_meetings
                            where meeting_reference = tams_test.ref('MTG-', 3))
   from public.council_resolutions where resolution_reference = tams_test.ref('RES-', 1))
  and (select count(*) = 0 from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname = 'secretary_record_resolution'
          and pg_get_function_arguments(p.oid) ilike '%date%')
);

select tams_test.check(
  'RES 33 — an active resolution becomes implemented',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_set_resolution_status(
      tams_test.resolution_id(tams_test.ref('RES-', 2)), 'implemented')
  $sql$) = 'OK'
);

select tams_test.check(
  'RES 33a — and the implementation is recorded',
  (select resolution_status = 'implemented' and implemented_at is not null
          and implemented_by_staff_id is not null
   from public.council_resolutions where resolution_reference = tams_test.ref('RES-', 2))
);

select tams_test.check(
  'RES 34 — withdrawing a resolution needs a reason',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_set_resolution_status(
      tams_test.resolution_id(tams_test.ref('RES-', 3)), 'withdrawn')
  $sql$) = 'TA100'
  and tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_set_resolution_status(
      tams_test.resolution_id(tams_test.ref('RES-', 3)), 'withdrawn', '  ')
  $sql$) = 'TA100'
  and tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_set_resolution_status(
      tams_test.resolution_id(tams_test.ref('RES-', 3)), 'withdrawn',
      'The contractor''s fees were settled outside the council')
  $sql$) = 'OK'
);

select tams_test.check(
  'RES 35 — the withdrawn resolution is kept, with its wording, its reason and who withdrew it',
  (select resolution_status = 'withdrawn'
          and withdrawal_reason = 'The contractor''s fees were settled outside the council'
          and withdrawn_at is not null and withdrawn_by_staff_id is not null
          and resolution_text like 'The council resolves to review the borehole contractor%'
   from public.council_resolutions where resolution_reference = tams_test.ref('RES-', 3))
);

select tams_test.check(
  'RES 35a — a withdrawn resolution stays withdrawn, and cannot be deleted',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_set_resolution_status(
      tams_test.resolution_id(tams_test.ref('RES-', 3)), 'implemented')
  $sql$) = 'TA097'
  and tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    delete from public.council_resolutions
  $sql$) = '42501'
);

-- A resolution on the meeting whose minutes are still a draft, so that
-- the "public but unconfirmed" case can be tested.
select tams_test.run_as('authenticated', tams_test.secretary(), $sql$
  select public.secretary_record_resolution(tams_test.meeting_id(tams_test.ref('MTG-', 4)),
    'The council resolves to renovate the community hall.', 'public')
$sql$);

select tams_test.check(
  'RES 36 — an internal resolution is invisible to a resident',
  tams_test.query_as('authenticated', tams_test.villager(), $sql$
    select count(*) from public.council_resolutions where visibility = 'internal'
  $sql$) = '0'
);

select tams_test.check(
  'RES 37 — a public resolution whose meeting''s minutes are still a draft is invisible',
  (select minutes_status = 'draft' from public.meeting_minutes mm
    join public.council_meetings m on m.id = mm.meeting_id
    where m.meeting_reference = tams_test.ref('MTG-', 4))
  and tams_test.query_as('authenticated', tams_test.villager(), $sql$
    select count(*) from public.council_resolutions
    where resolution_reference = tams_test.ref('RES-', 4)
  $sql$) = '0'
);

select tams_test.check(
  'RES 38 — a public resolution from a meeting with final minutes is visible',
  tams_test.query_as('authenticated', tams_test.villager(), $sql$
    select count(*) from public.council_resolutions
    where resolution_reference in (tams_test.ref('RES-', 1), tams_test.ref('RES-', 2))
  $sql$) = '2'
  and tams_test.query_as('authenticated', tams_test.villager(), $sql$
    select resolution_text from public.council_resolutions
    where resolution_reference = tams_test.ref('RES-', 1)
  $sql$) like 'The council resolves to repair the three dry boreholes%'
);

select tams_test.check(
  'RES 39 — taking a resolution back off the public record needs a reason',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_set_resolution_visibility(
      tams_test.resolution_id(tams_test.ref('RES-', 2)), 'internal')
  $sql$) = 'TA101'
  and tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_set_resolution_visibility(
      tams_test.resolution_id(tams_test.ref('RES-', 2)), 'internal', '   ')
  $sql$) = 'TA101'
  and tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_set_resolution_visibility(
      tams_test.resolution_id(tams_test.ref('RES-', 2)), 'internal',
      'The municipality asked that the request not be published while it is under consideration')
  $sql$) = 'OK'
);

select tams_test.check(
  'RES 39a — and the publication history records both the sending out and the taking back',
  (select count(*) = 2 from public.visibility_changes
    where resolution_id = tams_test.resolution_id(tams_test.ref('RES-', 2)))
  and (select reason = 'The municipality asked that the request not be published while it is under consideration'
              and from_visibility = 'public' and to_visibility = 'internal'
              and changed_by_staff_id is not null
       from public.visibility_changes
       where resolution_id = tams_test.resolution_id(tams_test.ref('RES-', 2))
         and to_visibility = 'internal')
);

select tams_test.check(
  'RES 39b — and the resident can no longer see it',
  tams_test.query_as('authenticated', tams_test.villager(), $sql$
    select count(*) from public.council_resolutions
    where resolution_reference = tams_test.ref('RES-', 2)
  $sql$) = '0'
);

select tams_test.check(
  'RES 39c — the history itself is the Secretary''s to read, nobody else''s',
  tams_test.query_as('authenticated', tams_test.villager(), $sql$
    select count(*) from public.visibility_changes
  $sql$) = '0'
  and tams_test.run_as('authenticated', tams_test.villager(), $sql$
    select count(*) from public.secretary_resolution_visibility_history(
      tams_test.resolution_id(tams_test.ref('RES-', 2)))
  $sql$) = '42501'
);


-- =====================================================================
-- PROJECTS
-- =====================================================================

select tams_test.check(
  'PRJ 40 — a project may be linked to a resolution',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_create_project('Borehole repairs',
      'Repair the three dry boreholes in Section A and Section C.',
      (current_date - 30)::date, (current_date + 60)::date,
      tams_test.resolution_id(tams_test.ref('RES-', 1)), 'public')
  $sql$) = 'OK'
);

select tams_test.check(
  'PRJ 40a — and the link, the visibility and the status are as recorded',
  (select resolution_id = tams_test.resolution_id(tams_test.ref('RES-', 1))
          and visibility = 'public' and project_status = 'planned'
   from public.community_projects where project_reference = tams_test.ref('PRJ-', 1))
);

select tams_test.check(
  'PRJ 41 — and a project may exist with no resolution behind it at all',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_create_project('Community hall painting',
      'Repaint the community hall inside and out.',
      (current_date - 10)::date, null, null, 'public')
  $sql$) = 'OK'
);

select tams_test.check(
  'PRJ 41a — and it is stored with no resolution and no target date',
  (select resolution_id is null and target_completion_date is null
   from public.community_projects where project_reference = tams_test.ref('PRJ-', 2))
);

select tams_test.check(
  'PRJ 42 — a target completion date before the start date is refused',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_create_project('Backwards', 'A project that finishes before it starts.',
      current_date, (current_date - 1)::date, null, 'internal')
  $sql$) = 'TA103'
  and tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_create_project('No start', 'No start date.', null, null, null, 'internal')
  $sql$) = 'TA103'
  and tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_create_project('   ', 'Blank name.', current_date, null, null, 'internal')
  $sql$) = 'TA102'
);

select tams_test.check(
  'PRJ 43 — cancelling a project needs a reason, and keeps it',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_create_project('Fencing the grazing camp',
      'Fence the camp on the eastern boundary.', (current_date - 5)::date, null, null, 'internal')
  $sql$) = 'OK'
  and tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_set_project_status(
      tams_test.project_id(tams_test.ref('PRJ-', 3)), 'cancelled')
  $sql$) = 'TA106'
  and tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_set_project_status(
      tams_test.project_id(tams_test.ref('PRJ-', 3)), 'cancelled',
      'The budget was not approved for this financial year')
  $sql$) = 'OK'
);

select tams_test.check(
  'PRJ 43a — the cancelled project is still there, with its reason',
  (select project_status = 'cancelled'
          and cancellation_reason = 'The budget was not approved for this financial year'
          and cancelled_at is not null and cancelled_by_staff_id is not null
   from public.community_projects where project_reference = tams_test.ref('PRJ-', 3))
);

select tams_test.check(
  'PRJ 44 — a completed project is kept, with the date it was completed',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_set_project_status(
      tams_test.project_id(tams_test.ref('PRJ-', 2)), 'active')
  $sql$) = 'OK'
  and tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_set_project_status(
      tams_test.project_id(tams_test.ref('PRJ-', 2)), 'completed')
  $sql$) = 'OK'
);

select tams_test.check(
  'PRJ 44a — and it cannot be reopened, edited or deleted afterwards',
  (select project_status = 'completed' and completed_on = current_date and completed_at is not null
   from public.community_projects where project_reference = tams_test.ref('PRJ-', 2))
  and tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_set_project_status(
      tams_test.project_id(tams_test.ref('PRJ-', 2)), 'active')
  $sql$) = 'TA105'
  and tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    delete from public.community_projects
  $sql$) = '42501'
);

select tams_test.check(
  'PRJ 45 — an internal project is invisible to a resident',
  tams_test.query_as('authenticated', tams_test.villager(), $sql$
    select count(*) from public.community_projects where visibility = 'internal'
  $sql$) = '0'
);

select tams_test.check(
  'PRJ 46 — a public project is visible to a resident, whatever its meeting''s minutes say',
  tams_test.query_as('authenticated', tams_test.villager(), $sql$
    select count(*) from public.community_projects
    where project_reference in (tams_test.ref('PRJ-', 1), tams_test.ref('PRJ-', 2))
  $sql$) = '2'
);

select tams_test.check(
  'PRJ 47 — taking a project back off the public record needs a reason and leaves a history',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_set_project_visibility(
      tams_test.project_id(tams_test.ref('PRJ-', 2)), 'internal')
  $sql$) = 'TA101'
  and tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_set_project_visibility(
      tams_test.project_id(tams_test.ref('PRJ-', 2)), 'internal',
      'Published in error before the council had confirmed the budget')
  $sql$) = 'OK'
);

select tams_test.check(
  'PRJ 47a — the history has both changes, and the resident can no longer see it',
  (select count(*) = 2 from public.visibility_changes
    where project_id = tams_test.project_id(tams_test.ref('PRJ-', 2)))
  and tams_test.query_as('authenticated', tams_test.villager(), $sql$
    select count(*) from public.community_projects
    where project_reference = tams_test.ref('PRJ-', 2)
  $sql$) = '0'
);

-- Put it back, so the resident tests have two public projects to read.
select tams_test.run_as('authenticated', tams_test.secretary(), $sql$
  select public.secretary_set_project_visibility(
    tams_test.project_id(tams_test.ref('PRJ-', 2)), 'public')
$sql$);

-- A public project whose resolution is internal: the leak test.
select tams_test.run_as('authenticated', tams_test.secretary(), $sql$
  select public.secretary_create_project('Contractor review follow-up',
    'Carry out what the council decided about the borehole contractor.',
    (current_date - 3)::date, null, tams_test.resolution_id(tams_test.ref('RES-', 3)), 'public')
$sql$);

select tams_test.check(
  'PRJ 48 — a public project linked to an internal resolution exposes none of that resolution',
  -- The project itself is readable…
  tams_test.query_as('authenticated', tams_test.villager(), $sql$
    select count(*) from public.community_projects
    where project_reference = tams_test.ref('PRJ-', 4)
  $sql$) = '1'
  -- …but the resolution it points at is not.
  and tams_test.query_as('authenticated', tams_test.villager(), $sql$
    select count(*) from public.council_resolutions
    where id = (select resolution_id from public.community_projects
                 where project_reference = tams_test.ref('PRJ-', 4))
  $sql$) = '0'
  -- …and Community Updates gives no reference for it either.
  and tams_test.query_as('authenticated', tams_test.villager(), $sql$
    select coalesce((
      select p ->> 'resolution_reference'
      from jsonb_array_elements(public.resident_community_updates() -> 'projects') as p
      where p ->> 'project_reference' = tams_test.ref('PRJ-', 4)), 'absent')
  $sql$) = 'absent'
);

select tams_test.check(
  'PRJ 48a — while a public project linked to a public, confirmed resolution does show its reference',
  tams_test.query_as('authenticated', tams_test.villager(), $sql$
    select p ->> 'resolution_reference'
    from jsonb_array_elements(public.resident_community_updates() -> 'projects') as p
    where p ->> 'project_reference' = tams_test.ref('PRJ-', 1)
  $sql$) = tams_test.ref('RES-', 1)
);


-- =====================================================================
-- MILESTONES
-- =====================================================================

select tams_test.check(
  'MS 49 — a project may have several milestones',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_add_milestone(tams_test.project_id(tams_test.ref('PRJ-', 1)),
      'Purchase materials', (current_date - 20)::date, 'Pipes, casing and a pump')
  $sql$) = 'OK'
  and tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_add_milestone(tams_test.project_id(tams_test.ref('PRJ-', 1)),
      'Borehole drilling', (current_date - 5)::date, null)
  $sql$) = 'OK'
  and tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_add_milestone(tams_test.project_id(tams_test.ref('PRJ-', 1)),
      'Install the pump', (current_date + 30)::date, null)
  $sql$) = 'OK'
);

select tams_test.check(
  'MS 49a — all three belong to that project',
  (select count(*) = 3 from public.project_milestones ms
    where ms.project_id = tams_test.project_id(tams_test.ref('PRJ-', 1)))
);

select tams_test.check(
  'MS 50 — a new milestone is pending, with no completion recorded',
  (select milestone_status = 'pending' and completed_at is null
   from public.project_milestones
   where id = tams_test.milestone_id(tams_test.ref('PRJ-', 1), 'Install the pump'))
);

select tams_test.check(
  'MS 51 — pending becomes in progress',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_set_milestone_status(
      tams_test.milestone_id(tams_test.ref('PRJ-', 1), 'Borehole drilling'), 'in_progress')
  $sql$) = 'OK'
);

select tams_test.check(
  'MS 51a — and it is stored in progress, with no completion',
  (select milestone_status = 'in_progress' and completed_at is null
   from public.project_milestones
   where id = tams_test.milestone_id(tams_test.ref('PRJ-', 1), 'Borehole drilling'))
);

select tams_test.check(
  'MS 52 — marking a milestone completed stores the moment it was completed',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_set_milestone_status(
      tams_test.milestone_id(tams_test.ref('PRJ-', 1), 'Purchase materials'), 'completed')
  $sql$) = 'OK'
);

select tams_test.check(
  'MS 52a — and completed_at, with who completed it, is on the record',
  (select milestone_status = 'completed' and completed_at is not null
          and completed_by_staff_id is not null
   from public.project_milestones
   where id = tams_test.milestone_id(tams_test.ref('PRJ-', 1), 'Purchase materials'))
);

select tams_test.check(
  'MS 53 — a milestone past its due date and not finished reads as overdue',
  -- 'Borehole drilling' was due five days ago and is only in progress.
  public.milestone_effective_status('in_progress', (current_date - 5)::date) = 'overdue'
  and (select public.milestone_effective_status(milestone_status, due_date) = 'overdue'
       from public.project_milestones
       where id = tams_test.milestone_id(tams_test.ref('PRJ-', 1), 'Borehole drilling'))
  -- while one that was completed before its due date passed is not overdue…
  and public.milestone_effective_status('completed', (current_date - 20)::date) = 'completed'
  -- …and one not yet due is simply pending.
  and public.milestone_effective_status('pending', (current_date + 30)::date) = 'pending'
);

select tams_test.check(
  'MS 54 — overdue is never stored, never chosen, and needs no scheduler',
  -- It cannot be set…
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_set_milestone_status(
      tams_test.milestone_id(tams_test.ref('PRJ-', 1), 'Install the pump'), 'overdue')
  $sql$) = 'TA109'
  -- …the table will not hold it…
  and tams_test.run_as('service_role', null, $sql$
    update public.project_milestones set milestone_status = 'overdue'
     where id = tams_test.milestone_id(tams_test.ref('PRJ-', 1), 'Install the pump')
  $sql$) = '23514'
  -- …and no row anywhere carries it.
  and (select count(*) = 0 from public.project_milestones where milestone_status = 'overdue')
  -- The answer is a pure function of the stored status and the date, so
  -- it is right the moment the date passes.
  and (select p.provolatile = 'i' from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'milestone_effective_status')
);

select tams_test.check(
  'MS 54a — the dashboard counts overdue milestones from the due date itself',
  tams_test.query_as('authenticated', tams_test.secretary(), $sql$
    select (public.secretary_dashboard() ->> 'overdue_milestones')::int
  $sql$) = '1'
);

select tams_test.check(
  'MS 25a — a milestone due before its project starts is refused, and a blank title too',
  tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_add_milestone(tams_test.project_id(tams_test.ref('PRJ-', 1)),
      'Time travel', (current_date - 400)::date, null)
  $sql$) = 'TA108'
  and tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_add_milestone(tams_test.project_id(tams_test.ref('PRJ-', 1)),
      '   ', (current_date + 5)::date, null)
  $sql$) = 'TA107'
);

select tams_test.check(
  'MS 55 — a resident sees milestones only for public projects',
  -- Milestones on a public project: visible.
  tams_test.query_as('authenticated', tams_test.villager(), $sql$
    select count(*) from public.project_milestones
    where project_id = tams_test.project_id(tams_test.ref('PRJ-', 1))
  $sql$) = '3'
  -- Milestones on an internal project: not.
  and tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_create_project('Internal audit preparation',
      'Prepare the council''s files for the annual audit.',
      (current_date - 2)::date, null, null, 'internal')
  $sql$) = 'OK'
  and tams_test.run_as('authenticated', tams_test.secretary(), $sql$
    select public.secretary_add_milestone(tams_test.project_id(tams_test.ref('PRJ-', 5)),
      'Collect the ledgers', (current_date + 10)::date, null)
  $sql$) = 'OK'
);

select tams_test.check(
  'MS 55a — and the internal project''s milestone is unreachable',
  tams_test.query_as('authenticated', tams_test.villager(), $sql$
    select count(*) from public.project_milestones
    where project_id = tams_test.project_id(tams_test.ref('PRJ-', 5))
  $sql$) = '0'
  and tams_test.query_as('authenticated', tams_test.villager(), $sql$
    select count(*) from public.project_milestones where title = 'Collect the ledgers'
  $sql$) = '0'
);

select tams_test.check(
  'MS 56 — a resident can change nothing about a milestone, a project or a resolution',
  tams_test.run_as('authenticated', tams_test.villager(), $sql$
    select public.secretary_set_milestone_status(
      tams_test.milestone_id(tams_test.ref('PRJ-', 1), 'Install the pump'), 'completed')
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.villager(), $sql$
    update public.project_milestones set milestone_status = 'completed'
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.villager(), $sql$
    update public.community_projects set visibility = 'public'
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.villager(), $sql$
    update public.council_resolutions set visibility = 'public'
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.villager(), $sql$
    delete from public.council_meetings
  $sql$) = '42501'
);


-- =====================================================================
-- RESIDENT COMMUNITY UPDATES
-- =====================================================================

select tams_test.check(
  'COM 57 — an active resident can read Community Updates',
  tams_test.run_as('authenticated', tams_test.villager(), $sql$
    select public.resident_community_updates()
  $sql$) = 'OK'
);

select tams_test.check(
  'COM 58 — a resident still waiting for verification cannot',
  tams_test.run_as('authenticated', tams_test.pending_resident(), $sql$
    select public.resident_community_updates()
  $sql$) = '42501'
  and tams_test.query_as('authenticated', tams_test.pending_resident(), $sql$
    select count(*) from public.council_resolutions
  $sql$) = '0'
  and tams_test.query_as('authenticated', tams_test.pending_resident(), $sql$
    select count(*) from public.community_projects
  $sql$) = '0'
);

select tams_test.check(
  'COM 59 — a resident whose verification was declined cannot',
  tams_test.run_as('authenticated', tams_test.declined_resident(), $sql$
    select public.resident_community_updates()
  $sql$) = '42501'
  and tams_test.query_as('authenticated', tams_test.declined_resident(), $sql$
    select count(*) from public.community_projects
  $sql$) = '0'
);

select tams_test.check(
  'COM 60 — a resolution reaches the resident with four fields and no others',
  tams_test.query_as('authenticated', tams_test.villager(), $sql$
    select (select array_agg(k order by k)
            from jsonb_object_keys(
              (select r from jsonb_array_elements(
                 public.resident_community_updates() -> 'resolutions') as r
                where r ->> 'resolution_reference' = tams_test.ref('RES-', 1))) as k)::text
  $sql$) = '{decision_date,resolution_reference,resolution_status,resolution_text}'
);

select tams_test.check(
  'COM 61 — a project reaches the resident with the agreed fields and no others',
  tams_test.query_as('authenticated', tams_test.villager(), $sql$
    select (select array_agg(k order by k)
            from jsonb_object_keys(
              (select p from jsonb_array_elements(
                 public.resident_community_updates() -> 'projects') as p
                where p ->> 'project_reference' = tams_test.ref('PRJ-', 1))) as k)::text
  $sql$) = '{description,milestones,project_name,project_reference,project_status,resolution_reference,start_date,target_completion_date}'
);

select tams_test.check(
  'COM 61a — and a milestone carries its title, note, due date and effective status only',
  tams_test.query_as('authenticated', tams_test.villager(), $sql$
    select (select array_agg(k order by k)
            from jsonb_object_keys(
              (select ms from jsonb_array_elements(
                 (select p -> 'milestones' from jsonb_array_elements(
                    public.resident_community_updates() -> 'projects') as p
                   where p ->> 'project_reference' = tams_test.ref('PRJ-', 1))) as ms
                where ms ->> 'title' = 'Borehole drilling')) as k)::text
  $sql$) = '{description,due_date,effective_status,title}'
);

select tams_test.check(
  'COM 61b — and the resident sees the drilling as overdue, worked out just now',
  tams_test.query_as('authenticated', tams_test.villager(), $sql$
    select ms ->> 'effective_status'
    from jsonb_array_elements(
      (select p -> 'milestones' from jsonb_array_elements(
         public.resident_community_updates() -> 'projects') as p
        where p ->> 'project_reference' = tams_test.ref('PRJ-', 1))) as ms
    where ms ->> 'title' = 'Borehole drilling'
  $sql$) = 'overdue'
);

select tams_test.check(
  'COM 62 — Community Updates says nothing about who attended anything',
  tams_test.query_as('authenticated', tams_test.villager(), $sql$
    select public.resident_community_updates()::text ilike '%Hosi Mhinga%'
  $sql$) = 'false'
  and tams_test.query_as('authenticated', tams_test.villager(), $sql$
    select public.resident_community_updates()::text ilike '%Headman%'
  $sql$) = 'false'
);

select tams_test.check(
  'COM 63 — no draft minutes reach the resident, by any route',
  tams_test.query_as('authenticated', tams_test.villager(), $sql$
    select count(*) from public.meeting_minutes where minutes_status = 'draft'
  $sql$) = '0'
  and tams_test.query_as('authenticated', tams_test.villager(), $sql$
    select public.resident_community_updates()::text ilike '%considered the community projects%'
  $sql$) = 'false'
);

select tams_test.check(
  'COM 64 — nor do final minutes: residents do not read minutes at all yet',
  tams_test.query_as('authenticated', tams_test.villager(), $sql$
    select count(*) from public.meeting_minutes
  $sql$) = '0'
  and tams_test.query_as('authenticated', tams_test.villager(), $sql$
    select count(*) from public.meeting_minutes_amendments
  $sql$) = '0'
  and tams_test.query_as('authenticated', tams_test.villager(), $sql$
    select public.resident_community_updates()::text ilike '%boreholes were reported dry%'
  $sql$) = 'false'
);

select tams_test.check(
  'COM 65 — no internal resolution reaches the resident',
  tams_test.query_as('authenticated', tams_test.villager(), $sql$
    select public.resident_community_updates()::text ilike '%contractor%fees%'
  $sql$) = 'false'
  and tams_test.query_as('authenticated', tams_test.villager(), $sql$
    select count(*) from jsonb_array_elements(
      public.resident_community_updates() -> 'resolutions') as r
    where r ->> 'resolution_reference' in (tams_test.ref('RES-', 2), tams_test.ref('RES-', 3),
                                           tams_test.ref('RES-', 4))
  $sql$) = '0'
);

select tams_test.check(
  'COM 66 — no internal project reaches the resident',
  tams_test.query_as('authenticated', tams_test.villager(), $sql$
    select count(*) from jsonb_array_elements(
      public.resident_community_updates() -> 'projects') as p
    where p ->> 'project_reference' in (tams_test.ref('PRJ-', 3), tams_test.ref('PRJ-', 5))
  $sql$) = '0'
  and tams_test.query_as('authenticated', tams_test.villager(), $sql$
    select public.resident_community_updates()::text ilike '%audit%'
  $sql$) = 'false'
  -- and the reason a cancelled internal project was cancelled stays internal
  and tams_test.query_as('authenticated', tams_test.villager(), $sql$
    select public.resident_community_updates()::text ilike '%budget was not approved%'
  $sql$) = 'false'
);

select tams_test.check(
  'COM 67 — going straight to the tables gives a resident exactly the same narrow answer',
  tams_test.query_as('authenticated', tams_test.villager(), $sql$
    select count(*) from public.council_meetings
  $sql$) = '0'
  and tams_test.query_as('authenticated', tams_test.villager(), $sql$
    select count(*) from public.meeting_attendance
  $sql$) = '0'
  and tams_test.query_as('authenticated', tams_test.villager(), $sql$
    select count(*) from public.visibility_changes
  $sql$) = '0'
  and tams_test.query_as('authenticated', tams_test.villager(), $sql$
    select count(*) from public.council_resolutions
  $sql$) = '1'      -- RES-0001 only: public, from a meeting whose minutes are final
  and tams_test.query_as('authenticated', tams_test.villager(), $sql$
    select count(*) from public.community_projects
  $sql$) = '3'      -- PRJ-0001, PRJ-0002 and PRJ-0004: the public ones
);

select tams_test.check(
  'COM 67a — and the Secretary''s own read functions are closed to them',
  tams_test.run_as('authenticated', tams_test.villager(), $sql$
    select public.secretary_dashboard()
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.villager(), $sql$
    select public.secretary_meeting(tams_test.meeting_id(tams_test.ref('MTG-', 3)))
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.villager(), $sql$
    select count(*) from public.secretary_meetings(null, null, null, null)
  $sql$) = '42501'
  and tams_test.run_as('authenticated', tams_test.villager(), $sql$
    select count(*) from public.secretary_projects(null, null, null)
  $sql$) = '42501'
);

select tams_test.check(
  'COM 57a — the Secretary''s own dashboard and lists answer properly',
  tams_test.query_as('authenticated', tams_test.secretary(), $sql$
    select (public.secretary_dashboard() ->> 'upcoming_meetings')::int
  $sql$) = '1'
  and tams_test.query_as('authenticated', tams_test.secretary(), $sql$
    select (public.secretary_dashboard() ->> 'meetings_awaiting_minutes')::int
  $sql$) = '1'      -- MTG-0004 was held and its minutes are still a draft
  and tams_test.query_as('authenticated', tams_test.secretary(), $sql$
    select (public.secretary_dashboard() ->> 'draft_minutes')::int
  $sql$) = '1'
  and tams_test.query_as('authenticated', tams_test.secretary(), $sql$
    select count(*) from public.secretary_meetings(null, null, null, null)
  $sql$) = '4'
  and tams_test.query_as('authenticated', tams_test.secretary(), $sql$
    select jsonb_array_length(
      public.secretary_meeting(tams_test.meeting_id(tams_test.ref('MTG-', 3))) -> 'resolutions')
  $sql$) = '3'
);


-- =====================================================================
-- REGRESSION — everything that worked before still works
-- =====================================================================

select tams_test.check(
  'REG 68 — Registry Clerk functions still work',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_search_residents('Ndlovu')
  $sql$) = 'OK'
  and tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select public.registry_create_resident('SYN0000000900', 'Council', 'Era',
      '1990-01-01', 'Female', 'active')
  $sql$) = 'OK'
);

select tams_test.check(
  'REG 68a — and the new resident is on the register',
  (select count(*) = 1 from public.residents where id_number = 'SYN0000000900')
);

select tams_test.check(
  'REG 69 — resident verification still works end to end',
  tams_test.run_as('authenticated', tams_test.clerk(), $sql$
    select count(*) from public.registry_pending_resident_requests()
  $sql$) = 'OK'
  and (select count(*) > 0 from public.resident_account_requests)
);

select tams_test.check(
  'REG 70 — Land Officer functions still work',
  tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_dashboard()
  $sql$) = 'OK'
  and tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select count(*) from public.land_officer_sites(null, null)
  $sql$) = 'OK'
  and tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select count(*) from public.land_officer_allocations('active', null, null)
  $sql$) = 'OK'
);

select tams_test.check(
  'REG 71 — land applications still work',
  tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_register_site('BUS-9501', 'business',
      '1 Council Street', '9501', 'Section A', 'Mhinga Village')
  $sql$) = 'OK'
  and tams_test.run_as('authenticated', tams_test.resident_uid('SYN0000000028'), $sql$
    select public.resident_submit_land_application('business',
      jsonb_build_object('reason_for_application', 'To open a shop',
                         'business_type', 'shop', 'business_name', 'Council Era Trading'))
  $sql$) = 'OK'
  and tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_approve_application(tams_test.latest_application('SYN0000000028'))
  $sql$) = 'OK'
);

select tams_test.check(
  'REG 72 — allocation and PTO issuance still work',
  tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_allocate_site(tams_test.latest_application('SYN0000000028'),
      tams_test.site_id_of('BUS-9501'))
  $sql$) = 'OK'
  and tams_test.run_as('authenticated', tams_test.officer(), $sql$
    select public.land_officer_issue_pto(tams_test.allocation_for_site('BUS-9501'))
  $sql$) = 'OK'
);

select tams_test.check(
  'REG 72b — and a business permission still runs for exactly two years',
  (select count(*) = 1 from public.ptos p
    join public.land_allocations a on a.id = p.land_allocation_id
    join public.land_sites s on s.id = a.land_site_id
    where s.site_code = 'BUS-9501' and p.pto_status = 'active'
      and p.expiry_date = (current_date + make_interval(years => 2))::date)
);

select tams_test.check(
  'REG 72a — and verifying a permission from its token still works, for anybody',
  tams_test.query_as('anon', null, $sql$
    select (public.verify_pto(tams_test.token_for_site('BUS-9501')) ->> 'found')
  $sql$) = 'true'
);

select tams_test.check(
  'REG 73 — Council Administrator staff management still works',
  tams_test.run_as('authenticated', tams_test.administrator(), $sql$
    select public.deactivate_staff_account(tams_test.staff_id_of('2026075'),
      'No longer employed by the traditional authority')
  $sql$) = 'OK'
  and tams_test.run_as('authenticated', tams_test.administrator(), $sql$
    select public.reactivate_staff_account(tams_test.staff_id_of('2026075'), 'Returned to the post')
  $sql$) = 'OK'
  and tams_test.run_as('authenticated', tams_test.administrator(), $sql$
    select public.change_staff_role(tams_test.staff_id_of('2026075'),
      tams_test.role_id_of('Council Secretary'))
  $sql$) = 'OK'
);

select tams_test.check(
  'REG 73a — and the staff record shows the new role and an active account',
  tams_test.role_of('2026075') = 'Council Secretary'
  and tams_test.status_of('2026075') = 'active'
);

select tams_test.check(
  'REG 74 — the imported village register is untouched by any of this',
  (select count(*) = 20 from tams_test.imported_allocations)
  and (select count(*) = 20
       from public.land_allocations a join tams_test.imported_allocations i on i.id = a.id
       where a.allocation_reference = i.allocation_reference
         and a.land_site_id = i.land_site_id
         and a.resident_id = i.resident_id
         and a.allocation_status = 'active')
  and (select count(*) = 20
       from public.land_sites s join tams_test.imported_sites i on i.id = s.id
       where s.site_code = i.site_code and s.site_type = i.site_type
         and s.street_address = i.street_address)
  and (select count(*) = 200 from tams_test.imported_relationships)
  and (select count(*) = 200
       from public.family_relationships f join tams_test.imported_relationships i on i.id = f.id
       where f.relationship_status = 'active')
);
