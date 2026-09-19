# Testing

```bash
npm run test:all        # typecheck + edge function rules + database rules
```

## `npm test` — the edge function rules (30 tests)

The two edge functions keep their decisions in `handler.ts` files that
take everything they need through a small set of ports, so the rules can
be run without Deno or a Supabase project. `tests/` covers:

* only the active Council Administrator may create staff;
* a Council Administrator role id submitted by hand is refused, and no
  invitation is sent;
* required fields, email format and contact number format;
* details are trimmed and email addresses lower-cased before use;
* duplicate employee numbers and email addresses;
* **rollback**: when the staff record cannot be written, the invited auth
  user is deleted again, so no auth user survives without its records;
* the bootstrap secret: unset, wrong, missing;
* the bootstrap refusing a second Council Administrator.

## `npm run test:db` — the database rules (62 tests)

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

The suite covers the first administrator bootstrap, staff creation and
everything it refuses, Row Level Security for administrators, ordinary
staff and signed-out visitors, and `account_status` as the single source
of truth for access. `supabase/tests/02_foundation_tests.sql` reads as a
list of the rules themselves.

## What still needs a Supabase project

Supabase Auth itself — sending the invitation email, the link in it, and
`updateUser({ password })` — cannot be exercised here. The checklist at
the end of [SETUP.md](SETUP.md) walks through those against your own
project.
