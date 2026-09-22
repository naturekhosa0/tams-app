// Tests for the notification email worker's rules.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  composeEmail,
  type PendingDelivery,
  runWorker,
  safeError,
  type SendResult,
  type WorkerPorts,
} from "../supabase/functions/process-notification-emails/handler.ts";

const SECRET = "a-long-random-worker-secret";
const APP_URL = "https://tams.example";

function delivery(overrides: Partial<PendingDelivery> = {}): PendingDelivery {
  return {
    delivery_id: "delivery-1",
    notification_id: "notification-1",
    recipient_email: "resident@village.example",
    title: "Land application APP-0007 has been approved",
    message: "Your residential land application has been approved.",
    link_path: "/resident",
    notification_category: "land_application",
    attempt_count: 0,
    ...overrides,
  };
}

type Calls = { sent: string[]; failed: [string, string][]; emails: { to: string }[] };

function makePorts(
  queue: PendingDelivery[],
  send: (input: { to: string }) => Promise<SendResult>,
  overrides: Partial<WorkerPorts> = {},
): WorkerPorts & { calls: Calls } {
  const calls: Calls = { sent: [], failed: [], emails: [] };
  // The real claim happens in the database and hands each row over once.
  let handedOver = false;

  return {
    calls,
    configuredSecret: () => SECRET,
    secretsMatch: (a, b) => a === b,
    emailConfigured: () => true,
    claimDeliveries: async () => {
      if (handedOver) return [];
      handedOver = true;
      return queue;
    },
    sendEmail: async (input) => {
      calls.emails.push({ to: input.to });
      return send(input);
    },
    markSent: async (id) => { calls.sent.push(id); },
    markFailed: async (id, error) => { calls.failed.push([id, error]); },
    ...overrides,
  };
}

test("a queued notification is emailed and marked sent", async () => {
  const ports = makePorts([delivery()], async () => ({ ok: true, providerMessageId: "msg-1" }));
  const result = await runWorker(SECRET, 25, APP_URL, ports);

  assert.equal(result.status, 200);
  assert.deepEqual(result.body, { claimed: 1, sent: 1, failed: 0 });
  assert.deepEqual(ports.calls.sent, ["delivery-1"]);
  assert.deepEqual(ports.calls.failed, []);
});

test("a second run of the worker sends nothing again", async () => {
  const ports = makePorts([delivery()], async () => ({ ok: true }));
  await runWorker(SECRET, 25, APP_URL, ports);
  const second = await runWorker(SECRET, 25, APP_URL, ports);

  assert.deepEqual(second.body, { claimed: 0, sent: 0, failed: 0 });
  assert.equal(ports.calls.emails.length, 1, "the same delivery must not be emailed twice");
});

test("a provider failure is recorded and the batch carries on", async () => {
  const ports = makePorts(
    [delivery({ delivery_id: "a" }), delivery({ delivery_id: "b" })],
    async (input) =>
      input.to === "resident@village.example" && ports.calls.emails.length === 1
        ? { ok: false, error: "Provider returned 500" }
        : { ok: true },
  );
  const result = await runWorker(SECRET, 25, APP_URL, ports);

  assert.equal(result.status, 200);
  assert.equal(result.body.claimed, 2);
  assert.equal(result.body.sent, 1);
  assert.equal(result.body.failed, 1);
  assert.equal(ports.calls.failed[0][0], "a");
});

test("a provider that throws does not stop the worker", async () => {
  const ports = makePorts([delivery()], async () => {
    throw new Error("connect ETIMEDOUT api.brevo.com:443");
  });
  const result = await runWorker(SECRET, 25, APP_URL, ports);

  assert.equal(result.status, 200);
  assert.equal(result.body.failed, 1);
  assert.match(ports.calls.failed[0][1], /ETIMEDOUT/);
});

test("the worker refuses without the shared secret", async () => {
  const ports = makePorts([delivery()], async () => ({ ok: true }));
  assert.equal((await runWorker(null, 25, APP_URL, ports)).status, 403);
  assert.equal((await runWorker("wrong-secret", 25, APP_URL, ports)).status, 403);
  assert.equal(ports.calls.emails.length, 0, "nothing may be sent without the secret");
});

test("the worker refuses when the secret is not configured at all", async () => {
  const ports = makePorts([delivery()], async () => ({ ok: true }), {
    configuredSecret: () => null,
  });
  assert.equal((await runWorker(SECRET, 25, APP_URL, ports)).status, 503);
});

test("the worker refuses when the email provider is not configured", async () => {
  const ports = makePorts([delivery()], async () => ({ ok: true }), {
    emailConfigured: () => false,
  });
  const result = await runWorker(SECRET, 25, APP_URL, ports);
  assert.equal(result.status, 503);
  assert.match(result.body.error!.message, /BREVO_API_KEY/);
  assert.equal(ports.calls.emails.length, 0);
});

test("an error from a provider is shortened and flattened before it is stored", () => {
  const long = "x".repeat(900);
  const stored = safeError(new Error(`line one\n\tline two ${long}`));
  assert.ok(stored.length <= 300);
  assert.ok(!stored.includes("\n"));
  assert.ok(stored.startsWith("line one line two"));
});

test("the email carries the notification and a link back into TAMS", () => {
  const email = composeEmail(delivery(), APP_URL);
  assert.equal(email.subject, "Land application APP-0007 has been approved");
  assert.ok(email.text.includes("Your residential land application has been approved."));
  assert.ok(email.text.includes("https://tams.example/resident"));
  assert.ok(email.html.includes("https://tams.example/resident"));
});

test("a notification with no link still points at the application", () => {
  const email = composeEmail(delivery({ link_path: null }), "https://tams.example/");
  assert.ok(email.text.includes("Open TAMS: https://tams.example"));
});

test("anything in a title or message is escaped before it becomes html", () => {
  const email = composeEmail(
    delivery({ title: 'Notice <script>alert("x")</script>', message: "a & b" }),
    APP_URL,
  );
  assert.ok(!email.html.includes("<script>"));
  assert.ok(email.html.includes("&lt;script&gt;"));
  assert.ok(email.html.includes("a &amp; b"));
});
