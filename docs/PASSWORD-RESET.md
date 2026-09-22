# Forgetting a password

Residents and every staff role sign in through the same Supabase Auth,
so they all recover a password the same way. Two pages, no tokens of our
own, and nothing in TAMS moves.

---

## 1. The two pages

| Route | Page | Who |
| --- | --- | --- |
| `/forgot-password` | Ask for a reset link | anybody, signed out |
| `/reset-password` | Choose a new password | whoever followed the link |

Neither sits behind a guard — a person who cannot sign in is exactly the
person who needs them. **Sign in** carries a **Forgot password?** link
under the button and another in its footer.

## 2. Asking for a link

`supabase.auth.resetPasswordForEmail(address, { redirectTo })`.

**Supabase Auth's own password recovery.** TAMS mints no recovery token,
stores none, checks none, and touches no auth table. There is nothing in
this codebase that could be a second, weaker way in.

### Account enumeration

The answer is written before the call and does not depend on it:

> If an account exists for that email address, a password reset link has
> been sent. Check your inbox, and your spam folder.

That same sentence appears whether the address belongs to an account or
not, and the page never branches on what Supabase returned. Saying "no
account with that address" would tell anybody who asked which addresses
are registered here, and there is no good reason to do that. The one
thing that *is* checked first is whether the address is shaped like an
address at all, which reveals nothing.

### Where the link comes back to

`resetRedirectUrl` builds `<base>/reset-password` from
`VITE_APP_URL` when it is set, and from the browser's own origin
otherwise. No address is written into the code — a test asserts that
nothing under `src/auth`, `src/lib/appUrl.ts` or the forgot-password page
contains a literal `http://…`.

Set `VITE_APP_URL` when TAMS is deployed, so reset emails never send
anybody to localhost. Leave it unset in development.

## 3. Supabase Dashboard configuration

**Authentication → URL Configuration → Redirect URLs** must list the
reset page, or Supabase refuses to send people back to it:

```
http://localhost:5173/reset-password
```

When TAMS is deployed, add the real one as well and keep both if you
still develop locally:

```
https://your-tams-address.example/reset-password
```

**Site URL** should be the deployed address once there is one.

The reset email itself is ordinary Supabase Auth mail. If custom SMTP is
already configured under **Project Settings → Authentication → SMTP
Settings** — which it is, for the staff invitations — it carries these
too, and nothing further is needed.

## 4. Choosing the new password

The link signs the person in for this one purpose. The page then calls
`supabase.auth.updateUser({ password })`, and that is the whole change.

The rules are the ones TAMS already used for staff invitations, now
shared by both pages so neither can drift from the other: a password is
required, a confirmation is required, they must match, and the password
must be at least **8** characters.

### It changes a password and nothing else

The reset page mentions no TAMS table and makes exactly three calls:
`updateUser`, one audit RPC, and `signOut`. A test asserts that list.

Nothing on the TAMS side reacts either. Passwords live in `auth.users`,
and there is no trigger of ours on that table — a database test changes
every account's password at once and then proves that every field of
`user_accounts` (type, status, resident link, staff link), every
resident's household and status, and every staff member's role are
byte-for-byte what they were, and that not one line of audit was written
by the change itself.

### A deactivated account stays deactivated

Supabase Auth will let a deactivated account through its own recovery,
and that is fine: `account_status` is untouched, so the next sign-in is
turned away exactly as it was before. A database test signs in as a
deactivated Registry Clerk with a changed password and confirms they are
still refused by the registry functions, by staff messaging, and by
`current_user_account_id()`.

**A password reset never reactivates anything.**

## 5. After it succeeds

The temporary recovery session is signed out, so the next sign-in is an
ordinary one with the new password and settles their access the usual
way. The page then says so plainly and offers **Go to sign in** and
**Back to home**.

The success state is checked before the no-session state, so signing out
does not throw the person onto the error page at the moment they
succeed.

## 6. A link that cannot be used

Supabase reports a stale, already-used or malformed link in the address
itself — `error`, `error_code`, `error_description`, usually in the
fragment. `recoveryLinkProblem` reads them, and a missing session takes
the same route, so there is no blank screen and no raw error.

The page says **This reset link cannot be used**, gives the reason in
Supabase's own words where there is one, and offers:

* **Request another reset link** → `/forgot-password`
* **Back to sign in** → `/auth`
* **Back to TAMS home** → `/`

## 7. The audit trail

Password resets are **not** notifications: they do not go through the
notification table, and no recovery link or token is stored anywhere in
TAMS.

One line is written, and only when the reset page asks for it:

```
action            PASSWORD_RESET_COMPLETED
entity            user_account, referenced by email
actor             worked out from auth.uid()
old_values        null
new_values        null
reason            null
created_at        now
```

`record_password_reset()` **takes no parameters at all**. It cannot be
asked to name a different actor, a different account or a different
action — everything it records it works out for itself. That is why it
does not weaken the authentication boundary the way an ordinary
"write me an audit entry" endpoint would.

There are no old or new values because nothing in TAMS changed, and the
one thing that changed outside it is a password, which is never written
down here in any form. Tests assert that no audited field in the whole
trail is even *named* like a password or a token, that no stored hash
appears anywhere in it, and that a signed-out caller gets nowhere.

A recovery session with no TAMS account behind it records nothing and
says nothing about whether such an account exists.

## 8. Navigation

| Page | Offers |
| --- | --- |
| Sign in | **Forgot password?**, Register, Back to home, Verify a PTO |
| Forgot password | ← Back to sign in, Sign in, Register, Back to home, Verify a PTO |
| Forgot password, after sending | Go to sign in, Send another link, and the same footer |
| Reset password | Back to sign in, Back to home, TAMS name → home |
| Reset password, unusable link | Request another reset link, Back to sign in, Back to TAMS home |
| Reset password, done | Go to sign in, Back to home |
| Set password (invitation), unusable link | Go to sign in, **Reset my password**, Back to home |

Every state of every page has somewhere to go, and none of them depends
on the browser's Back button.
