// =====================================================================
// The decisions the notification email worker makes, kept free of Deno
// and of any provider so they can be tested in Node.
//
// The rules are small but they matter:
//
//   * a delivery is attempted once per run, never twice;
//   * a send that already succeeded is never repeated;
//   * a failure is recorded, shortened, and stripped of anything the
//     provider might have echoed back;
//   * nothing here ever touches the business record the notification
//     was about.
// =====================================================================

export type PendingDelivery = {
  delivery_id: string;
  notification_id: string;
  recipient_email: string;
  title: string;
  message: string;
  link_path: string | null;
  notification_category: string;
  attempt_count: number;
};

export type SendResult =
  | { ok: true; providerMessageId?: string | null }
  | { ok: false; error: string };

export type WorkerPorts = {
  /** The shared secret configured on the server, or null when unset. */
  configuredSecret(): string | null;
  secretsMatch(a: string, b: string): boolean;
  /** True once the provider has everything it needs to send. */
  emailConfigured(): boolean;
  /** Claims a batch; the database records the attempt as it hands them over. */
  claimDeliveries(limit: number): Promise<PendingDelivery[]>;
  sendEmail(input: {
    to: string;
    subject: string;
    text: string;
    html: string;
  }): Promise<SendResult>;
  markSent(deliveryId: string, providerMessageId: string | null): Promise<void>;
  markFailed(deliveryId: string, error: string): Promise<void>;
};

export type WorkerResult = {
  status: number;
  body: {
    claimed?: number;
    sent?: number;
    failed?: number;
    message?: string;
    error?: { message: string };
  };
};

const fail = (status: number, message: string): WorkerResult => ({
  status,
  body: { error: { message } },
});

/** Everything a provider says is untrusted text. Keep it short and flat. */
export function safeError(caught: unknown): string {
  const raw = caught instanceof Error ? caught.message : String(caught ?? "Unknown error");
  return raw.replace(/\s+/g, " ").trim().slice(0, 300) || "Unknown error";
}

/** The email a notification becomes. Deliberately thin. */
export function composeEmail(
  delivery: PendingDelivery,
  appUrl: string,
): { subject: string; text: string; html: string } {
  const base = appUrl.replace(/\/+$/, "");
  const link = delivery.link_path ? `${base}${delivery.link_path}` : base;

  const text = [
    delivery.title,
    "",
    delivery.message,
    "",
    `Open TAMS: ${link}`,
    "",
    "This is an automatic message from the Traditional Authority Management System.",
    "Please do not reply to it.",
  ].join("\n");

  const html = [
    `<p style="font-size:16px;font-weight:600;margin:0 0 12px">${escapeHtml(delivery.title)}</p>`,
    `<p style="white-space:pre-wrap;margin:0 0 18px">${escapeHtml(delivery.message)}</p>`,
    `<p style="margin:0 0 18px"><a href="${escapeHtml(link)}">Open TAMS</a></p>`,
    `<p style="color:#7c7c99;font-size:12px;margin:0">This is an automatic message from the `,
    `Traditional Authority Management System. Please do not reply to it.</p>`,
  ].join("");

  return { subject: delivery.title, text, html };
}

export function escapeHtml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

export async function runWorker(
  suppliedSecret: string | null,
  limit: number,
  appUrl: string,
  ports: WorkerPorts,
): Promise<WorkerResult> {
  const expected = ports.configuredSecret();
  if (!expected) {
    return fail(503, "The email worker is not enabled. Set TAMS_WORKER_SECRET on the server first.");
  }
  if (!suppliedSecret || !ports.secretsMatch(suppliedSecret, expected)) {
    return fail(403, "The worker secret is missing or incorrect.");
  }
  if (!ports.emailConfigured()) {
    return fail(
      503,
      "Email is not configured. Set BREVO_API_KEY and TAMS_EMAIL_FROM on the server first.",
    );
  }

  const deliveries = await ports.claimDeliveries(limit);
  let sent = 0;
  let failed = 0;

  for (const delivery of deliveries) {
    const email = composeEmail(delivery, appUrl);
    let result: SendResult;
    try {
      result = await ports.sendEmail({
        to: delivery.recipient_email,
        subject: email.subject,
        text: email.text,
        html: email.html,
      });
    } catch (caught) {
      result = { ok: false, error: safeError(caught) };
    }

    // A failure on one delivery must never stop the rest of the batch,
    // and must never reach back into the record the notification was
    // about. It is recorded here and nowhere else.
    if (result.ok) {
      await ports.markSent(delivery.delivery_id, result.providerMessageId ?? null);
      sent += 1;
    } else {
      await ports.markFailed(delivery.delivery_id, safeError(result.error));
      failed += 1;
    }
  }

  return {
    status: 200,
    body: { claimed: deliveries.length, sent, failed },
  };
}
