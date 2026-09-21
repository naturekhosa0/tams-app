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

That applies both migrations:

* `20260919090000_tams_foundation.sql` — the three tables, the four
  seeded roles, and Row Level Security.
* `20260920100000_staff_role_and_status_management.sql` — the columns
  recording who deactivated or reactivated an account, when and why,
  and the three staff management functions.
* `20260921090000_village_records.sql` — the village's own records
  (land sites, residents, households, family relationships, land
  allocations) and the one-time legacy import.
* `20260922090000_registry_clerk.sql` — the Registry Clerk's read
  access and the functions behind every change they make.
* `20260923090000_relationship_history.sql` — when a relationship began
  and ended, and the change from one relationship per pair to one
  *current* relationship per pair.
* `20260924090000_resident_accounts.sql` — resident accounts,
  verification requests, their documents, and the private storage
  bucket the documents live in.

If a page reports that a function is "not found in the schema cache", a
migration has not reached the project yet — run
`scripts/check-registry-functions.sql` in the SQL Editor to see which.

`db:push` applies only the migrations your project has not seen yet.

Once the database is up, the village's existing records are loaded with
a one-time command — see [LEGACY-IMPORT.md](LEGACY-IMPORT.md).

## 3. Sign-in settings

In **Authentication → Providers → Email**, leave **Enable sign-ups**
**on** and turn **Confirm email** on. Residents create their own
sign-ins and confirm their address; that only ever produces a resident
account, pending verification, with no access to anything. Staff
accounts are still created solely by the Council Administrator's
invitation, and nothing a member of the public can do produces one.

In **Authentication → URL Configuration**, set the **Site URL** to where
the app runs (`http://localhost:5173` while developing) and add
`<site-url>/set-password` to the **Redirect URLs**. That is where
invitation emails land.

### Email delivery — set this up before creating any staff

**Staff creation fails without it.** Supabase's built-in email service is
for demonstration only: it is heavily rate limited and it refuses
addresses that do not belong to your own Supabase team. Inviting anyone
else comes back as:

> The invitation email could not be sent, so no staff account was
> created.

Nothing is created when that happens, so it is safe to fix the mail
settings and create the account again.

Set up your own SMTP server under **Project Settings → Authentication →
SMTP Settings**. Any provider works. Two that need no domain of your own:

**Brevo** (300 emails a day, free) — sign up, verify the sender address
you want mail to come from (your own Gmail address is fine), then under
**SMTP & API → SMTP** take:

| Field | Value |
| --- | --- |
| Host | `smtp-relay.brevo.com` |
| Port | `587` |
| Username | the login Brevo shows you |
| Password | the SMTP key Brevo generates |
| Sender email | the address you verified |
| Sender name | e.g. `TAMS` |

**Gmail** — in your Google account, turn on 2-Step Verification, create an
**App password**, then use host `smtp.gmail.com`, port `465`, your Gmail
address as the username, and the 16-character app password as the
password. Fine for a handful of staff; use a real provider for more.

Afterwards, raise the invite allowance under **Authentication → Rate
Limits** if you plan to create several accounts in one sitting.

Add `<site-url>/resident` to the **Redirect URLs** as well: that is
where a resident's confirmation email returns them.

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

### Checking staff management

| # | Check | Expected |
| --- | --- | --- |
| 16 | As the administrator, open Staff accounts | Active staff show **Change role** and **Deactivate**; deactivated staff show **Reactivate**; your own row shows "Managed separately" |
| 17 | Change a Registry Clerk to Land Officer | Saved; the row shows the new role at once |
| 18 | Change them to the role they already hold | "That staff member already holds the role you chose" |
| 19 | Sign in as that staff member | Their account page shows the **new** role |
| 20 | Deactivate a staff member without a reason | Refused; the reason is required |
| 21 | Deactivate them with a reason | Row shows **Deactivated**, the date and the reason; their role is unchanged |
| 22 | While they are signed in elsewhere, deactivate them | Within a minute — or the moment they return to the tab — they are sent to "Your staff account has been deactivated" |
| 23 | Try to sign in as them | They reach the same refusal, not the system |
| 24 | Reactivate them with a reason | Row shows **Active** again; same employee number, email and role |
| 25 | Sign in as them again | Same password as before; their account page works |
| 26 | As an ordinary staff member, call the function by hand (below) | `403` |

For 26, from a signed-in Registry Clerk's browser console:

```js
const { data: { session } } = await supabase.auth.getSession();
await fetch(`${SUPABASE_URL}/functions/v1/manage-staff-account`, {
  method: "POST",
  headers: {
    "Content-Type": "application/json",
    apikey: ANON_KEY,
    Authorization: `Bearer ${session.access_token}`,
  },
  body: JSON.stringify({ action: "deactivate", staff_id: "<any staff id>", reason: "test" }),
}).then((response) => response.status);   // 403
```

The same request with `action: "change_role"` and the Council
Administrator's role id is refused too, as is any attempt to act on the
Council Administrator's own account.

### Checking resident accounts end to end

| # | Check | Expected |
| --- | --- | --- |
| 27 | Register at `/register` with a new email | "Check your email"; a confirmation arrives |
| 28 | Confirm, then sign in | The resident portal, status **Pending**, nothing else reachable |
| 29 | Look for the person in Supabase → residents | Nothing was added to the register |
| 30 | Register again with the same email | "An account with this email may already exist" — no second account |
| 31 | Send verification with a 3 MB file | Refused before anything is submitted |
| 32 | Send verification with a .docx | Refused |
| 33 | Send valid details and both documents | Status stays **Pending**, now showing the submitted date |
| 34 | Try to send a second request | Refused: one is already waiting |
| 35 | As Registry Clerk, open **Resident accounts** | The application is listed |
| 36 | Open it | Claimed details on the left, likely matches on the right, both documents with **View** |
| 37 | Click **View** on a document | Opens; the link stops working after two minutes |
| 38 | Approve against a resident with no household | Refused, telling you to link the household first |
| 39 | Approve against a valid resident | Account becomes **Active** and linked |
| 40 | Check that resident's record on the register | Unchanged — nothing the applicant typed was copied in |
| 41 | Decline another application without a reason | Refused |
| 42 | Decline with a reason | Applicant's account becomes **Declined** |
| 43 | Sign in as the declined applicant | Sees the reason and an **Apply again** button |
| 44 | Apply again with corrected details | New request created; the declined one still on record; same account, same sign-in |
| 45 | As a Land Officer, open `/registry/resident-accounts` | Sent away; the API returns `403` |

### Checking relationship history

| # | Check | Expected |
| --- | --- | --- |
| 46 | Open a resident's family lineage | Three sections: lineage, current, former |
| 47 | Look at a parent or sibling | No **End** button — lineage is permanent |
| 48 | Record a spouse without a date | Refused; a start date is required |
| 49 | Record a spouse with a start date, then **End** it | Moves to **Former spouse**, with both dates, on both people |
| 50 | Record the same spouse again with a later date | A second episode; the first stays under Former |

### If the invitation email fails

The message says no staff account was created, and none was: the staff
record and user account are only written after the invitation has been
accepted for delivery. Fix the SMTP settings above and create the
account again with the same details.

One thing to check afterwards: if the second attempt says *"That email
address already has a sign-in account"*, a sign-in user was left behind
by the failed attempt. Remove it under **Authentication → Users**, then
create the staff account again.

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
