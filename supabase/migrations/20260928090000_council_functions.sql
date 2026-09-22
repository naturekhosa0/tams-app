-- =====================================================================
-- TAMS — Council Secretary functions
--
-- Every privileged operation establishes its caller from auth.uid() and
-- rechecks the rules for itself. Nothing is trusted from the browser:
-- not the role, not a staff id, not a decision date.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Who is a Council Secretary
--
--    The same walk as the Registry Clerk's and the Land Officer's:
--    auth.uid() -> user_accounts (staff, active) -> staff -> the role
--    that account holds *now*. An account deactivated a second ago
--    fails here, and the Council Administrator does not pass merely by
--    being the administrator.
-- ---------------------------------------------------------------------

create or replace function public.is_active_council_secretary()
returns boolean
language sql stable security definer set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.user_accounts ua
    join public.staff s on s.id = ua.staff_id
    join public.roles r on r.id = s.role_id
    where ua.auth_user_id = auth.uid()
      and ua.account_type = 'staff'
      and ua.account_status = 'active'
      and r.role_name = 'Council Secretary');
$$;

create or replace function public.acting_council_secretary_staff_id()
returns uuid
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_staff_id uuid;
begin
  select s.id into v_staff_id
  from public.user_accounts ua
  join public.staff s on s.id = ua.staff_id
  join public.roles r on r.id = s.role_id
  where ua.auth_user_id = auth.uid()
    and ua.account_type = 'staff'
    and ua.account_status = 'active'
    and r.role_name = 'Council Secretary';

  if v_staff_id is null then
    raise exception 'Only an active Council Secretary may do that.' using errcode = '42501';
  end if;
  return v_staff_id;
end;
$$;

-- ---------------------------------------------------------------------
-- 2. Small shared helpers
-- ---------------------------------------------------------------------

-- A reference that carries the year it belongs to: MTG-2026-0001.
create or replace function public.council_reference(p_prefix text, p_column text, p_table text)
returns text
language sql volatile security definer set search_path = public, pg_temp
as $$
  select public.next_reference(
    p_prefix || to_char(current_date, 'YYYY') || '-', p_column, p_table, 4);
$$;

-- "Overdue" is never stored. It is this, worked out whenever anybody
-- looks, so it is right the moment the due date passes and needs no
-- scheduler to make it so.
create or replace function public.milestone_effective_status(p_status text, p_due_date date)
returns text
language sql immutable
as $$
  select case
    when p_status = 'completed' then 'completed'
    when p_due_date < current_date then 'overdue'
    else p_status
  end;
$$;

-- Are a meeting's minutes finalised? Asked from Row Level Security, so
-- it has to be able to read meeting_minutes as the definer: a resident
-- has no read policy on that table at all, and never will.
create or replace function public.meeting_minutes_are_final(p_meeting_id uuid)
returns boolean
language sql stable security definer set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.meeting_minutes m
    where m.meeting_id = p_meeting_id and m.minutes_status = 'final');
$$;

-- May a resident see this resolution at all? Public *and* confirmed:
-- a resolution from a meeting whose minutes are still a draft is not
-- yet part of the record.
create or replace function public.resolution_is_public(p_resolution_id uuid)
returns boolean
language sql stable security definer set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.council_resolutions r
    where r.id = p_resolution_id
      and r.visibility = 'public'
      and public.meeting_minutes_are_final(r.meeting_id));
$$;

create or replace function public.project_is_public(p_project_id uuid)
returns boolean
language sql stable security definer set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.community_projects p
    where p.id = p_project_id and p.visibility = 'public');
$$;

-- ---------------------------------------------------------------------
-- 3. Row Level Security policies
--
--     The Secretary reads their own records. A resident reads nothing
--     but public resolutions from confirmed meetings, public projects,
--     and the milestones of those projects. Meetings, attendance,
--     minutes, amendments and the visibility history are unreachable
--     to everybody else — not hidden by the browser, unreachable.
-- ---------------------------------------------------------------------

drop policy if exists council_meetings_readable on public.council_meetings;
create policy council_meetings_readable
  on public.council_meetings for select to authenticated
  using (public.is_active_council_secretary());

drop policy if exists meeting_attendance_readable on public.meeting_attendance;
create policy meeting_attendance_readable
  on public.meeting_attendance for select to authenticated
  using (public.is_active_council_secretary());

drop policy if exists meeting_minutes_readable on public.meeting_minutes;
create policy meeting_minutes_readable
  on public.meeting_minutes for select to authenticated
  using (public.is_active_council_secretary());

drop policy if exists minutes_amendments_readable on public.meeting_minutes_amendments;
create policy minutes_amendments_readable
  on public.meeting_minutes_amendments for select to authenticated
  using (public.is_active_council_secretary());

drop policy if exists visibility_changes_readable on public.visibility_changes;
create policy visibility_changes_readable
  on public.visibility_changes for select to authenticated
  using (public.is_active_council_secretary());

drop policy if exists council_resolutions_readable on public.council_resolutions;
create policy council_resolutions_readable
  on public.council_resolutions for select to authenticated
  using (
    public.is_active_council_secretary()
    or (visibility = 'public'
        and public.meeting_minutes_are_final(meeting_id)
        and public.current_resident_id() is not null)
  );

drop policy if exists community_projects_readable on public.community_projects;
create policy community_projects_readable
  on public.community_projects for select to authenticated
  using (
    public.is_active_council_secretary()
    or (visibility = 'public' and public.current_resident_id() is not null)
  );

drop policy if exists project_milestones_readable on public.project_milestones;
create policy project_milestones_readable
  on public.project_milestones for select to authenticated
  using (
    public.is_active_council_secretary()
    or (public.project_is_public(project_id) and public.current_resident_id() is not null)
  );

-- ---------------------------------------------------------------------
-- 4. Scheduling a meeting
-- ---------------------------------------------------------------------

