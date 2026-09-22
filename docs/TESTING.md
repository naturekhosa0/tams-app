# Testing

```bash
npm run test:all        # typecheck + edge function rules + database rules
```

## `npm test` — the edge function, worker, navigation and import rules (152 tests)

Each edge function keeps its decisions in a `handler.ts` that takes
everything it needs through a small set of ports, so the rules can be
run without Deno or a Supabase project. `tests/` covers:

* only the active Council Administrator may create staff;
* a Council Administrator role id submitted by hand is refused, and no
  invitation is sent;
* required fields, email format and contact number format;
* details are trimmed and email addresses lower-cased before use;
* duplicate employee numbers and email addresses;
* **rollback**: when the staff record cannot be written, the invited auth
  user is deleted again, so no auth user survives without its records;
* the bootstrap secret: unset, wrong, missing;
* the bootstrap refusing a second Council Administrator;
* for staff management: who may change a role, deactivate or reactivate,
  a reason being required and trimmed, and every refusal the database
  can raise being turned into wording an administrator can act on;
* the CSV reader — byte order marks, quoted values containing commas and
  newlines, CRLF, short rows, unterminated quotes;
* the legacy import payload: the supplied files read as expected, every
  code they refer to exists, and columns with no home in the database
  are reported rather than dropped;
* which way round a family relationship reads — a stored `parent` row
  means the people listed are that resident's *children*, and showing it
  the other way round would file someone's grandchildren under
  "Grandparents";
* which relationships are permanent and which are episodes, so that
  lineage is never offered an ending and a remarriage shows both the
  current marriage and the former one;
* the notification email worker — a queued notification is sent once and
  once only, a second run sends nothing again, a provider failure is
  recorded and the batch carries on, a provider that throws does not stop
  it, the shared secret is required, an unconfigured provider refuses to
  send, provider errors are shortened and flattened before storage, and
  anything in a title or message is escaped before it becomes HTML;
* emergency administrator recovery — it refuses while a healthy
  administrator exists, refuses without the secret, is off entirely until
  the secret is configured, lists eligible staff without changing
  anything, requires both a person and a reason, and never echoes the
  secret back;
* navigation — where each role's home is, what each role is offered,
  that no role is offered another role's area, and that every navigation
  link and every role's home is a route the application actually serves;
* forgetting a password — the shared password rules, the answer that
  never says whether an address has an account, the redirect address
  being configured or the browser's own rather than hard-coded, the
  problem Supabase reports about a stale link being read out of it, the
  reset making exactly three calls and mentioning no TAMS table, the
  audit event carrying no values at all, and the invitation and
  registration flows being untouched.

## `npm run test:db` — the database rules (708 tests)

Runs the real migration against a throwaway local PostgreSQL database.
`supabase/tests/00_local_auth_stub.sql` stands in for the parts Supabase
supplies (the `auth` schema, `auth.uid()`, and the `anon`,
`authenticated` and `service_role` roles); everything else is the
migration exactly as it is deployed.

It needs a local PostgreSQL server and the `postgres` superuser:

```bash
pg_ctlcluster 16 main start     # Debian/Ubuntu
npm run test:db
```

Each suite reads as a list of the rules themselves:

* `02_foundation_tests.sql` — the first administrator bootstrap, staff
  creation and everything it refuses, Row Level Security for
  administrators, ordinary staff and signed-out visitors, and
  `account_status` as the single source of truth for access.
* `03_staff_management_tests.sql` — changing a role, deactivating and
  reactivating: each rule, each refusal, and proof that a change of role
  or status leaves the staff record, the user account and the Auth
  identity otherwise untouched.
* `05_registry_clerk_tests.sql` — searching and viewing the register,
  creating and updating residents, creating households, linking
  residents, designating heads, recording relationships and their
  inverses, and who may do any of it: a Land Officer, a Council
  Secretary, the Council Administrator, a signed-out visitor and a
  deactivated Registry Clerk are each turned away.
* `06_relationship_history_tests.sql` — permanent lineage refusing to be
  ended, marriages and guardianships ending on both sides, a remarriage
  becoming a new episode while the first stays on record, and the 200
  imported relationships untouched.
* `07_resident_accounts_tests.sql` — registration, documents, one
  pending request at a time, the Registry Clerk's review, approval,
  decline, and reapplying with the same account and the same sign-in.
