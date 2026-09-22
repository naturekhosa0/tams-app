-- =====================================================================
-- TAMS — the Council Secretary's records
--
-- Meetings, who attended them, the minutes, corrections to minutes that
-- have already been finalised, the resolutions a meeting produced, the
-- projects the community is running, and the milestones those projects
-- are measured by.
--
-- Two rules shape the whole thing:
--
--   * Official history is never rewritten. Finalised minutes are
--     locked and corrected by amendment; cancelled meetings, withdrawn
--     resolutions and cancelled projects are kept with their reason.
--     Nothing here is ever physically deleted.
--
--   * What a resident may see is decided by the database, not by the
--     browser. Internal records are unreachable, not merely hidden.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Meetings
-- ---------------------------------------------------------------------

create table if not exists public.council_meetings (
  id                     uuid primary key default gen_random_uuid(),
  meeting_reference      text not null unique,
  title                  text not null,
  meeting_type           text not null,
  meeting_date           date not null,
  start_time             time not null,
  venue                  text not null,
  agenda                 text not null,
  meeting_status         text not null default 'scheduled',

  -- Kept for the record, never to be rewritten later.
  cancellation_reason    text,
  cancelled_at           timestamptz,
  cancelled_by_staff_id  uuid references public.staff (id),
  held_recorded_at       timestamptz,
  held_recorded_by_staff_id uuid references public.staff (id),

  created_by_staff_id    uuid references public.staff (id),
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),

  constraint council_meetings_reference_not_blank check (btrim(meeting_reference) <> ''),
  constraint council_meetings_title_not_blank     check (btrim(title) <> ''),
  constraint council_meetings_venue_not_blank     check (btrim(venue) <> ''),
  constraint council_meetings_agenda_not_blank    check (btrim(agenda) <> ''),
  constraint council_meetings_type_allowed
    check (meeting_type in ('ordinary', 'special', 'emergency')),
  constraint council_meetings_status_allowed
    check (meeting_status in ('scheduled', 'held', 'cancelled')),
  -- A date nobody could have meant. The narrower "not decades away"
  -- check lives in the function, because a CHECK constraint may not
  -- look at today's date.
  constraint council_meetings_date_sane check (meeting_date >= date '2000-01-01'),
  -- A cancelled meeting always says why, and who decided.
  constraint council_meetings_cancellation_shape check (
    meeting_status <> 'cancelled'
    or (btrim(coalesce(cancellation_reason, '')) <> ''
        and cancelled_at is not null and cancelled_by_staff_id is not null)
  ),
  -- A meeting that has not been cancelled carries no cancellation.
  constraint council_meetings_no_stray_cancellation check (
    meeting_status = 'cancelled'
    or (cancellation_reason is null and cancelled_at is null and cancelled_by_staff_id is null)
  )
);

create index if not exists council_meetings_date_idx   on public.council_meetings (meeting_date desc);
create index if not exists council_meetings_status_idx on public.council_meetings (meeting_status);

-- ---------------------------------------------------------------------
-- 2. Who was there
--
--    Attendance is an official record of a meeting, not a way of
--    signing in. The Chief, a Headman or Headwoman, a council member or
--    an invited guest is written down by name and capacity; none of
--    them needs a TAMS account, a staff record or a resident record,
--    and this table deliberately links to none of those.
-- ---------------------------------------------------------------------

create table if not exists public.meeting_attendance (
  id                  uuid primary key default gen_random_uuid(),
  meeting_id          uuid not null references public.council_meetings (id),
  attendee_name       text not null,
  role_or_capacity    text not null,
  attendance_status   text not null default 'present',
  recorded_by_staff_id uuid references public.staff (id),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),

  constraint meeting_attendance_name_not_blank     check (btrim(attendee_name) <> ''),
  constraint meeting_attendance_capacity_not_blank check (btrim(role_or_capacity) <> ''),
  constraint meeting_attendance_status_allowed
    check (attendance_status in ('present', 'absent', 'apology'))
);

create index if not exists meeting_attendance_meeting_idx on public.meeting_attendance (meeting_id);

-- ---------------------------------------------------------------------
-- 3. Minutes — at most one official record per meeting
--
--    The council confirms minutes the way it always has, in the room.
--    TAMS records that confirmation; it does not add a second digital
--    approver.
-- ---------------------------------------------------------------------

