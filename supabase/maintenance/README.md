# Account-linked data cleanup

These scripts remove registry and land data that is not connected to a resident
account. They are manual maintenance scripts, not migrations, so `npm run
db:push` will never run them automatically.

1. Create a database backup or confirm that the required Supabase point-in-time
   recovery window is available.
2. Run `preview_unlinked_account_data.sql` in the Supabase SQL Editor. Review
   every result set, especially the resident, household and land lists.
3. Run `cleanup_unlinked_account_data.sql` once. It executes in one transaction;
   any failed consistency check rolls the complete cleanup back.
4. Run the preview again. Every `will_delete` value should be zero.
5. Sign in with each retained resident account and check its household, land
   applications and permissions.

The cleanup keeps `audit_logs`. TAMS audit records are intentionally immutable
and remain as the security history of the deleted operational rows. Account
requests, verification documents and notifications also remain because they
are directly linked to user accounts.
