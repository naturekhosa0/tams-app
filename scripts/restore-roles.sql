-- =====================================================================
-- Restore the four TAMS staff roles.
--
-- Paste into the Supabase SQL Editor and run. Safe to run at any time:
-- roles that are still there are left exactly as they are, and only
-- missing ones are put back.
--
-- A role that any staff member holds cannot be deleted in the first
-- place (staff.role_id refuses it), so restoring a role never repairs
-- or disturbs an existing staff record — it simply makes the role
-- available to assign again.
-- =====================================================================

insert into public.roles (role_name, description) values
  ('Registry Clerk',        'Handles registry intake and record keeping.'),
  ('Land Officer',          'Handles land related administration.'),
  ('Council Secretary',     'Handles council administration and meetings.'),
  ('Council Administrator', 'Administers the system and manages staff accounts.')
on conflict (role_name) do nothing;

-- What the roles table holds now. Expect exactly these four rows,
-- every one of them marked "ok".
select
  role_name,
  description,
  case
    when role_name in ('Registry Clerk', 'Land Officer', 'Council Secretary', 'Council Administrator')
      then 'ok'
    else 'UNEXPECTED — this role is not part of TAMS'
  end as status,
  (select count(*) from public.staff s where s.role_id = r.id) as staff_holding_this_role
from public.roles r
order by role_name;