create table if not exists public.meeting_minutes (
  id                    uuid primary key default gen_random_uuid(),
  meeting_id            uuid not null unique references public.council_meetings (id),
  minutes_content       text not null,
  minutes_status        text not null default 'draft',
  finalized_at          timestamptz,
  finalized_by_staff_id uuid references public.staff (id),
  created_by_staff_id   uuid references public.staff (id),
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),

  constraint meeting_minutes_status_allowed check (minutes_status in ('draft', 'final')),
  constraint meeting_minutes_final_shape check (
    minutes_status <> 'final'
    or (btrim(minutes_content) <> '' and finalized_at is not null and finalized_by_staff_id is not null)
  ),
  constraint meeting_minutes_draft_shape check (
    minutes_status <> 'draft'
    or (finalized_at is null and finalized_by_staff_id is null)
  )
);

-- ---------------------------------------------------------------------
-- 4. Amendments — how finalised minutes are corrected
--
--    The original is never reopened and never overwritten. A correction
--    is a separate record, shown alongside it for ever.
-- ---------------------------------------------------------------------

create table if not exists public.meeting_minutes_amendments (
  id                  uuid primary key default gen_random_uuid(),
  minutes_id          uuid not null references public.meeting_minutes (id),
  amendment_reference text not null unique,
  amendment_text      text not null,
  reason              text not null,
  created_by_staff_id uuid references public.staff (id),
  created_at          timestamptz not null default now(),

  constraint minutes_amendments_text_not_blank   check (btrim(amendment_text) <> ''),
  constraint minutes_amendments_reason_not_blank check (btrim(reason) <> '')
);

create index if not exists minutes_amendments_minutes_idx
  on public.meeting_minutes_amendments (minutes_id);

-- ---------------------------------------------------------------------
-- 5. Resolutions
--
--    One meeting may produce many. The decision date comes from the
--    meeting, never from the browser.
-- ---------------------------------------------------------------------

create table if not exists public.council_resolutions (
  id                    uuid primary key default gen_random_uuid(),
  resolution_reference  text not null unique,
  meeting_id            uuid not null references public.council_meetings (id),
  resolution_text       text not null,
  decision_date         date not null,
  resolution_status     text not null default 'active',
  visibility            text not null default 'internal',

  withdrawal_reason     text,
  withdrawn_at          timestamptz,
  withdrawn_by_staff_id uuid references public.staff (id),
  implemented_at        timestamptz,
  implemented_by_staff_id uuid references public.staff (id),

  created_by_staff_id   uuid references public.staff (id),
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),

  constraint council_resolutions_text_not_blank check (btrim(resolution_text) <> ''),
  constraint council_resolutions_status_allowed
    check (resolution_status in ('active', 'implemented', 'withdrawn')),
  constraint council_resolutions_visibility_allowed
    check (visibility in ('internal', 'public')),
  constraint council_resolutions_withdrawal_shape check (
    resolution_status <> 'withdrawn'
    or (btrim(coalesce(withdrawal_reason, '')) <> ''
        and withdrawn_at is not null and withdrawn_by_staff_id is not null)
  )
);

create index if not exists council_resolutions_meeting_idx on public.council_resolutions (meeting_id);
create index if not exists council_resolutions_visible_idx
  on public.council_resolutions (visibility, resolution_status);

-- ---------------------------------------------------------------------
-- 6. Projects
--
--    A project may come out of a resolution, or may not. Both are
--    ordinary.
-- ---------------------------------------------------------------------

create table if not exists public.community_projects (
  id                     uuid primary key default gen_random_uuid(),
  project_reference      text not null unique,
  project_name           text not null,
  description            text not null,
  resolution_id          uuid references public.council_resolutions (id),
  start_date             date not null,
  target_completion_date date,
  project_status         text not null default 'planned',
  visibility             text not null default 'internal',

  cancellation_reason    text,
  cancelled_at           timestamptz,
  cancelled_by_staff_id  uuid references public.staff (id),
  completed_on           date,
  completed_at           timestamptz,
  completed_by_staff_id  uuid references public.staff (id),

  created_by_staff_id    uuid references public.staff (id),
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),

  constraint community_projects_name_not_blank        check (btrim(project_name) <> ''),
  constraint community_projects_description_not_blank check (btrim(description) <> ''),
  constraint community_projects_status_allowed
    check (project_status in ('planned', 'active', 'completed', 'cancelled')),
  constraint community_projects_visibility_allowed
    check (visibility in ('internal', 'public')),
  -- A target that falls before the start is not a target.
  constraint community_projects_date_order
    check (target_completion_date is null or target_completion_date >= start_date),
  constraint community_projects_start_sane check (start_date >= date '2000-01-01'),
  constraint community_projects_cancellation_shape check (
    project_status <> 'cancelled'
    or (btrim(coalesce(cancellation_reason, '')) <> ''
        and cancelled_at is not null and cancelled_by_staff_id is not null)
  ),
  constraint community_projects_completion_shape check (
    project_status <> 'completed'
    or (completed_on is not null and completed_at is not null)
  )
);

