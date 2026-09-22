# The audit trail, Administrator Transfer and emergency recovery

---

## 1. What the audit trail is for

It answers, for anything that ever happened in TAMS:

**Who** changed **what**, **when**, **from what**, **to what**, and
**why** where a reason exists.

"Resident updated" is not an answer. Every update records the old value
and the new value of each field that actually moved.

## 2. How it is written

Not by the frontend, and not by each function remembering to call
something. A function can be changed, or written next year by somebody
who forgets.

**Triggers on the tables themselves**, so the audit happens however the
row came to be written — through the ordinary function, through a later
one, or by hand in the SQL editor.

A business action may add its own name and reason through
`audit_context(action, reason)`, which sets **transaction-local**
settings that the triggers pick up. Anything that has no row behind it —
a document being viewed, a transfer, a recovery — is written with
`audit_event(...)`.

**The actor is read from `auth.uid()` inside a `security definer`
trigger.** No client supplies it. There is no function anywhere that
takes an actor or an action as a parameter from a browser:
`audit_event`, `audit_context`, `audit_actor` and `tg_audit` are all
revoked from `anon` and `authenticated`, and a test asserts that.

## 3. The model

`audit_logs`: `actor_user_id`, `actor_staff_id`, `actor_role` (the role
they held **at that moment**), `actor_account_type`, `actor_label`,
`action`, `entity_type`, `entity_id`, `entity_reference`, `old_values`,
`new_values`, `changed_fields`, `reason`, `event_group_id`,
`created_at`.

`event_group_id` ties together the several rows one business action
writes, and the viewer shows them together.

**Creates** record `old_values = null` and the created fields.
**Updates** record only the fields that moved, on both sides, with
`changed_fields` naming them. **Deletes** record what was there.

Action names come out as the vocabulary an administrator wants —
`PTO_REVOKED`, `MEETING_CANCELLED`, `PROJECT_COMPLETED`,
`STAFF_ROLE_CHANGED`, `LAND_APPLICATION_APPROVED`,
`RESIDENT_ACCOUNT_REQUEST_DECLINED` — because an update that moved a
status column is named after where it moved to.

Internal identifiers are turned into names where that is what a reader
needs: a staff role change records `role: "Registry Clerk" → "Land
Officer"`, not two UUIDs, and a household head change records the
person's name and identity number rather than `head_resident_id`.

## 4. What is covered

**Staff** — account created, role changed, deactivated, reactivated,
Administrator Transfer, emergency recovery.

**Registry** — resident created, updated, status changed; household
created; a resident linked to a household; the household head changed;
family relationships created and ended; resident accounts approved and
declined.

**Land** — applications approved and declined; sites registered and
updated; allocations created, ended and superseded; permissions issued,
renewed, revoked and superseded; burial plots marked full or closed;
residential succession; return to the Authority.

**Council** — meetings created, held, cancelled; attendance;
minutes finalised; amendments; resolutions created and their status and
visibility changed; projects created and their status and visibility
changed; milestones updated and completed.

**Communication** — every official notice sent, by reference; every
staff message sent, by reference; work requests acknowledged and
resolved.

**Document access** — `registry_open_verification_document` records that
an authorised Registry Clerk asked to see a verification document, with
the document type, the applicant and the request. Never a byte of the
document.

## 5. What is never recorded

Dropped before anything is written, whatever the source row holds:

* passwords and password hashes
* reset, access and refresh tokens
* the verification token that makes a permission to occupy checkable
* API keys, the service-role key, email-provider secrets
* storage paths, file paths and any document content
* the body and subject of a private staff message
* the wording of an official notice

The exclusion is by **key name pattern** as well as by an explicit
per-table list, so a column added later that is called `..._token` or
`..._secret` is excluded the day it appears. Tests assert that no key in
the whole trail matches those patterns, and that no permission's
verification token and no document's storage path appears anywhere in it.

## 6. Immutability

`audit_logs` is **insert only**.

* `authenticated` has `select` and nothing else. `service_role` has
  `select` and `insert`.
