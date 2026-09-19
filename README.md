# TAMS — Traditional Authority Management System

The foundation of the system: staff roles, staff accounts and signing in.
Built with React, Vite, Supabase (PostgreSQL, Supabase Auth and Row Level
Security).

This is step one. Registry Clerk, Land Officer, Council Secretary,
resident, land, PTO, meeting, project and audit work are **not** built
yet — only what those later functions will stand on.

## What works today

| | |
| --- | --- |
| **First Council Administrator** | A one-time, secret-guarded server process. No registration page exists. |
| **Sign in** | One page for every role, checked against the database record, not the browser. |
| **Create Staff Account** | The Council Administrator invites a Registry Clerk, Land Officer or Council Secretary. |
| **Invitation** | The new staff member gets an email and chooses their own password. |
| **Staff sign-in** | All three roles can sign in and see their own account page. |

## Getting started

```bash
npm install
cp .env.example .env     # your Supabase URL and anon key
npm run dev
```

The full walkthrough, including the first administrator, is in
[docs/SETUP.md](docs/SETUP.md).

## The database

Three tables, and nothing that is not needed yet.

```
roles ───< staff ───< user_accounts >─── auth.users
```

* **roles** — the four roles, seeded by the migration: Registry Clerk,
  Land Officer, Council Secretary, Council Administrator.
* **staff** — the person and their *one* role (`staff.role_id`).
* **user_accounts** — the sign-in account. For staff,
  `account_status` (`active` / `deactivated`) is the single source of
  truth for whether they may use the system.

`user_accounts.resident_id` is reserved for a later function and is
unused.

## How it is kept safe

* **The browser holds no secrets and makes no writes.** Only the `anon`
  key is used there, and it can reach only what Row Level Security
  allows.
* **Row Level Security is on for all three tables**, with no insert,
  update or delete policy at all. Every write goes through a
  `security definer` function that only `service_role` may execute.
* **Roles are never trusted from the browser.** Every protected
  operation re-reads, from the database, that the caller has an active
  staff account and what role that account currently holds.
* **The Council Administrator role cannot be handed out.** It is absent
  from the dropdown, refused by the edge function, refused by the
  database function, and a database trigger refuses a second
  administrator however the row is inserted.
* **No half-created people.** The staff record and the user account are
  written in one transaction, and the invited auth user is deleted again
  if that transaction fails.

## Layout

```
src/                      React app (pages, session, guards)
supabase/migrations/      the one foundation migration
supabase/functions/       bootstrap-council-administrator, create-staff-account
supabase/tests/           database test suite (runs on plain PostgreSQL)
tests/                    edge function rule tests
scripts/                  one-time administrator bootstrap
docs/                     SETUP.md, TESTING.md
```

## Tests

```bash
npm run test:all
```

92 automated checks: see [docs/TESTING.md](docs/TESTING.md).
