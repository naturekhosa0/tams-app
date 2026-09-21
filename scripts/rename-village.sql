-- =====================================================================
-- Change the village name on every land site.
--
-- The legacy import has already run, so the name is in the database and
-- changing the CSV alone will not move it. Run this in the Supabase SQL
-- Editor.
--
-- It touches village_name and nothing else: no site code, address,
-- household, resident or allocation is affected.
-- =====================================================================

\echo ''
\echo '=== Before ==='
select coalesce(village_name, '(none)') as village_name, count(*) as sites
from public.land_sites group by village_name order by village_name;

update public.land_sites
   set village_name = 'Mhinga Village'
 where village_name is distinct from 'Mhinga Village';

\echo ''
\echo '=== After — every site should now read Mhinga Village ==='
select coalesce(village_name, '(none)') as village_name, count(*) as sites
from public.land_sites group by village_name order by village_name;

\echo ''
\echo '=== Nothing else changed ==='
select (select count(*) from public.land_sites)           as land_sites,
       (select count(*) from public.residents)            as residents,
       (select count(*) from public.households)           as households,
       (select count(*) from public.land_allocations)     as land_allocations,
       (select count(*) from public.family_relationships) as family_relationships;