create index if not exists community_projects_status_idx on public.community_projects (project_status);
create index if not exists community_projects_visible_idx on public.community_projects (visibility);
create index if not exists community_projects_resolution_idx on public.community_projects (resolution_id);

-- ---------------------------------------------------------------------
-- 7. Milestones
--
--    Only three statuses are ever stored. "Overdue" is not one of them:
--    it is worked out from the due date whenever anybody looks, so it
--    cannot be forgotten, mis-set, or left wrong because a nightly job
--    did not run.
-- ---------------------------------------------------------------------

create table if not exists public.project_milestones (
  id                  uuid primary key default gen_random_uuid(),
  project_id          uuid not null references public.community_projects (id),
  title               text not null,
  description         text,
  due_date            date not null,
  milestone_status    text not null default 'pending',
  completed_at        timestamptz,
  completed_by_staff_id uuid references public.staff (id),
  created_by_staff_id uuid references public.staff (id),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),

  constraint project_milestones_title_not_blank check (btrim(title) <> ''),
  constraint project_milestones_status_allowed
    check (milestone_status in ('pending', 'in_progress', 'completed')),
  constraint project_milestones_completion_shape check (
    (milestone_status = 'completed' and completed_at is not null)
    or (milestone_status <> 'completed' and completed_at is null)
  ),
  constraint project_milestones_due_sane check (due_date >= date '2000-01-01')
);

create index if not exists project_milestones_project_idx on public.project_milestones (project_id);
create index if not exists project_milestones_due_idx on public.project_milestones (due_date);

-- ---------------------------------------------------------------------
-- 8. Visibility history
--
--    Something that was published and is then taken back must leave a
--    trace. One small table covers both resolutions and projects; a row
--    is written for every change of visibility, in either direction.
-- ---------------------------------------------------------------------

create table if not exists public.visibility_changes (
  id                  uuid primary key default gen_random_uuid(),
  subject_type        text not null,
  resolution_id       uuid references public.council_resolutions (id),
  project_id          uuid references public.community_projects (id),
  from_visibility     text not null,
  to_visibility       text not null,
  reason              text,
  changed_by_staff_id uuid references public.staff (id),
  changed_at          timestamptz not null default now(),

  constraint visibility_changes_subject_allowed
    check (subject_type in ('resolution', 'project')),
  constraint visibility_changes_from_allowed check (from_visibility in ('internal', 'public')),
  constraint visibility_changes_to_allowed   check (to_visibility in ('internal', 'public')),
  constraint visibility_changes_actually_changed check (from_visibility <> to_visibility),
  -- Exactly the one subject the row is about, and no other.
  constraint visibility_changes_subject_shape check (
    (subject_type = 'resolution' and resolution_id is not null and project_id is null)
    or (subject_type = 'project' and project_id is not null and resolution_id is null)
  ),
  -- Taking something back off the public record always says why.
  constraint visibility_changes_withdrawal_reason check (
    not (from_visibility = 'public' and to_visibility = 'internal')
    or btrim(coalesce(reason, '')) <> ''
  )
);

create index if not exists visibility_changes_resolution_idx
  on public.visibility_changes (resolution_id);
create index if not exists visibility_changes_project_idx
  on public.visibility_changes (project_id);

-- ---------------------------------------------------------------------
-- 9. updated_at
-- ---------------------------------------------------------------------

do $$
declare v_table text;
begin
  foreach v_table in array array[
    'council_meetings', 'meeting_attendance', 'meeting_minutes',
    'council_resolutions', 'community_projects', 'project_milestones'
  ]
  loop
    execute format('drop trigger if exists %I on public.%I', v_table || '_touch', v_table);
    execute format(
      'create trigger %I before update on public.%I for each row execute function public.tg_touch_updated_at()',
      v_table || '_touch', v_table);
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- 10. Row Level Security
--
--     Reads are policy-driven and deliberately narrow; the policies
--     themselves are added in the next migration, where the helper
--     functions they depend on exist. Until then these tables are
--     readable by nobody, which is the safe way round.
--
--     There is no insert, update or delete policy on any of them, in
--     this migration or the next. Every write goes through a
--     `security definer` function that establishes its own caller.
-- ---------------------------------------------------------------------

do $$
declare v_table text;
begin
  foreach v_table in array array[
    'council_meetings', 'meeting_attendance', 'meeting_minutes',
    'meeting_minutes_amendments', 'council_resolutions', 'community_projects',
    'project_milestones', 'visibility_changes'
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
