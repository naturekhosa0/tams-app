import { createClient, type SupabaseClient } from "@supabase/supabase-js";

const url = import.meta.env.VITE_SUPABASE_URL;
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY;

/** True when the project has been pointed at a Supabase project. */
export const isConfigured = Boolean(url && anonKey);

// Only the anon key is ever used in the browser. It carries no rights of
// its own: everything it can reach is decided by Row Level Security.
export const supabase: SupabaseClient = createClient(
  url ?? "http://localhost",
  anonKey ?? "public-anon-key",
  {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: true,
    },
  },
);

export type EdgeFunctionResult<T> = {
  ok: boolean;
  status: number;
  data?: T;
  message?: string;
  fields?: Record<string, string>;
};

/**
 * Calls a server-side edge function with the signed-in user's token, so
 * the function can establish who the caller is for itself.
 */
export async function callEdgeFunction<T>(
  name: string,
  body: unknown,
): Promise<EdgeFunctionResult<T>> {
  const { data: { session } } = await supabase.auth.getSession();
  if (!session) {
    return { ok: false, status: 401, message: "Your session has ended. Please sign in again." };
  }

  let response: Response;
  try {
    response = await fetch(`${url}/functions/v1/${name}`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: anonKey,
        Authorization: `Bearer ${session.access_token}`,
      },
      body: JSON.stringify(body),
    });
  } catch {
    return { ok: false, status: 0, message: "The server could not be reached. Check your connection and try again." };
  }

  let payload: Record<string, unknown> = {};
  try {
    payload = await response.json();
  } catch {
    // An empty or non-JSON body is handled by the status check below.
  }

  if (!response.ok) {
    const error = payload.error as { message?: string } | undefined;
    return {
      ok: false,
      status: response.status,
      message: error?.message ?? "The request could not be completed.",
      fields: payload.fields as Record<string, string> | undefined,
    };
  }

  return { ok: true, status: response.status, data: payload as T };
}
