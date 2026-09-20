# TAMS — Traditional Authority Management System

The foundation of the system: staff roles, staff accounts and signing in.
Built with React, Vite, Supabase (PostgreSQL, Supabase Auth and Row Level
Security).

The foundation, plus the Council Administrator's staff management.
Registry Clerk, Land Officer, Council Secretary, resident, land, PTO,
meeting, project and audit work are **not** built yet — only what those
later functions will stand on.

## What works today

| | |
| --- | --- |
| **First Council Administrator** | A one-time, secret-guarded server process. No registration page exists. |
| **Sign in** | One page for every role, checked against the database record, not the browser. |
| **Create Staff Account** | The Council Administrator invites a Registry Clerk, Land Officer or Council Secretary. |
| **Invitation** | The new staff member gets an email and chooses their own password. |
| **Staff sign-in** | All three roles can sign in and see their own account page. |
| **Change staff role** | The Council Administrator moves a staff member to a different one of the three ordinary roles. |
| **Deactivate / reactivate** | Access is withdrawn and given back, with a reason, without deleting anything. |

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
* **staff** — the person and their *one* role (`staff.role_id`), plus
  when they were last deactivated or reactivated, by whom and why.
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
* **The Council Administrator role cannot be handed out**, and the
  Council Administrator's own account cannot be changed, deactivated or
  reactivated from the staff pages. Each of those is refused by the edge
  function *and* by the database function, and a database trigger
  refuses a second administrator however the row is inserted.
* **Access can be withdrawn at once.** `account_status` is checked on
  every protected read and every privileged operation, so a staff member
  who is deactivated mid-session can do nothing further with the session
  they already have.
* **No half-created people.** The staff record and the user account are
  written in one transaction, and the invited auth user is deleted again
  if that transaction fails.

## Layout

```
src/                      React app (pages, session, guards)
supabase/migrations/      the foundation, then staff management
supabase/functions/       bootstrap-council-administrator, create-staff-account,
                          manage-staff-account
supabase/tests/           database test suite (runs on plain PostgreSQL)
tests/                    edge function rule tests
scripts/                  one-time administrator bootstrap
docs/                     SETUP.md, TESTING.md
```

## Tests

```bash
npm run test:all
```

166 automated checks: see [docs/TESTING.md](docs/TESTING.md).
