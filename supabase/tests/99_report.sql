-- Prints the result of every test file that ran before it, and fails
-- the run if any test failed.
\echo ''
\echo '==================== TAMS database tests ===================='
select name, case when passed then 'PASS' else 'FAIL' end as result
from tams_test.results order by id;

select count(*) filter (where passed) as passed,
       count(*) filter (where not passed) as failed,
       count(*) as total
from tams_test.results;

-- Fail the run if anything failed.
do $$
declare
  v_failed int;
begin
  select count(*) into v_failed from tams_test.results where not passed;
  if v_failed > 0 then
    raise exception '% test(s) failed', v_failed;
  end if;
  raise notice 'All % tests passed.', (select count(*) from tams_test.results);
end;
$$;