* `08_land_tests.sql` — land. Grazing refused as a kind of land, the
  four that are allowed, who counts as a Land Officer, the 21 rule at
  exactly 21 and one day short, applying without ever choosing a site,
  approval and decline with a reason, allocation in one transaction, the
  same site refused twice, one residential stand per person, one
  business site per person, one farming site per household, a burial
  plot only when every plot the household holds is full, a full plot
  staying with its household for ever, perpetual permissions with a null
  expiry rather than a pretend date, farming at five years and business
  at two to the day, expiry read from the date rather than a scheduler,
  renewal writing a new permission and keeping the old one, revocation
  with a reason, release freeing the site, succession waiting rather
  than freeing a stand, TAMS naming no heir, returning land to the
  Authority, QR verification showing no identity number or birth date,
  and a resident being refused every officer function there is.
* `09_council_secretary_tests.sql` — the council record. Who counts as a
  Council Secretary and who is turned away (a resident, a Registry
  Clerk, a Land Officer, the Council Administrator, a signed-out
  visitor, and a Secretary whose account was deactivated); the three
  kinds of meeting and the refusal of a fourth; unique references; the
  two status moves allowed and every one that is not; cancellation
  needing a reason and the meeting surviving it; attendance needing no
  account of any kind and closing when the minutes go final; one
  minutes record per meeting; a draft being edited; finalisation
  recording who and when; final minutes refusing to be edited or
  deleted; amendments being refused on a draft, required to carry a
  reason, and leaving the original word for word; several resolutions
  from one meeting; withdrawal needing a reason; an internal resolution
  and a public one from unconfirmed minutes both being invisible to a
  resident; public → internal needing a reason and leaving a history
  row; projects with and without a resolution; a backwards date order
  refused; a public project linked to an internal resolution leaking
  none of it; milestones through pending, in progress and completed;
  overdue being worked out from the date and refusing to be stored or
  chosen; and a resident's direct queries against the tables returning
  exactly the same narrow answer the function gives them.
* `10_notifications_audit_admin_tests.sql` — notifications and their
  emails, official communications, staff messaging and work requests,
  the audit trail, Administrator Transfer and emergency recovery. A
  recipient sees their own notifications and nobody else's; the unread
  count, marking read and archiving all work and none of them can change
  what a notification says; every notification queues exactly one email;
  the worker claims a batch once and never re-claims it; a failed email
  leaves the permission, the allocation and the notification exactly
  where they were. Expiry warnings fire at sixty, thirty and seven days
  for farming and business only, once each, never for the perpetual
  kinds. A summons reaches the one resident it names and nobody else; a
  selection reaches exactly the selection; a broadcast snapshots who was
  active at that moment, so somebody verified afterwards is not a
  recipient. Staff messaging refuses residents and deactivated staff,
  snapshots role recipients, keeps sent messages unaltered, and proves a
  linked record grants no permission. A role work request is claimed by
  the first to acknowledge it and resolved only by them. The audit
  records old and new values with the real actor, cannot be updated or
  deleted by anybody including the service key and the database owner,
  holds no password, token, key, document path or private message body,
  and is readable by the Council Administrator alone. The administrator
  role is transferred three times over with each ordinary outcome and
  once with deactivation, always leaving exactly one active
  administrator, and emergency recovery refuses until there is none and
  refuses again once there is one.
* `11_password_reset_tests.sql` — the boundary around a password
  change. Every account in the system changes its password at once, and
  every field of `user_accounts`, every resident's household and status
  and every staff member's role are then proved to be exactly what they
  were; a deactivated clerk with a new password is still refused
  everywhere; there is no trigger of ours on the table Supabase keeps
  passwords in, so all those resets wrote no audit between them; the one
  line the reset page can ask for names the caller's own account and
  holds no values at all; the function takes no parameters, so nothing
  can be claimed; and no audited field anywhere in the trail is even
  named like a password or a token.
* `04_legacy_import_tests.sql` — the legacy import. Every validation is
  given a dataset that breaks exactly one rule, and each one must write
  nothing at all; then the real CSV package is imported through the same
  builder the real command uses; then the database's own constraints are
  tried against the imported data, and Row Level Security is checked to
  be refusing everyone.

## What still needs a Supabase project

Supabase Auth itself — sending the invitation email, the link in it, and
`updateUser({ password })` — cannot be exercised here. The checklist at
the end of [SETUP.md](SETUP.md) walks through those against your own
project.
