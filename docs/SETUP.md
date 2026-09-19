# Setting TAMS up

Everything below is done once, in order. It takes about fifteen minutes.

## 1. A Supabase project

Create a project at <https://supabase.com/dashboard>, then note from
**Project Settings → API**:

| Value | Where it goes |
| --- | --- |
| Project URL | `.env` as `VITE_SUPABASE_URL` |
| `anon` public key | `.env` as `VITE_SUPABASE_ANON_KEY` |
| `service_role` secret key | **nowhere in this repository** — Supabase gives it to the edge functions automatically |

```bash
cp .env.example .env     # then fill in the two values
npm install
```

## 2. The database

```bash
npx supabase link --project-ref <your-project-ref>
npm run db:push
```

That applies `supabase/migrations/20260919090000_tams_foundation.sql`,
which creates the three tables, seeds the four roles, and turns on Row
Level Security.

## 3. Sign-in settings

In **Authentication → Providers → Email**, turn **off** "Enable sign-ups".
Staff accounts are only ever created by the Council Administrator, so
there must be no public sign-up.

In **Authentication → URL Configuration**, set the **Site URL** to where
the app runs (`http://localhost:5173` while developing) and add
`<site-url>/set-password` to the **Redirect URLs**. That is where
invitation emails land.

While developing, Supabase's built-in email service only delivers to a
small number of addresses per hour. For real use, set up SMTP under
**Project Settings → Authentication → SMTP Settings**.

Invitation links land on `/set-password`, a route inside the app. When
you host TAMS somewhere, make sure unknown paths serve `index.html`
(Netlify `_redirects`, Vercel rewrites, or `try_files` on nginx) or that
link will 404. `npm run dev` already does this.

## 4. The edge functions

```bash
npx supabase secrets set TAMS_SITE_URL="http://localhost:5173"
npx supabase secrets set TAMS_BOOTSTRAP_SECRET="$(openssl rand -hex 32)"
npm run functions:deploy
```

`TAMS_SITE_URL` is the address invitation links come back to.
`TAMS_BOOTSTRAP_SECRET` is used once, in the next step.

## 5. The first Council Administrator

There is no registration page for this, by design. Two steps:

**a. Create the sign-in user by hand.** Dashboard →
**Authentication → Users → Add user**: their email address, a password
you give them, and **Auto Confirm User** ticked.

**b. Run the bootstrap once:**

```bash
export SUPABASE_URL="https://<your-ref>.supabase.co"
export SUPABASE_ANON_KEY="<anon key>"
export TAMS_BOOTSTRAP_SECRET="<the same secret you set above>"

./scripts/bootstrap-administrator.sh 2026011 Nature Khosa admin@example.com 0728217377
```

This creates their staff record with the Council Administrator role and
their active user account, in one transaction. Run it again and it
refuses: a Council Administrator already exists.

**c. Shut the door:**

```bash
npx supabase secrets unset TAMS_BOOTSTRAP_SECRET
```

## 6. Run it

```bash
npm run dev
```

Sign in at <http://localhost:5173> with the administrator's email and the
password you set in step 5a.

---

## Checking it end to end

These are the checks to run against your own project once it is set up.
The parts that can be tested without a Supabase project are automated —
see [TESTING.md](TESTING.md) — and `npm run test:all` runs them.

| # | Check | Expected |
| --- | --- | --- |
| 1 | Run the bootstrap (step 5) | Staff record + active account, role Council Administrator |
| 2 | Run the bootstrap a second time | Refused: "A Council Administrator already exists" |
| 3 | Sign in as the administrator | Lands on the dashboard |
| 4 | Create a Registry Clerk | "An invitation has been emailed to …" |
| 5 | Open the invitation email | Lands on `/set-password` |
| 6 | Set a password under 8 characters | Refused |
| 7 | Set two passwords that differ | Refused |
| 8 | Set a valid password | "Your account is ready" |
| 9 | Sign in as the Registry Clerk | Lands on their account page with name, employee number, email, role, status |
| 10 | Repeat 4–9 for a Land Officer and a Council Secretary | Same |
| 11 | Create staff with an employee number already in use | Refused on that field; no invitation sent |
| 12 | Create staff with an email already in use | Refused on that field; no invitation sent |
| 13 | As a Registry Clerk, open `/staff/new` | Sent back to their own account page |
| 14 | As a Registry Clerk, POST to the `create-staff-account` function | `403` |
| 15 | Set someone's `account_status` to `deactivated`, then sign in as them | "Your staff account has been deactivated" |

For 14, from a signed-in Registry Clerk's browser console:

```js
const { data: { session } } = await supabase.auth.getSession();
await fetch(`${SUPABASE_URL}/functions/v1/create-staff-account`, {
  method: "POST",
  headers: {
    "Content-Type": "application/json",
    apikey: ANON_KEY,
    Authorization: `Bearer ${session.access_token}`,
  },
  body: JSON.stringify({
    employee_number: "9999", first_name: "Not", last_name: "Allowed",
    email: "not-allowed@example.com", contact_number: "0728217377",
    role_id: "<any role id>",
  }),
}).then((response) => response.status);   // 403
```
