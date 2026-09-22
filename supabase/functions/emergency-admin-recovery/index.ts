// =====================================================================
// emergency-admin-recovery — the way back in when TAMS has no Council
// Administrator anybody can sign in as.
//
// Guarded the same way the first-administrator bootstrap is: a secret
// only the person who configured the project knows, compared in
// constant time, plus a database that refuses outright the moment a
// healthy administrator exists.
//
// The secret is never written anywhere. It does not reach the database,
// and it does not appear in the audit record the recovery leaves behind.
// =====================================================================

import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders, errorResponse, jsonResponse, secretsMatch } from "../_shared/http.ts";
import { handleRecovery, type RecoveryPorts } from "./handler.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return errorResponse("Method not allowed.", 405);

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return errorResponse("The request body could not be read.", 400);
  }

  const adminClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const ports: RecoveryPorts = {
    configuredSecret: () => Deno.env.get("TAMS_ADMIN_RECOVERY_SECRET") ?? null,
    secretsMatch,

    async administratorHealth() {
      const { data, error } = await adminClient.rpc("administrator_health");
      if (error) throw new Error(`The administrator situation could not be read: ${error.message}`);
      return data as { active_administrators: number; valid_administrators: number };
    },

    async listCandidates() {
      const { data, error } = await adminClient.rpc("emergency_recovery_candidates");
      if (error) throw new Error(`The eligible staff could not be read: ${error.message}`);
      return data ?? [];
    },

    async promote(input) {
      const { data, error } = await adminClient.rpc("emergency_promote_administrator", {
        p_staff_id: input.staff_id,
        p_reason: input.reason,
      });
      if (error) return { error: { code: error.code, message: error.message } };
      return { data };
    },
  };

  try {
    const result = await handleRecovery(
      req.headers.get("x-recovery-secret"),
      payload,
      ports,
    );
    return jsonResponse(result.body, result.status);
  } catch (caught) {
    const message = caught instanceof Error ? caught.message : "Unexpected error.";
    return errorResponse(message, 500);
  }
});
