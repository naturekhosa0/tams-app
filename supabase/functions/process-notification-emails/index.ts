// =====================================================================
// process-notification-emails — sends the emails queued beside TAMS
// notifications.
//
// Runs on the server with the service key and a provider key, neither of
// which the browser ever sees. It is called on a schedule; calling it
// twice sends nothing twice, because a delivery that has been sent is
// never claimed again.
// =====================================================================

import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders, errorResponse, jsonResponse, secretsMatch } from "../_shared/http.ts";
import { runWorker, type SendResult, type WorkerPorts } from "./handler.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return errorResponse("Method not allowed.", 405);

  let payload: Record<string, unknown> = {};
  try {
    payload = await req.json();
  } catch {
    // An empty body is fine: the defaults are the normal case.
  }

  const adminClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const apiKey = Deno.env.get("BREVO_API_KEY") ?? "";
  const fromEmail = Deno.env.get("TAMS_EMAIL_FROM") ?? "";
  const fromName = Deno.env.get("TAMS_EMAIL_FROM_NAME") ?? "TAMS";
  const appUrl = Deno.env.get("TAMS_APP_URL") ?? "https://tams.example";

  const ports: WorkerPorts = {
    configuredSecret: () => Deno.env.get("TAMS_WORKER_SECRET") ?? null,
    secretsMatch,
    emailConfigured: () => apiKey.length > 0 && fromEmail.length > 0,

    async claimDeliveries(limit) {
      const { data, error } = await adminClient.rpc("claim_notification_emails", {
        p_limit: limit,
      });
      if (error) throw new Error(`The pending emails could not be read: ${error.message}`);
      return data ?? [];
    },

    async sendEmail(input): Promise<SendResult> {
      const response = await fetch("https://api.brevo.com/v3/smtp/email", {
        method: "POST",
        headers: {
          "api-key": apiKey,
          "content-type": "application/json",
          accept: "application/json",
        },
        body: JSON.stringify({
          sender: { email: fromEmail, name: fromName },
          to: [{ email: input.to }],
          subject: input.subject,
          textContent: input.text,
          htmlContent: input.html,
        }),
      });

      if (!response.ok) {
        // The provider's own words, kept short and never stored whole.
        const body = await response.text().catch(() => "");
        return { ok: false, error: `Provider returned ${response.status}: ${body.slice(0, 200)}` };
      }
      const body = await response.json().catch(() => ({} as Record<string, unknown>));
      return { ok: true, providerMessageId: (body as { messageId?: string }).messageId ?? null };
    },

    async markSent(deliveryId, providerMessageId) {
      await adminClient.rpc("mark_notification_email_sent", {
        p_delivery_id: deliveryId,
        p_provider_message_id: providerMessageId,
      });
    },

    async markFailed(deliveryId, error) {
      await adminClient.rpc("mark_notification_email_failed", {
        p_delivery_id: deliveryId,
        p_error: error,
      });
    },
  };

  try {
    const limit = Number(payload.limit ?? 25);
    const result = await runWorker(
      req.headers.get("x-worker-secret"),
      Number.isFinite(limit) ? limit : 25,
      appUrl,
      ports,
    );
    return jsonResponse(result.body, result.status);
  } catch (caught) {
    const message = caught instanceof Error ? caught.message : "Unexpected error.";
    return errorResponse(message, 500);
  }
});