create or replace function public.secretary_schedule_meeting(
  p_title        text,
  p_meeting_type text,
  p_meeting_date date,
  p_start_time   time,
  p_venue        text,
  p_agenda       text
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id uuid := public.acting_council_secretary_staff_id();
  v_meeting  public.council_meetings;
begin
  if btrim(coalesce(p_title, '')) = '' or btrim(coalesce(p_venue, '')) = ''
     or btrim(coalesce(p_agenda, '')) = '' then
    raise exception 'A title, a venue and an agenda are all required.' using errcode = 'TA081';
  end if;
  if p_meeting_type is null or p_meeting_type not in ('ordinary', 'special', 'emergency') then
    raise exception '% is not a kind of meeting. It is ordinary, special or emergency.',
      coalesce(p_meeting_type, '(none)') using errcode = 'TA082';
  end if;
  if p_meeting_date is null or p_start_time is null then
    raise exception 'A meeting needs a date and a starting time.' using errcode = 'TA083';
  end if;
  -- A date nobody could have meant: mistyped years are the usual cause.
  if p_meeting_date < current_date - make_interval(years => 10)
     or p_meeting_date > current_date + make_interval(years => 2) then
    raise exception 'A meeting date of % is not a date anybody meant.', p_meeting_date
      using errcode = 'TA083';
  end if;

  insert into public.council_meetings (
    meeting_reference, title, meeting_type, meeting_date, start_time, venue, agenda,
    meeting_status, created_by_staff_id)
  values (
    public.council_reference('MTG-', 'meeting_reference', 'council_meetings'),
    btrim(p_title), p_meeting_type, p_meeting_date, p_start_time,
    btrim(p_venue), btrim(p_agenda), 'scheduled', v_staff_id)
  returning * into v_meeting;

  return jsonb_build_object(
    'meeting_id', v_meeting.id,
    'meeting_reference', v_meeting.meeting_reference,
    'meeting_status', v_meeting.meeting_status);
end;
$$;

-- Editing what a meeting says. A meeting that has already been held or
-- cancelled is history: its date, time, type and agenda are what they
-- were, and this refuses to rewrite them.
create or replace function public.secretary_update_meeting(
  p_meeting_id   uuid,
  p_title        text,
  p_meeting_type text,
  p_meeting_date date,
  p_start_time   time,
  p_venue        text,
  p_agenda       text
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_meeting public.council_meetings;
begin
  perform public.acting_council_secretary_staff_id();

  select * into v_meeting from public.council_meetings where id = p_meeting_id for update;
  if not found then
    raise exception 'That meeting could not be found.' using errcode = 'TA084';
  end if;
  if v_meeting.meeting_status <> 'scheduled' then
    raise exception 'Meeting % has been recorded as %, so its details are part of the official record and cannot be edited. Record a correction in the minutes instead.',
      v_meeting.meeting_reference, v_meeting.meeting_status using errcode = 'TA085';
  end if;
  if btrim(coalesce(p_title, '')) = '' or btrim(coalesce(p_venue, '')) = ''
     or btrim(coalesce(p_agenda, '')) = '' then
    raise exception 'A title, a venue and an agenda are all required.' using errcode = 'TA081';
  end if;
  if p_meeting_type is null or p_meeting_type not in ('ordinary', 'special', 'emergency') then
    raise exception '% is not a kind of meeting. It is ordinary, special or emergency.',
      coalesce(p_meeting_type, '(none)') using errcode = 'TA082';
  end if;
  if p_meeting_date is null or p_start_time is null then
    raise exception 'A meeting needs a date and a starting time.' using errcode = 'TA083';
  end if;
  if p_meeting_date < current_date - make_interval(years => 10)
     or p_meeting_date > current_date + make_interval(years => 2) then
    raise exception 'A meeting date of % is not a date anybody meant.', p_meeting_date
      using errcode = 'TA083';
  end if;

  update public.council_meetings
     set title = btrim(p_title), meeting_type = p_meeting_type,
         meeting_date = p_meeting_date, start_time = p_start_time,
         venue = btrim(p_venue), agenda = btrim(p_agenda)
   where id = v_meeting.id
  returning * into v_meeting;

  return jsonb_build_object(
    'meeting_id', v_meeting.id, 'meeting_reference', v_meeting.meeting_reference);
end;
$$;

-- The only two moves a meeting can make, and both are one-way.
create or replace function public.secretary_set_meeting_status(
  p_meeting_id uuid,
  p_status     text,
  p_reason     text default null
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id uuid := public.acting_council_secretary_staff_id();
  v_meeting  public.council_meetings;
begin
  select * into v_meeting from public.council_meetings where id = p_meeting_id for update;
  if not found then
    raise exception 'That meeting could not be found.' using errcode = 'TA084';
  end if;
  if p_status is null or p_status not in ('scheduled', 'held', 'cancelled') then
    raise exception 'A meeting is scheduled, held or cancelled.' using errcode = 'TA086';
  end if;
  if v_meeting.meeting_status <> 'scheduled' then
    raise exception 'Meeting % is already %, and that cannot be undone.',
      v_meeting.meeting_reference, v_meeting.meeting_status using errcode = 'TA086';
  end if;
  if p_status = 'scheduled' then
    raise exception 'Meeting % is already scheduled.', v_meeting.meeting_reference
      using errcode = 'TA086';
  end if;

  if p_status = 'held' then
    update public.council_meetings
       set meeting_status = 'held', held_recorded_at = now(), held_recorded_by_staff_id = v_staff_id
     where id = v_meeting.id
    returning * into v_meeting;
  else
    if btrim(coalesce(p_reason, '')) = '' then
      raise exception 'A reason is required to cancel a meeting.' using errcode = 'TA087';
    end if;
    update public.council_meetings
       set meeting_status = 'cancelled', cancellation_reason = btrim(p_reason),
           cancelled_at = now(), cancelled_by_staff_id = v_staff_id
     where id = v_meeting.id
    returning * into v_meeting;
  end if;

  return jsonb_build_object(
    'meeting_id', v_meeting.id,
    'meeting_reference', v_meeting.meeting_reference,
    'meeting_status', v_meeting.meeting_status);
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Attendance
-- ---------------------------------------------------------------------

create or replace function public.secretary_add_attendee(
  p_meeting_id       uuid,
  p_attendee_name    text,
  p_role_or_capacity text,
  p_attendance_status text default 'present'
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id   uuid := public.acting_council_secretary_staff_id();
  v_meeting    public.council_meetings;
  v_attendance public.meeting_attendance;
begin
  select * into v_meeting from public.council_meetings where id = p_meeting_id;
  if not found then
    raise exception 'That meeting could not be found.' using errcode = 'TA084';
  end if;
  if btrim(coalesce(p_attendee_name, '')) = '' or btrim(coalesce(p_role_or_capacity, '')) = '' then
    raise exception 'An attendee needs a name and the capacity they attended in.'
      using errcode = 'TA088';
  end if;
  if p_attendance_status is null or p_attendance_status not in ('present', 'absent', 'apology') then
    raise exception 'Attendance is recorded as present, absent or apology.' using errcode = 'TA089';
  end if;
  -- Once the minutes are final the attendance list is part of them.
  if public.meeting_minutes_are_final(v_meeting.id) then
    raise exception 'The minutes of % are final, so its attendance list is closed.',
      v_meeting.meeting_reference using errcode = 'TA090';
  end if;

  insert into public.meeting_attendance (
    meeting_id, attendee_name, role_or_capacity, attendance_status, recorded_by_staff_id)
  values (v_meeting.id, btrim(p_attendee_name), btrim(p_role_or_capacity),
          p_attendance_status, v_staff_id)
  returning * into v_attendance;

  return jsonb_build_object(
    'attendance_id', v_attendance.id, 'attendee_name', v_attendance.attendee_name);
end;
$$;

create or replace function public.secretary_update_attendee(
  p_attendance_id     uuid,
  p_attendee_name     text,
  p_role_or_capacity  text,
  p_attendance_status text
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare v_attendance public.meeting_attendance;
begin
  perform public.acting_council_secretary_staff_id();

  select * into v_attendance from public.meeting_attendance where id = p_attendance_id for update;
  if not found then
    raise exception 'That attendance record could not be found.' using errcode = 'TA091';
  end if;
  if public.meeting_minutes_are_final(v_attendance.meeting_id) then
    raise exception 'The minutes for that meeting are final, so its attendance list is closed.'
      using errcode = 'TA090';
  end if;
  if btrim(coalesce(p_attendee_name, '')) = '' or btrim(coalesce(p_role_or_capacity, '')) = '' then
    raise exception 'An attendee needs a name and the capacity they attended in.'
      using errcode = 'TA088';
  end if;
  if p_attendance_status is null or p_attendance_status not in ('present', 'absent', 'apology') then
    raise exception 'Attendance is recorded as present, absent or apology.' using errcode = 'TA089';
  end if;

  update public.meeting_attendance
     set attendee_name = btrim(p_attendee_name),
         role_or_capacity = btrim(p_role_or_capacity),
         attendance_status = p_attendance_status
   where id = v_attendance.id
  returning * into v_attendance;

  return jsonb_build_object(
    'attendance_id', v_attendance.id, 'attendee_name', v_attendance.attendee_name);
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Minutes
-- ---------------------------------------------------------------------

-- Saving a draft. The first save creates the one minutes record the
-- meeting is allowed; later saves replace the draft. Once the minutes
-- are final this refuses, and there is no other way in.
create or replace function public.secretary_save_minutes(
  p_meeting_id uuid,
  p_content    text
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id uuid := public.acting_council_secretary_staff_id();
  v_meeting  public.council_meetings;
  v_minutes  public.meeting_minutes;
begin
  select * into v_meeting from public.council_meetings where id = p_meeting_id;
  if not found then
    raise exception 'That meeting could not be found.' using errcode = 'TA084';
  end if;
  if v_meeting.meeting_status = 'cancelled' then
    raise exception 'Meeting % was cancelled, so it has no minutes.', v_meeting.meeting_reference
      using errcode = 'TA092';
  end if;

  select * into v_minutes from public.meeting_minutes where meeting_id = v_meeting.id for update;

  if found then
    if v_minutes.minutes_status = 'final' then
      raise exception 'The minutes of % are final and cannot be edited. Record an amendment instead.',
        v_meeting.meeting_reference using errcode = 'TA093';
    end if;
    update public.meeting_minutes set minutes_content = coalesce(p_content, '')
     where id = v_minutes.id
    returning * into v_minutes;
  else
    insert into public.meeting_minutes (meeting_id, minutes_content, minutes_status, created_by_staff_id)
    values (v_meeting.id, coalesce(p_content, ''), 'draft', v_staff_id)
    returning * into v_minutes;
  end if;

  return jsonb_build_object(
    'minutes_id', v_minutes.id, 'minutes_status', v_minutes.minutes_status);
end;
$$;

create or replace function public.secretary_finalize_minutes(p_meeting_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id uuid := public.acting_council_secretary_staff_id();
  v_meeting  public.council_meetings;
  v_minutes  public.meeting_minutes;
begin
  select * into v_meeting from public.council_meetings where id = p_meeting_id;
  if not found then
    raise exception 'That meeting could not be found.' using errcode = 'TA084';
  end if;
  if v_meeting.meeting_status <> 'held' then
    raise exception 'Meeting % is recorded as %. Only a meeting that was held has minutes to finalise.',
      v_meeting.meeting_reference, v_meeting.meeting_status using errcode = 'TA092';
  end if;

  select * into v_minutes from public.meeting_minutes where meeting_id = v_meeting.id for update;
  if not found then
    raise exception 'There are no minutes for % to finalise yet.', v_meeting.meeting_reference
      using errcode = 'TA094';
  end if;
  if v_minutes.minutes_status = 'final' then
    raise exception 'The minutes of % are already final.', v_meeting.meeting_reference
      using errcode = 'TA093';
  end if;
  if btrim(coalesce(v_minutes.minutes_content, '')) = '' then
    raise exception 'Empty minutes cannot be finalised.' using errcode = 'TA094';
  end if;

  update public.meeting_minutes
     set minutes_status = 'final', finalized_at = now(), finalized_by_staff_id = v_staff_id
   where id = v_minutes.id
  returning * into v_minutes;

  return jsonb_build_object(
    'minutes_id', v_minutes.id,
    'minutes_status', v_minutes.minutes_status,
    'finalized_at', v_minutes.finalized_at);
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Amendments — the only way a finalised minute is ever corrected
-- ---------------------------------------------------------------------

create or replace function public.secretary_add_amendment(
  p_minutes_id     uuid,
  p_amendment_text text,
  p_reason         text
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id  uuid := public.acting_council_secretary_staff_id();
  v_minutes   public.meeting_minutes;
  v_amendment public.meeting_minutes_amendments;
begin
  select * into v_minutes from public.meeting_minutes where id = p_minutes_id;
  if not found then
    raise exception 'Those minutes could not be found.' using errcode = 'TA094';
  end if;
  if v_minutes.minutes_status <> 'final' then
    raise exception 'Only final minutes are amended. A draft is simply edited.'
      using errcode = 'TA095';
  end if;
  if btrim(coalesce(p_amendment_text, '')) = '' then
    raise exception 'An amendment needs the correction itself.' using errcode = 'TA096';
  end if;
  if btrim(coalesce(p_reason, '')) = '' then
    raise exception 'An amendment needs a reason.' using errcode = 'TA096';
  end if;

  insert into public.meeting_minutes_amendments (
    minutes_id, amendment_reference, amendment_text, reason, created_by_staff_id)
  values (
    v_minutes.id,
    public.council_reference('AMD-', 'amendment_reference', 'meeting_minutes_amendments'),
    btrim(p_amendment_text), btrim(p_reason), v_staff_id)
  returning * into v_amendment;

  return jsonb_build_object(
    'amendment_id', v_amendment.id,
    'amendment_reference', v_amendment.amendment_reference);
end;
$$;

-- ---------------------------------------------------------------------
-- 8. Resolutions
--
--    The decision date is the meeting's date. It is not a parameter,
--    so no browser can claim a different one.
-- ---------------------------------------------------------------------

create or replace function public.secretary_record_resolution(
  p_meeting_id      uuid,
  p_resolution_text text,
  p_visibility      text default 'internal'
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id   uuid := public.acting_council_secretary_staff_id();
  v_meeting    public.council_meetings;
  v_resolution public.council_resolutions;
begin
  select * into v_meeting from public.council_meetings where id = p_meeting_id;
  if not found then
    raise exception 'That meeting could not be found.' using errcode = 'TA084';
  end if;
  if v_meeting.meeting_status = 'cancelled' then
    raise exception 'Meeting % was cancelled, so it decided nothing.', v_meeting.meeting_reference
      using errcode = 'TA097';
  end if;
  if btrim(coalesce(p_resolution_text, '')) = '' then
    raise exception 'A resolution needs its wording.' using errcode = 'TA097';
  end if;
  if p_visibility is null or p_visibility not in ('internal', 'public') then
    raise exception 'A resolution is internal or public.' using errcode = 'TA098';
  end if;

  insert into public.council_resolutions (
    resolution_reference, meeting_id, resolution_text, decision_date,
    resolution_status, visibility, created_by_staff_id)
  values (
    public.council_reference('RES-', 'resolution_reference', 'council_resolutions'),
    v_meeting.id, btrim(p_resolution_text), v_meeting.meeting_date,
    'active', p_visibility, v_staff_id)
  returning * into v_resolution;

  -- A resolution recorded as public from the start is still a
  -- publication, and the record says so.
  if p_visibility = 'public' then
    insert into public.visibility_changes (
      subject_type, resolution_id, from_visibility, to_visibility, reason, changed_by_staff_id)
    values ('resolution', v_resolution.id, 'internal', 'public',
            'Recorded as public when the resolution was captured', v_staff_id);
  end if;

  return jsonb_build_object(
    'resolution_id', v_resolution.id,
    'resolution_reference', v_resolution.resolution_reference,
    'decision_date', v_resolution.decision_date);
end;
$$;

create or replace function public.secretary_update_resolution(
  p_resolution_id   uuid,
  p_resolution_text text
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare v_resolution public.council_resolutions;
begin
  perform public.acting_council_secretary_staff_id();

  select * into v_resolution from public.council_resolutions where id = p_resolution_id for update;
  if not found then
    raise exception 'That resolution could not be found.' using errcode = 'TA099';
  end if;
  if v_resolution.resolution_status <> 'active' then
    raise exception 'Resolution % is %, so its wording is part of the record.',
      v_resolution.resolution_reference, v_resolution.resolution_status using errcode = 'TA097';
  end if;
  if public.meeting_minutes_are_final(v_resolution.meeting_id) then
    raise exception 'The minutes of that meeting are final, so resolution % cannot be reworded. Record an amendment to the minutes instead.',
      v_resolution.resolution_reference using errcode = 'TA093';
  end if;
  if btrim(coalesce(p_resolution_text, '')) = '' then
    raise exception 'A resolution needs its wording.' using errcode = 'TA097';
  end if;

  update public.council_resolutions set resolution_text = btrim(p_resolution_text)
   where id = v_resolution.id
  returning * into v_resolution;

  return jsonb_build_object(
    'resolution_id', v_resolution.id,
    'resolution_reference', v_resolution.resolution_reference);
end;
$$;

create or replace function public.secretary_set_resolution_status(
  p_resolution_id uuid,
  p_status        text,
  p_reason        text default null
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id   uuid := public.acting_council_secretary_staff_id();
  v_resolution public.council_resolutions;
begin
  select * into v_resolution from public.council_resolutions where id = p_resolution_id for update;
  if not found then
    raise exception 'That resolution could not be found.' using errcode = 'TA099';
  end if;
  if p_status is null or p_status not in ('active', 'implemented', 'withdrawn') then
    raise exception 'A resolution is active, implemented or withdrawn.' using errcode = 'TA097';
  end if;
  if v_resolution.resolution_status = 'withdrawn' then
    raise exception 'Resolution % has been withdrawn; that stands.', v_resolution.resolution_reference
      using errcode = 'TA097';
  end if;
  if p_status = v_resolution.resolution_status then
    raise exception 'Resolution % is already %.', v_resolution.resolution_reference, p_status
      using errcode = 'TA097';
  end if;
  if p_status = 'active' then
    raise exception 'Resolution % cannot be made active again.', v_resolution.resolution_reference
      using errcode = 'TA097';
  end if;

  if p_status = 'implemented' then
    update public.council_resolutions
       set resolution_status = 'implemented', implemented_at = now(),
           implemented_by_staff_id = v_staff_id
     where id = v_resolution.id
    returning * into v_resolution;
  else
    if btrim(coalesce(p_reason, '')) = '' then
      raise exception 'A reason is required to withdraw a resolution.' using errcode = 'TA100';
    end if;
    update public.council_resolutions
       set resolution_status = 'withdrawn', withdrawal_reason = btrim(p_reason),
           withdrawn_at = now(), withdrawn_by_staff_id = v_staff_id
     where id = v_resolution.id
    returning * into v_resolution;
  end if;

  return jsonb_build_object(
    'resolution_id', v_resolution.id,
    'resolution_reference', v_resolution.resolution_reference,
    'resolution_status', v_resolution.resolution_status);
end;
$$;

-- Publishing, and taking a publication back. Either direction is
-- written down; taking one back always says why.
create or replace function public.secretary_set_resolution_visibility(
  p_resolution_id uuid,
  p_visibility    text,
  p_reason        text default null
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id   uuid := public.acting_council_secretary_staff_id();
  v_resolution public.council_resolutions;
  v_from       text;
begin
  select * into v_resolution from public.council_resolutions where id = p_resolution_id for update;
  if not found then
    raise exception 'That resolution could not be found.' using errcode = 'TA099';
  end if;
  if p_visibility is null or p_visibility not in ('internal', 'public') then
    raise exception 'A resolution is internal or public.' using errcode = 'TA098';
  end if;
  v_from := v_resolution.visibility;
  if v_from = p_visibility then
    raise exception 'Resolution % is already %.', v_resolution.resolution_reference, p_visibility
      using errcode = 'TA098';
  end if;
  if v_from = 'public' and p_visibility = 'internal'
     and btrim(coalesce(p_reason, '')) = '' then
    raise exception 'Taking resolution % back off the public record needs a reason.',
      v_resolution.resolution_reference using errcode = 'TA101';
  end if;

  update public.council_resolutions set visibility = p_visibility
   where id = v_resolution.id
  returning * into v_resolution;

  insert into public.visibility_changes (
    subject_type, resolution_id, from_visibility, to_visibility, reason, changed_by_staff_id)
  values ('resolution', v_resolution.id, v_from, p_visibility,
          nullif(btrim(coalesce(p_reason, '')), ''), v_staff_id);

  return jsonb_build_object(
    'resolution_id', v_resolution.id,
    'resolution_reference', v_resolution.resolution_reference,
    'visibility', v_resolution.visibility);
end;
$$;

-- ---------------------------------------------------------------------
-- 9. Projects
-- ---------------------------------------------------------------------

create or replace function public.secretary_create_project(
  p_project_name           text,
  p_description            text,
  p_start_date             date,
  p_target_completion_date date default null,
  p_resolution_id          uuid default null,
  p_visibility             text default 'internal'
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id uuid := public.acting_council_secretary_staff_id();
  v_project  public.community_projects;
begin
  if btrim(coalesce(p_project_name, '')) = '' or btrim(coalesce(p_description, '')) = '' then
    raise exception 'A project needs a name and a description.' using errcode = 'TA102';
  end if;
  if p_start_date is null then
    raise exception 'A project needs a start date.' using errcode = 'TA103';
  end if;
  if p_target_completion_date is not null and p_target_completion_date < p_start_date then
    raise exception 'A target completion date of % is before the start date of %.',
      p_target_completion_date, p_start_date using errcode = 'TA103';
  end if;
  if p_visibility is null or p_visibility not in ('internal', 'public') then
    raise exception 'A project is internal or public.' using errcode = 'TA098';
  end if;
  -- Linking a resolution is optional; naming one that does not exist is not.
  if p_resolution_id is not null
     and not exists (select 1 from public.council_resolutions where id = p_resolution_id) then
    raise exception 'That resolution could not be found.' using errcode = 'TA099';
  end if;

  insert into public.community_projects (
    project_reference, project_name, description, resolution_id, start_date,
    target_completion_date, project_status, visibility, created_by_staff_id)
  values (
    public.council_reference('PRJ-', 'project_reference', 'community_projects'),
    btrim(p_project_name), btrim(p_description), p_resolution_id, p_start_date,
    p_target_completion_date, 'planned', p_visibility, v_staff_id)
  returning * into v_project;

  if p_visibility = 'public' then
    insert into public.visibility_changes (
      subject_type, project_id, from_visibility, to_visibility, reason, changed_by_staff_id)
    values ('project', v_project.id, 'internal', 'public',
            'Recorded as public when the project was created', v_staff_id);
  end if;

  return jsonb_build_object(
    'project_id', v_project.id, 'project_reference', v_project.project_reference);
end;
$$;

create or replace function public.secretary_update_project(
  p_project_id             uuid,
  p_project_name           text,
  p_description            text,
  p_start_date             date,
  p_target_completion_date date default null,
  p_resolution_id          uuid default null
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare v_project public.community_projects;
begin
  perform public.acting_council_secretary_staff_id();

  select * into v_project from public.community_projects where id = p_project_id for update;
  if not found then
    raise exception 'That project could not be found.' using errcode = 'TA104';
  end if;
  if v_project.project_status in ('completed', 'cancelled') then
    raise exception 'Project % is %, so its details are part of the record.',
      v_project.project_reference, v_project.project_status using errcode = 'TA105';
  end if;
  if btrim(coalesce(p_project_name, '')) = '' or btrim(coalesce(p_description, '')) = '' then
    raise exception 'A project needs a name and a description.' using errcode = 'TA102';
  end if;
  if p_start_date is null then
    raise exception 'A project needs a start date.' using errcode = 'TA103';
  end if;
  if p_target_completion_date is not null and p_target_completion_date < p_start_date then
    raise exception 'A target completion date of % is before the start date of %.',
      p_target_completion_date, p_start_date using errcode = 'TA103';
  end if;
  if p_resolution_id is not null
     and not exists (select 1 from public.council_resolutions where id = p_resolution_id) then
    raise exception 'That resolution could not be found.' using errcode = 'TA099';
  end if;

  update public.community_projects
     set project_name = btrim(p_project_name), description = btrim(p_description),
         start_date = p_start_date, target_completion_date = p_target_completion_date,
         resolution_id = p_resolution_id
   where id = v_project.id
  returning * into v_project;

  return jsonb_build_object(
    'project_id', v_project.id, 'project_reference', v_project.project_reference);
end;
$$;

-- Completion is always the Secretary's own decision: finishing every
-- milestone does not finish a project by itself.
create or replace function public.secretary_set_project_status(
  p_project_id uuid,
  p_status     text,
  p_reason     text default null
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id uuid := public.acting_council_secretary_staff_id();
  v_project  public.community_projects;
begin
  select * into v_project from public.community_projects where id = p_project_id for update;
  if not found then
    raise exception 'That project could not be found.' using errcode = 'TA104';
  end if;
  if p_status is null or p_status not in ('planned', 'active', 'completed', 'cancelled') then
    raise exception 'A project is planned, active, completed or cancelled.' using errcode = 'TA105';
  end if;
  if v_project.project_status in ('completed', 'cancelled') then
    raise exception 'Project % is already %, and that stands.',
      v_project.project_reference, v_project.project_status using errcode = 'TA105';
  end if;
  if p_status = v_project.project_status then
    raise exception 'Project % is already %.', v_project.project_reference, p_status
      using errcode = 'TA105';
  end if;
  if p_status = 'planned' then
    raise exception 'Project % cannot go back to planned.', v_project.project_reference
      using errcode = 'TA105';
  end if;

  if p_status = 'cancelled' then
    if btrim(coalesce(p_reason, '')) = '' then
      raise exception 'A reason is required to cancel a project.' using errcode = 'TA106';
    end if;
    update public.community_projects
       set project_status = 'cancelled', cancellation_reason = btrim(p_reason),
           cancelled_at = now(), cancelled_by_staff_id = v_staff_id
     where id = v_project.id
    returning * into v_project;
  elsif p_status = 'completed' then
    update public.community_projects
       set project_status = 'completed', completed_on = current_date,
           completed_at = now(), completed_by_staff_id = v_staff_id
     where id = v_project.id
    returning * into v_project;
  else
    update public.community_projects set project_status = 'active'
     where id = v_project.id
    returning * into v_project;
  end if;

  return jsonb_build_object(
    'project_id', v_project.id,
    'project_reference', v_project.project_reference,
    'project_status', v_project.project_status);
end;
$$;

create or replace function public.secretary_set_project_visibility(
  p_project_id uuid,
  p_visibility text,
  p_reason     text default null
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id uuid := public.acting_council_secretary_staff_id();
  v_project  public.community_projects;
  v_from     text;
begin
  select * into v_project from public.community_projects where id = p_project_id for update;
  if not found then
    raise exception 'That project could not be found.' using errcode = 'TA104';
  end if;
  if p_visibility is null or p_visibility not in ('internal', 'public') then
    raise exception 'A project is internal or public.' using errcode = 'TA098';
  end if;
  v_from := v_project.visibility;
  if v_from = p_visibility then
    raise exception 'Project % is already %.', v_project.project_reference, p_visibility
      using errcode = 'TA098';
  end if;
  if v_from = 'public' and p_visibility = 'internal'
     and btrim(coalesce(p_reason, '')) = '' then
    raise exception 'Taking project % back off the public record needs a reason.',
      v_project.project_reference using errcode = 'TA101';
  end if;

  update public.community_projects set visibility = p_visibility
   where id = v_project.id
  returning * into v_project;

  insert into public.visibility_changes (
    subject_type, project_id, from_visibility, to_visibility, reason, changed_by_staff_id)
  values ('project', v_project.id, v_from, p_visibility,
          nullif(btrim(coalesce(p_reason, '')), ''), v_staff_id);

  return jsonb_build_object(
    'project_id', v_project.id,
    'project_reference', v_project.project_reference,
    'visibility', v_project.visibility);
end;
$$;

-- ---------------------------------------------------------------------
-- 10. Milestones
-- ---------------------------------------------------------------------

create or replace function public.secretary_add_milestone(
  p_project_id  uuid,
  p_title       text,
  p_due_date    date,
  p_description text default null
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id  uuid := public.acting_council_secretary_staff_id();
  v_project   public.community_projects;
  v_milestone public.project_milestones;
begin
  select * into v_project from public.community_projects where id = p_project_id;
  if not found then
    raise exception 'That project could not be found.' using errcode = 'TA104';
  end if;
  if v_project.project_status in ('completed', 'cancelled') then
    raise exception 'Project % is %, so no milestone can be added to it.',
      v_project.project_reference, v_project.project_status using errcode = 'TA105';
  end if;
  if btrim(coalesce(p_title, '')) = '' then
    raise exception 'A milestone needs a title.' using errcode = 'TA107';
  end if;
  if p_due_date is null then
    raise exception 'A milestone needs a due date.' using errcode = 'TA108';
  end if;
  if p_due_date < v_project.start_date then
    raise exception 'A milestone due on % falls before the project starts on %.',
      p_due_date, v_project.start_date using errcode = 'TA108';
  end if;

  insert into public.project_milestones (
    project_id, title, description, due_date, milestone_status, created_by_staff_id)
  values (v_project.id, btrim(p_title), nullif(btrim(coalesce(p_description, '')), ''),
          p_due_date, 'pending', v_staff_id)
  returning * into v_milestone;

  return jsonb_build_object('milestone_id', v_milestone.id, 'title', v_milestone.title);
end;
$$;

create or replace function public.secretary_update_milestone(
  p_milestone_id uuid,
  p_title        text,
  p_due_date     date,
  p_description  text default null
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_milestone public.project_milestones;
  v_project   public.community_projects;
begin
  perform public.acting_council_secretary_staff_id();

  select * into v_milestone from public.project_milestones where id = p_milestone_id for update;
  if not found then
    raise exception 'That milestone could not be found.' using errcode = 'TA107';
  end if;
  select * into v_project from public.community_projects where id = v_milestone.project_id;

  if btrim(coalesce(p_title, '')) = '' then
    raise exception 'A milestone needs a title.' using errcode = 'TA107';
  end if;
  if p_due_date is null then
    raise exception 'A milestone needs a due date.' using errcode = 'TA108';
  end if;
  if p_due_date < v_project.start_date then
    raise exception 'A milestone due on % falls before the project starts on %.',
      p_due_date, v_project.start_date using errcode = 'TA108';
  end if;

  update public.project_milestones
     set title = btrim(p_title), due_date = p_due_date,
         description = nullif(btrim(coalesce(p_description, '')), '')
   where id = v_milestone.id
  returning * into v_milestone;

  return jsonb_build_object('milestone_id', v_milestone.id, 'title', v_milestone.title);
end;
$$;

create or replace function public.secretary_set_milestone_status(
  p_milestone_id uuid,
  p_status       text
)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_staff_id  uuid := public.acting_council_secretary_staff_id();
  v_milestone public.project_milestones;
begin
  select * into v_milestone from public.project_milestones where id = p_milestone_id for update;
  if not found then
    raise exception 'That milestone could not be found.' using errcode = 'TA107';
  end if;
  -- 'overdue' is deliberately not offered: it is never stored.
  if p_status is null or p_status not in ('pending', 'in_progress', 'completed') then
    raise exception 'A milestone is pending, in progress or completed. Overdue is worked out from the due date, not chosen.'
      using errcode = 'TA109';
  end if;
  if v_milestone.milestone_status = p_status then
    raise exception 'That milestone is already %.', replace(p_status, '_', ' ')
      using errcode = 'TA109';
  end if;

  if p_status = 'completed' then
    update public.project_milestones
       set milestone_status = 'completed', completed_at = now(), completed_by_staff_id = v_staff_id
     where id = v_milestone.id
    returning * into v_milestone;
  else
    update public.project_milestones
       set milestone_status = p_status, completed_at = null, completed_by_staff_id = null
     where id = v_milestone.id
    returning * into v_milestone;
  end if;

  return jsonb_build_object(
    'milestone_id', v_milestone.id,
    'milestone_status', v_milestone.milestone_status,
    'effective_status', public.milestone_effective_status(
      v_milestone.milestone_status, v_milestone.due_date),
    'completed_at', v_milestone.completed_at);
end;
$$;

-- ---------------------------------------------------------------------
-- 11. What the Secretary sees
-- ---------------------------------------------------------------------

create or replace function public.secretary_meetings(
  p_status text default null,
  p_type   text default null,
  p_when   text default null,     -- 'upcoming', 'past', or null for both
  p_search text default null
)
returns table (
  meeting_id uuid, meeting_reference text, title text, meeting_type text,
  meeting_date date, start_time time, venue text, meeting_status text,
  cancellation_reason text, minutes_status text, resolution_count bigint,
  attendee_count bigint, present_count bigint
)
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_pattern text := public.like_pattern(p_search);
        v_empty boolean := coalesce(btrim(p_search), '') = '';
begin
  perform public.acting_council_secretary_staff_id();
  return query
    select m.id, m.meeting_reference, m.title, m.meeting_type, m.meeting_date,
           m.start_time, m.venue, m.meeting_status, m.cancellation_reason,
           (select mm.minutes_status from public.meeting_minutes mm where mm.meeting_id = m.id),
           (select count(*) from public.council_resolutions r where r.meeting_id = m.id),
           (select count(*) from public.meeting_attendance a where a.meeting_id = m.id),
           (select count(*) from public.meeting_attendance a
             where a.meeting_id = m.id and a.attendance_status = 'present')
    from public.council_meetings m
    where (p_status is null or m.meeting_status = p_status)
      and (p_type is null or m.meeting_type = p_type)
      and (p_when is null
           or (p_when = 'upcoming' and m.meeting_date >= current_date)
           or (p_when = 'past' and m.meeting_date < current_date))
      and (v_empty or m.meeting_reference ilike v_pattern or m.title ilike v_pattern
           or m.venue ilike v_pattern)
    order by m.meeting_date desc, m.start_time desc;
end;
$$;

-- One meeting, and everything that belongs to it: who was there, the
-- minutes, every amendment to them, and every resolution it produced.
create or replace function public.secretary_meeting(p_meeting_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_result jsonb;
begin
  perform public.acting_council_secretary_staff_id();

  select jsonb_build_object(
    'meeting_id',          m.id,
    'meeting_reference',   m.meeting_reference,
    'title',               m.title,
    'meeting_type',        m.meeting_type,
    'meeting_date',        m.meeting_date,
    'start_time',          m.start_time,
    'venue',               m.venue,
    'agenda',              m.agenda,
    'meeting_status',      m.meeting_status,
    'cancellation_reason', m.cancellation_reason,
    'created_by',          (select s.first_name || ' ' || s.last_name from public.staff s
                             where s.id = m.created_by_staff_id),
    'created_at',          m.created_at,

    'attendance', coalesce((
      select jsonb_agg(jsonb_build_object(
               'attendance_id',     a.id,
               'attendee_name',     a.attendee_name,
               'role_or_capacity',  a.role_or_capacity,
               'attendance_status', a.attendance_status)
             order by a.attendee_name)
      from public.meeting_attendance a where a.meeting_id = m.id), '[]'::jsonb),

    'minutes', (
      select jsonb_build_object(
               'minutes_id',      mm.id,
               'minutes_content', mm.minutes_content,
               'minutes_status',  mm.minutes_status,
               'finalized_at',    mm.finalized_at,
               'finalized_by',    (select s.first_name || ' ' || s.last_name from public.staff s
                                    where s.id = mm.finalized_by_staff_id),
               'amendments', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'amendment_id',        am.id,
                          'amendment_reference', am.amendment_reference,
                          'amendment_text',      am.amendment_text,
                          'reason',              am.reason,
                          'created_at',          am.created_at,
                          'created_by', (select s.first_name || ' ' || s.last_name
                                          from public.staff s where s.id = am.created_by_staff_id))
                        order by am.created_at)
                 from public.meeting_minutes_amendments am where am.minutes_id = mm.id), '[]'::jsonb))
      from public.meeting_minutes mm where mm.meeting_id = m.id),

    'resolutions', coalesce((
      select jsonb_agg(jsonb_build_object(
               'resolution_id',        r.id,
               'resolution_reference', r.resolution_reference,
               'resolution_text',      r.resolution_text,
               'decision_date',        r.decision_date,
               'resolution_status',    r.resolution_status,
               'visibility',           r.visibility,
               'withdrawal_reason',    r.withdrawal_reason)
             order by r.resolution_reference)
      from public.council_resolutions r where r.meeting_id = m.id), '[]'::jsonb)
  ) into v_result
  from public.council_meetings m where m.id = p_meeting_id;

  if v_result is null then
    raise exception 'That meeting could not be found.' using errcode = 'TA084';
  end if;
  return v_result;
end;
$$;

create or replace function public.secretary_resolutions(
  p_status     text default null,
  p_visibility text default null,
  p_search     text default null
)
returns table (
  resolution_id uuid, resolution_reference text, resolution_text text,
  decision_date date, resolution_status text, visibility text,
  withdrawal_reason text, meeting_id uuid, meeting_reference text, meeting_title text,
  minutes_status text, visible_to_residents boolean, project_count bigint
)
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_pattern text := public.like_pattern(p_search);
        v_empty boolean := coalesce(btrim(p_search), '') = '';
begin
  perform public.acting_council_secretary_staff_id();
  return query
    select r.id, r.resolution_reference, r.resolution_text, r.decision_date,
           r.resolution_status, r.visibility, r.withdrawal_reason,
           m.id, m.meeting_reference, m.title,
           mm.minutes_status,
           (r.visibility = 'public' and coalesce(mm.minutes_status, 'draft') = 'final'),
           (select count(*) from public.community_projects p where p.resolution_id = r.id)
    from public.council_resolutions r
    join public.council_meetings m on m.id = r.meeting_id
    left join public.meeting_minutes mm on mm.meeting_id = m.id
    where (p_status is null or r.resolution_status = p_status)
      and (p_visibility is null or r.visibility = p_visibility)
      and (v_empty or r.resolution_reference ilike v_pattern
           or r.resolution_text ilike v_pattern or m.meeting_reference ilike v_pattern)
    order by r.decision_date desc, r.resolution_reference desc;
end;
$$;

create or replace function public.secretary_projects(
  p_status     text default null,
  p_visibility text default null,
  p_search     text default null
)
returns table (
  project_id uuid, project_reference text, project_name text, description text,
  start_date date, target_completion_date date, project_status text, visibility text,
  cancellation_reason text, completed_on date,
  resolution_id uuid, resolution_reference text, resolution_visibility text,
  milestone_count bigint, completed_milestones bigint, overdue_milestones bigint
)
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_pattern text := public.like_pattern(p_search);
        v_empty boolean := coalesce(btrim(p_search), '') = '';
begin
  perform public.acting_council_secretary_staff_id();
  return query
    select p.id, p.project_reference, p.project_name, p.description, p.start_date,
           p.target_completion_date, p.project_status, p.visibility,
           p.cancellation_reason, p.completed_on,
           r.id, r.resolution_reference, r.visibility,
           (select count(*) from public.project_milestones ms where ms.project_id = p.id),
           (select count(*) from public.project_milestones ms
             where ms.project_id = p.id and ms.milestone_status = 'completed'),
           (select count(*) from public.project_milestones ms
             where ms.project_id = p.id
               and public.milestone_effective_status(ms.milestone_status, ms.due_date) = 'overdue')
    from public.community_projects p
    left join public.council_resolutions r on r.id = p.resolution_id
    where (p_status is null or p.project_status = p_status)
      and (p_visibility is null or p.visibility = p_visibility)
      and (v_empty or p.project_reference ilike v_pattern or p.project_name ilike v_pattern
           or p.description ilike v_pattern)
    order by p.start_date desc, p.project_reference desc;
end;
$$;

create or replace function public.secretary_project(p_project_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_result jsonb;
begin
  perform public.acting_council_secretary_staff_id();

  select jsonb_build_object(
    'project_id',             p.id,
    'project_reference',      p.project_reference,
    'project_name',           p.project_name,
    'description',            p.description,
    'start_date',             p.start_date,
    'target_completion_date', p.target_completion_date,
    'project_status',         p.project_status,
    'visibility',             p.visibility,
    'cancellation_reason',    p.cancellation_reason,
    'completed_on',           p.completed_on,
    'created_by',             (select s.first_name || ' ' || s.last_name from public.staff s
                                where s.id = p.created_by_staff_id),
    'created_at',             p.created_at,
    'resolution', (
      select jsonb_build_object(
               'resolution_id',        r.id,
               'resolution_reference', r.resolution_reference,
               'resolution_text',      r.resolution_text,
               'visibility',           r.visibility,
               'resolution_status',    r.resolution_status,
               'meeting_reference',    (select m.meeting_reference from public.council_meetings m
                                         where m.id = r.meeting_id))
      from public.council_resolutions r where r.id = p.resolution_id),

    'milestones', coalesce((
      select jsonb_agg(jsonb_build_object(
               'milestone_id',     ms.id,
               'title',            ms.title,
               'description',      ms.description,
               'due_date',         ms.due_date,
               'milestone_status', ms.milestone_status,
               'effective_status', public.milestone_effective_status(ms.milestone_status, ms.due_date),
               'completed_at',     ms.completed_at)
             order by ms.due_date, ms.created_at)
      from public.project_milestones ms where ms.project_id = p.id), '[]'::jsonb),

    'visibility_history', coalesce((
      select jsonb_agg(jsonb_build_object(
               'from_visibility', v.from_visibility,
               'to_visibility',   v.to_visibility,
               'reason',          v.reason,
               'changed_at',      v.changed_at,
               'changed_by', (select s.first_name || ' ' || s.last_name from public.staff s
                               where s.id = v.changed_by_staff_id))
             order by v.changed_at)
      from public.visibility_changes v where v.project_id = p.id), '[]'::jsonb)
  ) into v_result
  from public.community_projects p where p.id = p_project_id;

  if v_result is null then
    raise exception 'That project could not be found.' using errcode = 'TA104';
  end if;
  return v_result;
end;
$$;

-- The history of a resolution's publication, for the Secretary only.
create or replace function public.secretary_resolution_visibility_history(p_resolution_id uuid)
returns table (
  from_visibility text, to_visibility text, reason text,
  changed_at timestamptz, changed_by text
)
language plpgsql stable security definer set search_path = public, pg_temp
as $$
begin
  perform public.acting_council_secretary_staff_id();
  return query
    select v.from_visibility, v.to_visibility, v.reason, v.changed_at,
           (select s.first_name || ' ' || s.last_name from public.staff s
             where s.id = v.changed_by_staff_id)
    from public.visibility_changes v
    where v.resolution_id = p_resolution_id
    order by v.changed_at;
end;
$$;

-- ---------------------------------------------------------------------
-- 12. The dashboard
--
--     Overdue is counted from the due date every time this runs.
-- ---------------------------------------------------------------------

create or replace function public.secretary_dashboard()
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
begin
  perform public.acting_council_secretary_staff_id();
  return jsonb_build_object(
    'upcoming_meetings', (
      select count(*) from public.council_meetings
      where meeting_status = 'scheduled' and meeting_date >= current_date),
    'meetings_awaiting_minutes', (
      select count(*) from public.council_meetings m
      where m.meeting_status = 'held'
        and not exists (select 1 from public.meeting_minutes mm
                         where mm.meeting_id = m.id and mm.minutes_status = 'final')),
    'draft_minutes', (
      select count(*) from public.meeting_minutes where minutes_status = 'draft'),
    'final_minutes', (
      select count(*) from public.meeting_minutes where minutes_status = 'final'),
    'active_resolutions', (
      select count(*) from public.council_resolutions where resolution_status = 'active'),
    'public_resolutions', (
      select count(*) from public.council_resolutions r
      where r.visibility = 'public' and public.meeting_minutes_are_final(r.meeting_id)),
    'active_projects', (
      select count(*) from public.community_projects where project_status = 'active'),
    'planned_projects', (
      select count(*) from public.community_projects where project_status = 'planned'),
    'public_projects', (
      select count(*) from public.community_projects where visibility = 'public'),
    'overdue_milestones', (
      select count(*) from public.project_milestones ms
      join public.community_projects p on p.id = ms.project_id
      where p.project_status in ('planned', 'active')
        and public.milestone_effective_status(ms.milestone_status, ms.due_date) = 'overdue'),
    'next_meeting', (
      select jsonb_build_object(
               'meeting_id', m.id, 'meeting_reference', m.meeting_reference,
               'title', m.title, 'meeting_date', m.meeting_date, 'start_time', m.start_time,
               'venue', m.venue)
      from public.council_meetings m
      where m.meeting_status = 'scheduled' and m.meeting_date >= current_date
      order by m.meeting_date, m.start_time limit 1));
end;
$$;

-- ---------------------------------------------------------------------
-- 13. What a resident may see
--
--     Community Updates. Only public resolutions from meetings whose
--     minutes are final, only public projects, and the milestones of
--     those projects. Nothing about attendance, nothing about minutes —
--     not their contents, not their status, not whether they exist —
--     and nothing internal.
--
--     Every field here is chosen one at a time. This never selects a
--     whole row and leaves the browser to hide the rest of it.
-- ---------------------------------------------------------------------

create or replace function public.resident_community_updates()
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp
as $$
declare v_resident_id uuid := public.current_resident_id();
begin
  if v_resident_id is null then
    raise exception 'Community updates are for verified resident accounts.'
      using errcode = '42501';
  end if;

  return jsonb_build_object(
    'resolutions', coalesce((
      select jsonb_agg(jsonb_build_object(
               'resolution_reference', r.resolution_reference,
               'resolution_text',      r.resolution_text,
               'decision_date',        r.decision_date,
               'resolution_status',    r.resolution_status)
             order by r.decision_date desc, r.resolution_reference desc)
      from public.council_resolutions r
      where r.visibility = 'public'
        and public.meeting_minutes_are_final(r.meeting_id)), '[]'::jsonb),

    'projects', coalesce((
      select jsonb_agg(project order by project ->> 'start_date' desc)
      from (
        select jsonb_build_object(
                 'project_reference',      p.project_reference,
                 'project_name',           p.project_name,
                 'description',            p.description,
                 'start_date',             p.start_date,
                 'target_completion_date', p.target_completion_date,
                 'project_status',         p.project_status,
                 -- Only ever the reference, and only when that
                 -- resolution is itself public and confirmed. A public
                 -- project never becomes a way of reading an internal
                 -- resolution.
                 'resolution_reference', (
                   select r.resolution_reference from public.council_resolutions r
                   where r.id = p.resolution_id
                     and r.visibility = 'public'
                     and public.meeting_minutes_are_final(r.meeting_id)),
                 'milestones', coalesce((
                   select jsonb_agg(jsonb_build_object(
                            'title',            ms.title,
                            'description',      ms.description,
                            'due_date',         ms.due_date,
                            'effective_status', public.milestone_effective_status(
                                                  ms.milestone_status, ms.due_date))
                          order by ms.due_date, ms.created_at)
                   from public.project_milestones ms where ms.project_id = p.id), '[]'::jsonb)
               ) as project
        from public.community_projects p
        where p.visibility = 'public'
      ) as public_projects), '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------
-- 14. Grants
--
--     Each function establishes its own caller, so execute may be given
--     to signed-in users: the functions turn away anyone who should not
--     be there.
-- ---------------------------------------------------------------------

do $$
declare v_signature text;
begin
  foreach v_signature in array array[
    'public.is_active_council_secretary()',
    'public.milestone_effective_status(text, date)',
    'public.meeting_minutes_are_final(uuid)',
    'public.resolution_is_public(uuid)',
    'public.project_is_public(uuid)',
    'public.secretary_schedule_meeting(text, text, date, time, text, text)',
    'public.secretary_update_meeting(uuid, text, text, date, time, text, text)',
    'public.secretary_set_meeting_status(uuid, text, text)',
    'public.secretary_add_attendee(uuid, text, text, text)',
    'public.secretary_update_attendee(uuid, text, text, text)',
    'public.secretary_save_minutes(uuid, text)',
    'public.secretary_finalize_minutes(uuid)',
    'public.secretary_add_amendment(uuid, text, text)',
    'public.secretary_record_resolution(uuid, text, text)',
    'public.secretary_update_resolution(uuid, text)',
    'public.secretary_set_resolution_status(uuid, text, text)',
    'public.secretary_set_resolution_visibility(uuid, text, text)',
    'public.secretary_create_project(text, text, date, date, uuid, text)',
    'public.secretary_update_project(uuid, text, text, date, date, uuid)',
    'public.secretary_set_project_status(uuid, text, text)',
    'public.secretary_set_project_visibility(uuid, text, text)',
    'public.secretary_add_milestone(uuid, text, date, text)',
    'public.secretary_update_milestone(uuid, text, date, text)',
    'public.secretary_set_milestone_status(uuid, text)',
    'public.secretary_meetings(text, text, text, text)',
    'public.secretary_meeting(uuid)',
    'public.secretary_resolutions(text, text, text)',
    'public.secretary_projects(text, text, text)',
    'public.secretary_project(uuid)',
    'public.secretary_resolution_visibility_history(uuid)',
    'public.secretary_dashboard()',
    'public.resident_community_updates()'
  ]
  loop
    execute format('revoke all on function %s from public, anon, authenticated', v_signature);
    execute format('grant execute on function %s to authenticated', v_signature);
  end loop;
end;
$$;

revoke all on function public.acting_council_secretary_staff_id() from public, anon, authenticated;
revoke all on function public.council_reference(text, text, text) from public, anon, authenticated;
