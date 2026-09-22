# Land, allocations and permissions to occupy

Everything TAMS does with land: what kinds there are, who may have them,
how a site is given out, what the permission to occupy is worth, and how
anybody can check that a printed one is genuine.

---

## 1. The four kinds of land

TAMS allocates exactly four kinds of land:

| Land type | Held by | Term | Renewable |
| --- | --- | --- | --- |
| **Residential** | the person | perpetual | no |
| **Farming** | the household | 5 years | yes |
| **Business** | the person | 2 years | yes |
| **Burial** | the household | perpetual | no |

**Grazing land is not one of them.** TAMS does not allocate grazing land
and issues no permission to occupy for it. The migration checks the live
database when it is applied:

* if no grazing site exists, grazing is removed from the kinds of land a
  site may be, and no new grazing site can ever be created;
* if grazing sites *do* exist, they are kept exactly as they are, as
  legacy records that can never be allocated. **Nothing is deleted.**

Either way `allocatable_land_types()` returns only the four above, and
every application, site registration and allocation is checked against
it.

There is **no Council Administrator countersignature** anywhere in this
process, and no approval by a Chief, Headman or Headwoman. What the Land
Officer records is the Traditional Authority's decision; TAMS does not
ask anyone to sign it off afterwards.

## 2. Who may apply

An applicant must, at the moment they apply:

* be on the village register with `resident_status = 'active'`;
* have a verified, active resident account linked to that record;
* be **21 or older**, worked out from `residents.date_of_birth` by real
  date arithmetic (`date_of_birth + 21 years <= current_date`), never
  from a subtraction of years;
* belong to a household;
* not already hold that kind of land, within the limits below;
* have no other open application for the same kind of land.

For **farming** and **burial** the applicant must also be the **head of
their household**, because those are held by the household.

The same check (`land_eligibility`) runs **three times**: when the
resident submits, when the Land Officer approves, and again when the
Land Officer allocates a site. Someone who turns 21 after being refused
can simply apply again; someone whose circumstances change between
approval and allocation is stopped at allocation.

### The hard limits

| Rule | Enforced by |
| --- | --- |
| One residential stand per resident | a partial unique index on `land_allocations` |
| One business site per resident | a partial unique index |
| One farming site per household | a partial unique index |
| A burial plot only when every plot the household holds is full | `land_eligibility` |
| One open allocation per site | a partial unique index |

These are unique indexes in the database, not checks in the application.
Two officers allocating the same site at the same instant cannot both
succeed: the allocation function locks the site row `for update` first,
and the index refuses the second write even if the lock were somehow
bypassed.

## 3. What a resident does

The resident signs in, opens their portal and sees a card for each kind
of land. A kind they cannot have is shown with the reason in plain words
("You already hold a residential stand", "You are under 21").

They fill in a short form — why they are applying, and a few details
particular to the land type — and send it.

* The resident **never chooses a site.** There is no site picker on the
  resident's side at all.
* They **never re-upload their identity document or proof of address.**
  Those are already on their verified account.
* A second open application for the same kind of land is refused by a
  partial unique index, not merely by the form.

## 4. What the Land Officer does

The Land Officer's area is at `/land`:

| Screen | What it is for |
| --- | --- |
| **Dashboard** | what is waiting: applications, allocations, renewals, succession |
| **Applications** | the queue, and one screen per application |
| **Land sites** | register a site, update one, set a burial plot's status, read a site's whole history |
| **Allocations** | what is held now and what was held before; issue a permission; release an allocation |
| **PTOs** | every permission ever issued; open the document; revoke one |
| **Renewals** | farming and business renewal requests |
| **Succession** | residential stands whose holder has died |

Only an **active Land Officer** reaches any of it. Authorisation is
established from `auth.uid()` → `user_accounts` → `staff` → account
active → role is Land Officer, re-read from the database on every single
call. The React route guard is a courtesy; the database is the rule.

### Reviewing an application

The review screen shows the applicant, their household and its members,
their family relationships, the land the household already holds, their
earlier applications, and the eligibility check run just now.

* **Approve** — rechecks eligibility and marks the application approved.
  It allocates nothing.
* **Decline** — requires a reason. The application is kept, the reason is
  recorded, and the applicant reads it in their own portal.

### Allocating a site

Only an approved application can be given a site, and only a site that

* is of the same land type,
* is `available`,
* has no open allocation, and
* (for burial) is `usable`.

The whole allocation happens in one transaction: the site is locked, the
allocation row is written, the site becomes `allocated` and the
application becomes `allocated`. If any part fails, none of it happened.

