# Resident accounts

## The principle everything here rests on

**An online account does not make anyone a resident of the village.**

`residents` is the authoritative register, and registration never writes
to it. An applicant creates a sign-in, sends their details and two
documents, and a Registry Clerk decides which record *already on the
register* they are. Only then is the account linked.

```
auth.users → user_accounts (resident, pending)
                  └─< resident_account_requests   one per attempt
                            └─< resident_request_documents
```

## Registering

1. **Create a sign-in** at `/register` and confirm the email address.
2. **Send the verification details** from the portal at `/resident`.

Both stages are presented as one thing: creating a resident account.

If the email is already in use, the message is the same either way —
*"An account with this email may already exist. Sign in to continue, or
use Forgot password to recover it."* Nothing confirms or denies whether
an address is registered.

`resident_ensure_account()` creates the `user_accounts` row on first
sign-in, always with `account_type = 'resident'` and
`account_status = 'pending'`, never linked to a resident. It cannot
produce a staff account: it refuses outright for an address that belongs
to a staff member. Staff accounts still only come from an invitation.

## What is collected

Identity (first, middle, surname, previous surname, ID number, date of
birth, gender), contact (email, cellphone), address (house number,
street) and the household claim (the head's full name, and the
applicant's relationship to them).

**Never the household code or the site code.** `HH-0001` and `RES-0001`
are the system's own references; no resident should be expected to know
them, and the table has no column for them.

## Documents

Two are required: a **certified copy of the ID** and a **proof of
residence**. PDF, JPG or PNG, **2 MB each at most**.

The bytes never go near PostgreSQL. They go to a **private** Supabase
Storage bucket, `resident-verification-documents`, and the database
keeps only the path, the file name, the type and the size.

Size and type are checked in three places, and the browser is the least
of them:

1. the browser, as a courtesy;
2. the bucket itself, which Supabase configures with a 2 MB limit and
   the three accepted types, and which no client can talk around;
3. the submission function, which reads the **actual** size of the
   uploaded object from `storage.objects` — so a small declared size
   cannot smuggle a large file through. There is a test for exactly
   that.

The storage policies let an applicant write and read only inside a
folder named after their own auth user id, and let an active Registry
Clerk read the bucket to review what was sent. Nobody else, staff
included, can reach it. There are no public URLs: the clerk's screen
opens each document through a signed link that expires in two minutes.

## One account, many attempts

An applicant never creates a second account. `resident_account_requests`
holds one row per attempt, and a partial unique index allows only **one
pending request per account**. Declined attempts are kept exactly as
they were, with their reason and their documents.

```
Request 1  declined — "Proof of residence could not be verified"
Request 2  pending
Request 3  approved
```

## Account status

| Status | Means |
| --- | --- |
| `pending` | Registered, or reapplied; waiting on the Registry Clerk |
| `active` | Approved and linked to a record on the register |
| `declined` | Turned away, with a reason; may apply again |
| `deactivated` | No access |

A declined applicant can still sign in. They see why they were declined
and an **Apply again** button — and nothing else. The status only
returns to `pending` once the new request has actually been submitted.

## The Registry Clerk's review

`/registry/resident-accounts` lists what is waiting. Opening one gives a
side-by-side: **what the applicant sent** on the left, **the official
record** on the right, with the documents beneath.

Likely matches are suggested in the order a clerk would look:

1. the identity number matches exactly;
2. name and date of birth match;
3. they live at the address given;
4. the household head matches the name given;
5. the surname matches.

Suggestions only. The clerk chooses, and can search the register by
hand instead.

### Approving

Checked on the server before anything changes: the request is still
pending, the caller is an active Registry Clerk, the chosen resident
exists and is `active`, **belongs to a household**, that household is
current, the resident does not already have an account, and the
applicant's account is still pending.

A resident with no household cannot be approved. Link them to their
household with the existing resident functions first, then come back.

Approving sets `user_accounts.resident_id` and `account_status =
'active'`, and marks the request approved with who decided it and when.

**It changes nothing on the register.** The claimed name, ID, address
and household are evidence for matching, never authoritative. If the
official record is wrong, that is a separate correction through Update
resident. A test proves the register is byte-for-byte unchanged by an
approval — including a case where the claimed name differs entirely
from the official one.

### Declining

A reason is required, because the applicant reads it. Declining keeps
the sign-in, the account, the request and the documents. `resident_id`
stays null.

## Security

Row Level Security is on for both new tables, with **no insert, update
or delete policy at all**. An applicant can read their own requests and
documents and nothing else; an active Registry Clerk can read all of
them. Every change goes through a `security definer` function that
works out the caller from `auth.uid()`.

An applicant therefore cannot approve themselves, choose their own
matched resident, set a request to approved, write a reviewer, or touch
`account_status` or `resident_id` directly. Each of those is a test.

## What an active resident account can then do

Once the account is active and linked, the resident's portal also shows
their land: what they may apply for, what they have applied for, what
has been allocated to them, and their permissions to occupy. See
[LAND.md](LAND.md).
