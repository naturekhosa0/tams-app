// =====================================================================
// manage-staff-account — Change Staff Role, Deactivate, Reactivate.
//
// Wiring only; the rules live in handler.ts and, independently, in the
// database functions this calls.
//
// Note what is NOT here: the service role key. These three operations
// need no elevated rights. Each database function is security definer
// and works out for itself, from auth.uid(), whether the caller is the
// active Council Administrator — so the calls below are made as the
// caller, and an ordinary staff member gets nowhere with them.
// =====================================================================

import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders, errorResponse, jsonResponse } from "../_shared/http.ts";
import { handleManageStaffAccount, type StaffManagementPorts } from "./handler.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return errorResponse("Method not allowed.", 405);

  const authHeader = req.headers.get("Authorization") ?? "";
  if (!authHeader.toLowerCase().startsWith("bearer ")) {
    return errorResponse("You must be signed in.", 401);
  }

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return errorResponse("The request body could not be read.", 400);
  }

  // Acts as the caller: Row Level Security and auth.uid() apply.
  const callerClient = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const rpc = async (name: string, args: Record<string, unknown>) => {
    const { data, error } = await callerClient.rpc(name, args);
    if (error) return { error: { code: error.code, message: error.message } };
    return { data };
  };

  const ports: StaffManagementPorts = {
    async getCaller() {
      const { data, error } = await callerClient.auth.getUser();
      if (error || !data?.user) return null;
      return { id: data.user.id };
    },

    async callerIsActiveCouncilAdministrator() {
      const { data, error } = await callerClient.rpc("is_active_council_administrator");
      if (error) throw new Error(`Could not verify your permissions: ${error.message}`);
      return data === true;
    },

    changeStaffRole: (input) =>
      rpc("change_staff_role", { p_staff_id: input.staff_id, p_new_role_id: input.role_id }),

    deactivateStaffAccount: (input) =>
      rpc("deactivate_staff_account", { p_staff_id: input.staff_id, p_reason: input.reason }),

    reactivateStaffAccount: (input) =>
      rpc("reactivate_staff_account", { p_staff_id: input.staff_id, p_reason: input.reason }),
  };

  try {
    const result = await handleManageStaffAccount(payload, ports);
    return jsonResponse(result.body, result.status);
  } catch (caught) {
    const message = caught instanceof Error ? caught.message : "Unexpected error.";
    return errorResponse(message, 500);
  }
});
