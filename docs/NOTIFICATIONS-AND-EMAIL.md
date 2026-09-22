# Notifications, email, communications and messaging

One notification system for the whole of TAMS, the email that goes with
it, the Council Secretary's official notices to residents, and the
internal messages staff send each other.

---

## 1. One system, two deliveries

Everything important that happens to somebody is written down as an
**in-app notification** and an **email is queued for it separately**.

The in-app notification is the authoritative one. It is written inside
the same transaction as the business action, so it cannot go missing;
the email is a best effort that is allowed to fail without undoing
anything at all.

**A database transaction never waits on an email provider, and is never
rolled back by one being down.** A land application that was approved
stays approved, the notification stays in the resident's list, and the
email failure is recorded on its own row.

## 2. The notification model

`notifications`:

| Column | What it holds |
| --- | --- |
| `recipient_user_account_id` | whose it is |
| `notification_category` | one of the ten below |
| `title`, `message` | what it says |
| `link_path` | where in TAMS it leads — an application path, never an external link |
| `source_entity_type`, `source_entity_id`, `source_reference` | what it is about |
| `read_at`, `archived_at` | the recipient's own two marks |

**Categories:** `account`, `land_application`, `land_allocation`,
`pto`, `pto_renewal`, `community`, `official_notice`, `staff_message`,
`work_request`, `administration` — a check constraint, not free text.

**Nothing is ever deleted.** Archiving sets `archived_at` and takes the
row out of the everyday inbox; the notification and its history stay.

**`read_at` means one thing only: the notification was opened in TAMS.**
It is not attendance, not legal acceptance, not agreement, and not
compliance. The word "read" is used in that narrow sense everywhere it
appears in the interface.

## 3. What creates a notification

Triggers, not calls added to each function — a trigger cannot be
forgotten. However the row comes to be written, the person it concerns
is told, in the same transaction:

| Event | Who is told |
| --- | --- |
| Resident account approved / declined | the applicant |
| Land application approved / declined | the applicant |
| Site allocated | the holder, or the head of the household |
| Permission to occupy issued | the holder |
| Permission revoked | the holder, with the reason |
| Renewal approved / declined | the requester |
| Farming or business permission nearing expiry | the holder, or the head |
| Official notice, summons, announcement | the residents it was sent to |
| Staff message or work request | the staff it was sent to |
| Work request acknowledged / resolved | the sender |
| Administrator transfer, emergency recovery | incoming and outgoing |

Nothing is sent for opening a page, reading a record or saving a draft.

## 4. Email delivery

`notification_email_deliveries`, **one row per notification** — a unique
constraint on `notification_id` is what stops a second queueing attempt
creating a second email.

**Statuses:** `pending`, `sent`, `failed`, with `attempt_count`,
`last_attempt_at`, `sent_at`, `provider_message_id` and a short
`last_error`.

The table is readable by `service_role` only. Nobody signed in through a
browser — including the Council Administrator — can read a provider
message id or an error.

### The worker

`supabase/functions/process-notification-emails`. It runs on the server
with the service key and the provider key, neither of which the browser
ever sees.

1. `claim_notification_emails(limit)` hands over a batch and records the
   attempt in the same statement, using `for update skip locked`, so two
   workers running at once cannot take the same row.
2. Each one is sent through the provider.
3. `mark_notification_email_sent` or `mark_notification_email_failed`.

**It is idempotent.** A delivery that has been sent is never claimed
again, so running the worker twice sends nothing twice. A failure on one
delivery never stops the rest of the batch.

### Required server-side configuration

Set as Supabase **Edge Function secrets**. None of these is ever
referenced from `src/`, and none reaches the browser:

| Secret | What it is |
| --- | --- |
| `BREVO_API_KEY` | the email provider's API key (Brevo's free tier is enough) |
| `TAMS_EMAIL_FROM` | the address mail is sent from |
| `TAMS_EMAIL_FROM_NAME` | optional; defaults to `TAMS` |
| `TAMS_APP_URL` | where TAMS is, so emails can link back to it |
| `TAMS_WORKER_SECRET` | the shared secret the worker requires, compared in constant time |

Until `TAMS_WORKER_SECRET` is set the worker refuses every request. Until
`BREVO_API_KEY` and `TAMS_EMAIL_FROM` are set it refuses to send and says
which is missing. In both cases the in-app notifications carry on
working exactly as they are.

### Retries

A delivery is retried while `attempt_count < 5` and the last attempt was
more than ten minutes ago. After five attempts it is `failed` and is left
alone. **Retrying never creates a second notification**, because the
retry works on the existing delivery row.

