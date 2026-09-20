-- =====================================================================
-- "Could not find the function public.registry_… in the schema cache"
--
-- Run this in the Supabase SQL Editor. It tells you which of the two
-- causes you have, and fixes the second one.
-- =====================================================================

\echo ''
\echo '=== 1. Are the Registry Clerk functions in the database? (expect 15) ==='
select count(*) as registry_functions_found,
       case when count(*) = 0
              then 'NOT APPLIED — run: npm run db:push (or paste the migration into the SQL Editor)'
            when count(*) < 15
              then 'PARTLY APPLIED — re-run the migration; it is safe to run again'
            else 'All present. If the app still cannot see them, it is the schema cache: see step 3.'
       end as what_to_do
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname like 'registry\_%';

\echo ''
\echo '=== 2. Which ones are there, and can a signed-in user call them? ==='
select p.proname as function_name,
       pg_get_function_identity_arguments(p.oid) as arguments,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated_may_call
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname like 'registry\_%'
order by p.proname;

\echo ''
\echo '=== 3. Tell PostgREST to re-read the schema ==='
\echo '(harmless to run at any time; takes a second or two to take effect)'
notify pgrst, 'reload schema';

\echo ''
\echo '=== 4. The other migrations, for completeness ==='
select 'village tables' as checking,
       count(*) filter (where table_name in
         ('land_sites', 'residents', 'households', 'family_relationships', 'land_allocations')) as found,
       5 as expected
from information_schema.tables where table_schema = 'public'
union all
select 'staff tables',
       count(*) filter (where table_name in ('roles', 'staff', 'user_accounts')), 3
from information_schema.tables where table_schema = 'public';