### Issuing the permission to occupy

The officer types nothing. Holder, household, site, land type, issue date
and expiry all come from the allocation and the register.

* **Residential** and **burial** permissions have `expiry_date = NULL`.
  That is what perpetual means here — there is no pretend far-future
  date such as 9999-12-31 anywhere in the schema.
* **Farming** runs five years from the issue date, **business** two.

A permission is `active`, `expired`, `renewed`, `revoked` or
`superseded`. **Expiry is worked out from the date, not by a scheduler:**
`pto_effective_status(stored_status, expiry_date)` reports a permission
whose expiry date has passed as expired, immediately, with no nightly
job involved and nothing to go wrong if a job does not run.

### Renewal

Only farming and business permissions can be renewed — residential and
burial are perpetual and there is nothing to renew. The holder (or the
head of the household, for farming) requests it; the officer approves or
declines with a reason.

Approving **issues a brand new permission** with a new number and a new
term, and marks the old one `renewed`, pointing at its replacement. The
old permission is never overwritten, and the site does not change.

### Revoking and releasing

* **Revoking** a permission makes it invalid and records the reason. The
  permission stays on record for ever; the allocation is untouched.
* **Releasing** an allocation needs a reason, closes the allocation,
  revokes any current permission and makes the site available again.
  Both records are kept.

Nothing in the land functions deletes a row. There is no physical delete
anywhere.

## 5. Burial plots

A burial plot is `usable`, `full` or `closed`.

* A household gets a second plot only once **every** plot it holds is
  full or closed.
* A full or closed plot is **never** reallocated and **never** leaves the
  household that holds it. It stays theirs for ever.
* TAMS does not record individual graves. That is deliberately out of
  scope.

## 6. Residential succession

A residential permission is perpetual, so it does not lapse when the
holder dies.

When a Registry Clerk records a resident as deceased, any residential
allocation they hold moves to `succession_pending` automatically. While
it is in that state the site is **not** available and cannot be given to
anybody else.

**TAMS never chooses an heir.** The succession screen lists the other
members of the household, in age order, and says which of them would be
eligible — nothing more. It ranks nobody and proposes nobody. The
Traditional Authority decides off the system and the Land Officer records
what was decided:

* **Record the successor** — the old allocation becomes `superseded` and
  a new allocation is written for the same site and the same household,
  with a new permission. The old permission becomes `superseded` and is
  kept. Who heads the household is the Registry Clerk's business and is
  deliberately left alone.
* **Return to the Authority** — used only when the Authority decides
  there is no successor. It requires a reason, closes the allocation and
  frees the site. It is never automatic.

## 7. The document and checking it

`/pto/:ptoId` renders the permission as a printable certificate with a QR
code, ready for the browser's own print-or-save-as-PDF. A resident can
open their own; the Land Officer can open any.

The QR code points at `/verify/pto/<token>`, a page **anybody** can open
without signing in — that is what makes a printed permission checkable at
a counter.

The public page shows only: the PTO number, the holder's name, the land
type, the site code, the village and section, the issue date, the expiry
(or "perpetual"), and whether the permission is valid, expired, revoked,
renewed or superseded.

It shows **no identity number, no date of birth, no contact details, no
address of the holder and no private documents**, and an unknown token
simply reports that nothing matches.

## 8. How it is kept safe

* **Row Level Security is on** for `land_applications`,
  `land_allocations`, `ptos`, `pto_renewal_requests` and `land_sites`.
  There is **no insert, update or delete policy on any of them**, and no
  broad "authenticated may write" policy anywhere.
* **Reads are narrow.** A resident can read their own applications,
  allocations and permissions, and — if they head a household — the
  household's farming and burial ones. Nobody else's. The household-head
  check goes through a `security definer` helper, because a resident has
  no read policy on `households` at all.
* **Every write is a `security definer` function** that establishes the
  caller from `auth.uid()` and rechecks the rules itself. The browser
  holds only the `anon` key and writes to no table directly.
* **A resident cannot approve, allocate, issue, revoke or renew
  anything**, however the call is made — each of those functions refuses
  a caller who is not an active Land Officer with SQLSTATE `42501`.
* **Multi-step work is transactional.** Allocation, renewal and
  succession each either happen completely or not at all.
* **Nothing is physically deleted.** Declined applications, ended
  allocations, revoked and superseded permissions are all kept.

## 9. Deliberately not built

Notifications, Council Secretary functions, the audit trail,
Administrator Transfer, individual grave tracking, GIS or mapping,
payments and fees, and Chief/Headman/Headwoman accounts are **not** part
of this work.
