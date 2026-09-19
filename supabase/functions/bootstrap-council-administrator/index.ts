// =====================================================================
// bootstrap-council-administrator — one-time creation of the first
// Council Administrator.
//
// Guarded three ways:
//   1. the caller must present the project's anon key (verify_jwt);
//   2. the caller must present the x-bootstrap-secret header, which is
//      only known to whoever configured the project;
//   3. the database refuses outright once a Council Administrator
//      exists, so the process cannot be used twice.
//
// There is deliberately no page in the application that reaches this.
// =====================================================================

import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders, errorResponse, jsonResponse, secretsMatch } from "../_shared/http.ts";
import { type BootstrapPorts, handleBootstrap } from "./handler.ts";

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

  const ports: BootstrapPorts = {
    configuredSecret: () => Deno.env.get("TAMS_BOOTSTRAP_SECRET") ?? null,
    secretsMatch,

    async findAuthUserByEmail(email) {
      // Paged scan of the auth users. The project has very few users at
      // bootstrap time, and this avoids depending on a private endpoint.
      for (let page = 1; page <= 20; page++) {
        const { data, error } = await adminClient.auth.admin.listUsers({ page, perPage: 200 });
        if (error) throw new Error(`Could not read the authentication users: ${error.message}`);
        const match = data.users.find((user) => (user.email ?? "").toLowerCase() === email);
        if (match) return { id: match.id };
        if (data.users.length < 200) break;
      }
      return null;
    },

    async bootstrapAdministrator(input) {
      const { data, error } = await adminClient.rpc("bootstrap_council_administrator", {
        p_auth_user_id: input.auth_user_id,
        p_employee_number: input.employee_number,
        p_first_name: input.first_name,
        p_last_name: input.last_name,
        p_email: input.email,
        p_contact_number: input.contact_number,
      });
      if (error) return { error: { code: error.code, message: error.message } };
      return { data };
    },
  };

  try {
    const result = await handleBootstrap(
      req.headers.get("x-bootstrap-secret"),
      payload,
      ports,
    );
    return jsonResponse(result.body, result.status);
  } catch (caught) {
    const message = caught instanceof Error ? caught.message : "Unexpected error.";
    return errorResponse(message, 500);
  }
});