Run the worker on a schedule — see the setup steps in
[SETUP.md](SETUP.md).

## 5. Expiry warnings

`pto_expiry_warnings`, with `unique (pto_id, threshold_days)` — the whole
idempotency mechanism.

`queue_pto_expiry_warnings()` warns the holders of **farming and business**
permissions at **60, 30 and 7 days** before expiry. Business goes to the
resident who holds it; farming goes to whoever heads the household today.

**Residential and burial permissions are perpetual and are never warned
about.** They have no expiry date at all, so they cannot match.

Each permission receives each threshold **exactly once**, however often
the function runs.

## 6. Official communications to residents

`resident_communications` and `resident_communication_recipients`.

**Kinds:** `community_announcement`, `individual_notice`, `summons`,
`general_notice`. **Audiences:** `all_active_residents`, `one_resident`,
`selected_residents`.

A notice may be recorded as **issued on behalf of** the Chief, the
Traditional Council, a Headman or a Headwoman. That is descriptive
information on a record — none of those people has a TAMS account, and
nothing here authenticates anybody.

A summons carries an optional **date, time and venue**, which appear in
the notification the resident receives.

**Recipients are snapshotted when the notice is sent.** Only verified,
active resident accounts are included; pending, declined and deactivated
accounts are not, and somebody verified next month does not
retrospectively become a recipient of last month's announcement.

A notice may refer to a meeting, a resolution or a project by its
**reference only**. Linking a meeting never publishes that meeting.

Only an active **Council Secretary** may send one. A Registry Clerk and a
Land Officer are refused, and a resident is refused.

Sent communications are never deleted and never edited.

## 7. Internal staff messaging

`staff_messages` and `staff_message_recipients`. For coordination between
roles that are deliberately kept apart — a clarification, a handover, a
request for another role to do its part. It is not a chat: there are no
reactions, no emoji features and no attachments.

**Any active staff member** may use it. A deactivated staff member is
refused, and a resident cannot reach it at all.

**Targets:** `direct` (one active staff member), `role` (everybody
holding that role **now**), `all_staff`. An all-staff announcement is the
**Council Administrator's or the Council Secretary's** to make; an
ordinary role is refused.

**Recipients are snapshotted when the message is sent.** A role change
tomorrow does not rewrite who was written to today.

**Kinds:** `normal`, `action_required`, `announcement`.

A message may link a record — resident, household, verification request,
land application, allocation, permission, meeting, resolution or project.
**A link is a reference, never a key**: whether the reader may open it is
decided where that record lives, exactly as it was before the message
existed. A Registry Clerk who receives a link to a land application gains
no Land Officer privilege whatsoever, and the interface says so plainly
when they cannot open it.

**Once sent, a message stands.** It cannot be edited or deleted by
anybody, including its sender. A correction is a new message. A recipient
may **archive their own copy**, which takes it out of their inbox and
changes nothing for anybody else.

Staff may read a message only if they sent it or were a snapshotted
recipient. **The Council Administrator gets no special key to other
people's post.**

### The email alert for a message

The alert says who wrote, about what, how urgent, and the reference — and
links back into TAMS. **The body of the message stays inside TAMS**: an
external inbox is not the place for the details of a private record.

## 8. Work requests

A message marked `action_required` is a work request, with a lifecycle:
`open` → `acknowledged` → `resolved`.

* A **direct** request is acknowledged and resolved by its recipient.
* A **role** request goes to everybody holding that role, and **the first
  of them to acknowledge it claims it**. The row is locked with
  `for update` for the duration, so two people pressing at the same moment
  cannot both win: the second is told who did.
* **Only the staff member who claimed it may resolve it.**
* The sender sees the whole lifecycle — open, acknowledged by whom and
  when, resolved by whom and when.

Resolved requests are kept for ever.

## 9. Security

* **Notifications**: RLS on and forced, a single select policy limiting
  a caller to their own rows, and `select` is the only table privilege
  `authenticated` has. Marking read and archiving go through functions
  that touch those two columns and nothing else, on the caller's own rows
  only. A recipient cannot change a title, a message, a link or a source,
  cannot read anybody else's, and cannot invent one: `notify_user` is
  revoked from every browser role.
* **Email deliveries and expiry warnings**: `service_role` only.
* **Communications**: only an active Council Secretary may send or list
  them. A resident's copy is the notification; they cannot read the
  communications table at all.
* **Staff messages**: readable by the sender and the snapshotted
  recipients, through a `security definer` helper rather than two
  policies consulting each other.
* There is **no insert, update or delete policy** on any table in this
  phase.
