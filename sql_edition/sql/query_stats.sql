-- index_query_stats: captured-plan dependencies with the query's
-- pg_stat_statements statistics. Times, buffers and pg_stat_plans call
-- counts vary between runs, so they are checked as booleans.
SET enable_seqscan = off;
SELECT count(*) FROM o x JOIN o y ON y.id = x.c WHERE x.c = 23;
SELECT count(*) FROM o x JOIN o y ON y.id = x.c WHERE x.c = 24;
SELECT pg_stat_force_next_flush();
RESET enable_seqscan;

-- The join's plan used two indexes: each row names the other one.
SELECT indexname, scan_types, source, other_indexes, is_unique, is_partial,
       index_plans >= 1 AND index_calls >= 1 AS counted,
       calls = 2 AS calls_ok, rows_per_call,
       total_exec_ms >= 0 AND mean_exec_ms >= 0 AND max_exec_ms >= min_exec_ms AS has_times,
       shared_blks_hit + shared_blks_read > 0 AS has_buffers,
       roles = ARRAY[current_user]::name[] AS roles_ok,
       indexdef, query
  FROM index_deps.index_query_stats
 WHERE query LIKE '%JOIN o y%'
 ORDER BY indexname;

-- Not an install-time dependency: pg_stat_statements can be dropped, and
-- the view then says what is missing.
DROP EXTENSION pg_stat_statements;
SELECT count(*) FROM index_deps.index_query_stats;
CREATE EXTENSION pg_stat_statements;
