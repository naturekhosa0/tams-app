// =====================================================================
// create-staff-account — the only way a staff account is created.
//
// This file is wiring only: it turns an HTTP request into the ports
// that handler.ts expects. The rules live in handler.ts.
//
// The service role key is read here and nowhere else in the project —
// it never reaches the browser.
// =====================================================================

import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders, errorResponse, jsonResponse } from "../_shared/http.ts";
import { handleCreateStaffAccount, type StaffCreationPorts } from "./handler.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

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

  // Full rights. Only used for work the caller has already been
  // authorised for by the database.
  const adminClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const siteUrl = Deno.env.get("TAMS_SITE_URL") ?? req.headers.get("origin") ?? "";
  const redirectTo = siteUrl ? `${siteUrl.replace(/\/$/, "")}/set-password` : undefined;

  const ports: StaffCreationPorts = {
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

    async findRoleById(roleId) {
      const { data, error } = await adminClient
        .from("roles").select("id, role_name").eq("id", roleId).maybeSingle();
      if (error) throw new Error(`Could not read the roles list: ${error.message}`);
      return data ?? null;
    },

    async employeeNumberTaken(employeeNumber) {
      // An exact match, so nothing in the employee number can act as a
      // pattern. A difference of case is caught by the unique index and
      // handled as a rollback below.
      const { data, error } = await adminClient
        .from("staff").select("id").eq("employee_number", employeeNumber).maybeSingle();
      if (error) throw new Error(error.message);
      return data !== null;
    },

    async staffEmailTaken(email) {
      const { data, error } = await adminClient
        .from("staff").select("id").eq("email", email).maybeSingle();
      if (error) throw new Error(error.message);
      return data !== null;
    },

    async inviteUser(email, details) {
      const { data, error } = await adminClient.auth.admin.inviteUserByEmail(email, {
        redirectTo,
        data: details,
      });
      if (error || !data?.user) {
        return { error: { message: error?.message ?? "The invitation was not accepted by Supabase Auth." } };
      }
      return { userId: data.user.id };
    },

    async deleteAuthUser(userId) {
      const { error } = await adminClient.auth.admin.deleteUser(userId);
      if (error) throw new Error(error.message);
    },

    async createStaffWithAccount(input) {
      const { data, error } = await adminClient.rpc("create_staff_with_account", {
        p_auth_user_id: input.auth_user_id,
        p_employee_number: input.employee_number,
        p_first_name: input.first_name,
        p_last_name: input.last_name,
        p_email: input.email,
        p_contact_number: input.contact_number,
        p_role_id: input.role_id,
      });
      if (error) return { error: { code: error.code, message: error.message } };
      return { data };
    },
  };

  try {
    const result = await handleCreateStaffAccount(payload, ports);
    return jsonResponse(result.body, result.status);
  } catch (caught) {
    const message = caught instanceof Error ? caught.message : "Unexpected error.";
    return errorResponse(message, 500);
  }
});
