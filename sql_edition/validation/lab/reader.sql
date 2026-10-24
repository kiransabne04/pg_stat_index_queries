-- Index lab, reader phase: run against an Aurora reader (or a hot standby)
-- after a writer run with --keep. Read-only: runs W40 on lab.reader_only,
-- then shows what this instance's plan source records and whether
-- index_drop_impact works here. Writes reader-report.md.

\set ON_ERROR_STOP on
\pset footer off
\pset null '(null)'
SET client_min_messages = warning;

SELECT pg_is_in_recovery() AS in_recovery,
       current_setting('transaction_read_only') AS read_only,
       index_deps.resolved_plan_source() AS plan_source;

\o /dev/null
SELECT format('SELECT count(*) FROM lab.reader_only WHERE v = %s /* lab:W40 */', g)
  FROM generate_series(1, 10) g \gexec
\o
SELECT to_regprocedure('pg_stat_force_next_flush()') IS NOT NULL AS has_force_flush \gset
\if :has_force_flush
SELECT pg_stat_force_next_flush();
\endif
SELECT pg_sleep(2);

DO $$
DECLARE m text;
BEGIN
    BEGIN
        PERFORM * FROM index_deps.index_drop_impact('lab.reader_only_idx');
        m := 'no error';
    EXCEPTION WHEN OTHERS THEN
        m := 'error: ' || SQLERRM;
    END;
    PERFORM set_config('lab.reader_di', m, false);
END $$;

\pset format unaligned
\pset tuples_only on
\o reader-report.md
SELECT concat_ws(E'\n',
  '# Index lab reader report: ' || :'label',
  '',
  lab.md($q$ SELECT pg_is_in_recovery() AS in_recovery,
                    current_setting('transaction_read_only') AS read_only,
                    index_deps.resolved_plan_source() AS plan_source,
                    current_setting('server_version') AS server_version,
                    now() AS run_at $q$),
  '## W40 on this instance (expected: reader_only_idx attributed here, not on the writer)',
  '',
  lab.md($q$ SELECT d.indexname, d.calls, d.scan_types, tm.calls AS pgss_calls
               FROM index_deps.index_dependents d JOIN lab.tag_map() tm USING (queryid)
              WHERE tm.tag = 'W40' $q$),
  '## index_no_dependents on this instance (lab schema)',
  '',
  lab.md($q$ SELECT indexname FROM index_deps.index_no_dependents
              WHERE schemaname IN ('lab', 'lab_b') ORDER BY 1 $q$),
  '## index_drop_impact here',
  '',
  current_setting('lab.reader_di'),
  '');
\o
\pset format aligned
\pset tuples_only off
\echo 'wrote reader-report.md'
SELECT current_setting('lab.reader_di') AS drop_impact_on_reader;