* A `before update or delete or truncate` trigger raises `TA120` — so
  even the most privileged thing the application ever runs as cannot
  rewrite its own history. A test proves this as the database owner.
* There is **no insert, update or delete policy**, and no public function
  that lets a caller fabricate an entry.

A database owner can drop a trigger; that is outside the application, and
outside what this can promise. Application-level immutability is the
requirement and is what is enforced.

## 7. Who may read it

**The Council Administrator, and nobody else.** A Registry Clerk, a Land
Officer, a Council Secretary and a resident each get nothing — from the
functions and from the table alike.

**Audit trail** (`/admin/audit`) filters by date range, actor, role at
the time, action, kind of record and reference, and exports exactly what
is on screen as CSV — which is exactly what the database was willing to
hand over, with the same exclusions.

**Audit detail** (`/admin/audit/:id`) shows the actor, their role at the
time, the action, the record, the reason, and **old beside new for every
field that changed**, in words rather than raw JSON. The stored JSON is
available behind a toggle as a secondary detail.

## 8. Administrator Transfer

Normal operation has exactly **one active Council Administrator**, and no
ordinary staff function may hand that role out: Create Staff Account and
Change Staff Role both still refuse it, and ordinary deactivate and
reactivate still refuse to touch the administrator.

The role moves **only** through `/admin/transfer`, which only the current
active administrator can open.

**The incoming administrator** must already be staff, with an active
account, a valid sign-in identity, and one of the three ordinary roles —
not themselves, not already the administrator, not deactivated. **No new
account is created by a transfer.**

**The outgoing administrator** chooses one of two outcomes:

* **Remain as staff** — and must choose one of Registry Clerk, Land
  Officer or Council Secretary.
* **Be deactivated** — their account becomes deactivated and their
  record keeps saying they were the Council Administrator. No fake
  ordinary role is invented to make that work.

A **reason is required** and is stored.

**One transaction.** The outgoing administrator stops being one first, so
there is never an instant with two; the transfer then checks that exactly
one active administrator remains and rolls the whole thing back if not.
There is no committed state with two administrators, none, or a half-done
transfer.

The interface warns plainly that this transfers control of TAMS and
requires the word **TRANSFER** to be typed.

Afterwards the outgoing administrator's next authorisation check treats
them as whatever they now are, and the incoming one has administrator
access immediately — both are read live from the database on every call.
Both are notified in TAMS and by email, and the transfer is permanently
audited with the actor's role captured **before** it changed.

### The single-administrator rule

It used to be "no second staff row may carry the administrator role at
all". That cannot survive a transfer that leaves the outgoing
administrator deactivated but still recorded as what they were, so the
rule is now the one that actually matters:

**At most one ACTIVE Council Administrator** — enforced on the staff row
*and* on the account, because either could otherwise create a second.
A deactivated former administrator cannot simply be switched back on
while somebody else holds the role.

## 9. Emergency recovery

For one situation only: **TAMS has no Council Administrator anybody can
sign in as** — an account that is gone, deactivated, or whose sign-in
identity no longer exists.

**A forgotten password is not this.** Use ordinary password recovery. An
administrator whose account is healthy still counts as valid, so recovery
refuses.

There is **no page anywhere in the application** that reaches it, and
nothing on the sign-in page. It runs as `service_role`, from the
`emergency-admin-recovery` edge function, and is revoked from every
browser role.

Three things must all be true:

1. the caller knows **`TAMS_ADMIN_RECOVERY_SECRET`**, compared in
   constant time exactly as the first-administrator bootstrap does;
2. the database agrees there is no valid active administrator;
3. the person being promoted is existing, active, ordinary staff with a
   sign-in identity — never a resident, never a deactivated account.

Recovery promotes them, normal rules resume immediately, and **it refuses
again the moment an administrator exists**.

It is audited as `EMERGENCY_ADMIN_RECOVERY` with the person, their
previous role, the reason given, the timestamp, and the system as the
actor. **The recovery secret is never recorded** — it is not a parameter
of the database function and never reaches the database at all.
