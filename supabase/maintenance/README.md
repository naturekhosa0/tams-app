# Database preparation for deployment

## Clean demonstration reset — destructive

Use this route when the demonstration must start with no resident, household,
land, council, message, notification, audit or non-administrator account data.
It keeps only the active Council Administrator's Auth identity, staff row and
active application account.

1. Run `preview_demonstration_reset.sql` in the Supabase SQL Editor.
2. Confirm exactly one account says `KEEP — sole active account after reset`.
3. In **Supabase → Storage**, open `resident-verification-documents` and empty
   the bucket. Do not delete `storage.objects` with SQL.
4. Open `reset_for_demonstration.sql`, read the warning, and change its one
   confirmation value from `TYPE RESET TAMS FOR DEMONSTRATION` to
   `RESET TAMS FOR DEMONSTRATION`.
5. Run the complete edited script once. Its final result must show the Council
   Administrator as active, one application account, one Auth user and zero
   audit rows.
6. Turn off **Allow new users to sign up** in **Authentication → Sign In /
   Providers → Email**.

This reset is permanent. It deliberately clears the audit trail and removes the
earlier reversible-deactivation snapshots so the app starts clean.

## Account-only lockdown — reversible

These scripts leave the active Council Administrator as the only usable TAMS
account. They do not delete accounts, Auth identities, residents, staff, land,
households or council records.

Run them in the Supabase SQL Editor in this order:

1. `preview_administrator_only.sql` — confirm that
   `active_council_administrators` is exactly `1` and inspect every planned
   account change.
2. `enable_administrator_only.sql` — deactivate every non-administrator
   account in one transaction and save the prior state in the private schema.
3. Run the preview again. The Council Administrator must be the only account
   whose status is not `deactivated`.

Also turn off **Allow new users to sign up** in **Supabase → Authentication →
Sign In / Providers → Email**. The web deployment must set
`VITE_RESIDENT_SELF_REGISTRATION=false`.

To undo the database part later, run `restore_administrator_only.sql`. It
restores the exact statuses and staff deactivation details saved by the latest
enable batch. Accounts that were already deactivated before the batch remain
deactivated.

Do not use the reversible route when the goal is a completely empty
demonstration database.

