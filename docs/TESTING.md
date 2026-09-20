# Testing

```bash
npm run test:all        # typecheck + edge function rules + database rules
```

## `npm test` — the edge function, import and lineage rules (91 tests)

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
  current marriage and the former one.

## `npm run test:db` — the database rules (322 tests)

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

Two suites, both of which read as a list of the rules themselves:

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
