-- =====================================================================
-- TAMS — recording that somebody reset their password
--
-- The reset itself is Supabase Auth's: TAMS mints no recovery token,
-- stores none, and never touches the auth tables. What this adds is one
-- line in the audit trail saying that a password was reset, by whom and
-- when — and nothing else.
--
-- Deliberately taking no parameters at all. The function cannot be
-- asked to name a different actor, a different account or a different
-- action: everything it records it works out for itself from
-- auth.uid(). A caller therefore gains nothing by calling it that they
-- could not already say truthfully about themselves, which is why it
-- does not weaken the authentication boundary the way an ordinary
-- "write me an audit entry" endpoint would.
-- =====================================================================

create or replace function public.record_password_reset()
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare v_account public.user_accounts;
begin
  select * into v_account from public.user_accounts where auth_user_id = auth.uid();

  -- A recovery session with no TAMS account behind it. There is nothing
  -- to record, and saying so would be saying something about who does
  -- and does not have an account here.
  if not found then
    return jsonb_build_object('recorded', false);
  end if;

  -- No old value and no new value: nothing in TAMS changed, and the
  -- one thing that did change outside it is a password, which is never
  -- written down here in any form.
  perform public.audit_event(
    'PASSWORD_RESET_COMPLETED',
    'user_account',
    v_account.id,
    v_account.email,
    null,
    null,
    null);

  return jsonb_build_object('recorded', true);
end;
$$;

revoke all on function public.record_password_reset() from public, anon, authenticated;
grant execute on function public.record_password_reset() to authenticated;
