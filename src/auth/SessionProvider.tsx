import { createContext, useCallback, useContext, useEffect, useMemo, useState } from "react";
import type { ReactNode } from "react";
import type { Session } from "@supabase/supabase-js";
import { supabase } from "../lib/supabaseClient";
import type { StaffContext } from "../lib/types";

type SessionState = {
  /** Still working out who the user is. Nothing should be decided yet. */
  loading: boolean;
  session: Session | null;
  /** Read from the database on every load — never from the browser. */
  profile: StaffContext | null;
  /** The auth user signed in but has no user_accounts record at all. */
  accountMissing: boolean;
  refresh: () => Promise<void>;
  signOut: () => Promise<void>;
};

const SessionContext = createContext<SessionState | undefined>(undefined);

export function SessionProvider({ children }: { children: ReactNode }) {
  const [loading, setLoading] = useState(true);
  const [session, setSession] = useState<Session | null>(null);
  const [profile, setProfile] = useState<StaffContext | null>(null);
  const [accountMissing, setAccountMissing] = useState(false);

  // Ask the database who this user is. current_staff_context() works
  // from auth.uid(), so a tampered browser cannot change the answer.
  const loadProfile = useCallback(async (activeSession: Session | null) => {
    if (!activeSession) {
      setProfile(null);
      setAccountMissing(false);
      return;
    }
    const { data, error } = await supabase.rpc("current_staff_context");
    if (error) {
      setProfile(null);
      setAccountMissing(true);
      return;
    }
    setProfile((data as StaffContext) ?? null);
    setAccountMissing(data === null);
  }, []);

  useEffect(() => {
    let cancelled = false;

    supabase.auth.getSession().then(async ({ data }) => {
      if (cancelled) return;
      setSession(data.session);
      await loadProfile(data.session);
      if (!cancelled) setLoading(false);
    });

    const { data: listener } = supabase.auth.onAuthStateChange(async (_event, nextSession) => {
      if (cancelled) return;
      setSession(nextSession);
      setLoading(true);
      await loadProfile(nextSession);
      if (!cancelled) setLoading(false);
    });

    return () => {
      cancelled = true;
      listener.subscription.unsubscribe();
    };
  }, [loadProfile]);

  const refresh = useCallback(async () => {
    const { data } = await supabase.auth.getSession();
    setSession(data.session);
    await loadProfile(data.session);
  }, [loadProfile]);

  const signOut = useCallback(async () => {
    await supabase.auth.signOut();
    setSession(null);
    setProfile(null);
    setAccountMissing(false);
  }, []);

  const value = useMemo<SessionState>(
    () => ({ loading, session, profile, accountMissing, refresh, signOut }),
    [loading, session, profile, accountMissing, refresh, signOut],
  );

  return <SessionContext.Provider value={value}>{children}</SessionContext.Provider>;
}

export function useSession(): SessionState {
  const context = useContext(SessionContext);
  if (!context) throw new Error("useSession must be used inside a SessionProvider.");
  return context;
}

/** Where a signed-in user belongs, decided by their role in the database. */
export function homePathFor(profile: StaffContext | null): string {
  if (!profile || !profile.access_granted) return "/no-access";
  return profile.is_council_administrator ? "/dashboard" : "/home";
}
