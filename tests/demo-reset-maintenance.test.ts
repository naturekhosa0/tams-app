import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const reset = readFileSync(
  new URL("../supabase/maintenance/reset_for_demonstration.sql", import.meta.url),
  "utf8",
);
const preview = readFileSync(
  new URL("../supabase/maintenance/preview_demonstration_reset.sql", import.meta.url),
  "utf8",
);

const operationalTables = [
  "residents", "households", "family_relationships",
  "resident_account_requests", "resident_request_documents",
  "land_sites", "land_applications", "land_allocations", "ptos", "pto_renewal_requests",
  "council_meetings", "meeting_attendance", "meeting_minutes",
  "meeting_minutes_amendments", "council_resolutions", "community_projects",
  "project_milestones", "visibility_changes", "notifications",
  "notification_email_deliveries", "pto_expiry_warnings", "resident_communications",
  "resident_communication_recipients", "staff_messages", "staff_message_recipients",
  "audit_logs",
];

test("the demonstration reset is blocked until an explicit confirmation is edited", () => {
  assert.match(reset, /TYPE RESET TAMS FOR DEMONSTRATION/);
  assert.match(reset, /v_confirmation <> 'RESET TAMS FOR DEMONSTRATION'/);
});

test("the reset refuses to orphan uploaded verification files", () => {
  assert.match(reset, /from storage\.objects/);
  assert.match(reset, /Empty it through Supabase Storage/);
  assert.ok(!/delete from storage\.objects/i.test(reset));
  assert.ok(!/delete from storage\.buckets/i.test(reset));
});

test("every operational table is previewed and verified empty after reset", () => {
  for (const table of operationalTables) {
    assert.match(preview, new RegExp(`public\\.${table}\\b`), `${table} is missing from preview`);
    assert.match(reset, new RegExp(`public\\.${table}\\b`), `${table} is missing from reset`);
  }
});

test("the reset preserves exactly one active Council Administrator and Auth user", () => {
  assert.match(reset, /v_admin_count <> 1/);
  assert.match(reset, /delete from public\.user_accounts where id <> v_admin_account_id/);
  assert.match(reset, /delete from public\.staff where id <> v_admin_staff_id/);
  assert.match(reset, /delete from auth\.users where id <> v_admin_auth_user_id/);
  assert.match(reset, /ua\.account_status = 'active'/);
  assert.match(reset, /r\.role_name = 'Council Administrator'/);
});

test("seeded roles, schema and the Storage bucket are never deleted", () => {
  assert.ok(!/delete from public\.roles/i.test(reset));
  assert.ok(!/drop table/i.test(reset));
  assert.ok(!/delete from storage\.buckets/i.test(reset));
});

