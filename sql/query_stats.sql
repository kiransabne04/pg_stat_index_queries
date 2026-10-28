-- pg_index_query_stats: one row per (index, query) with the query's
-- pg_stat_statements statistics. Times and buffer counts vary between runs,
-- so they are checked as booleans.
CREATE EXTENSION pg_stat_statements;
CREATE TABLE qs (id int PRIMARY KEY, a int, b int);
CREATE INDEX qs_a_idx ON qs (a);
CREATE INDEX qs_b_small_idx ON qs (b) WHERE b < 10;
INSERT INTO qs SELECT g, g % 100, g % 50 FROM generate_series(1, 20000) g;
VACUUM ANALYZE qs;
SET enable_seqscan = off;

SELECT pg_stat_index_queries_reset();
-- pg_stat_statements_reset() returns void before PG 17, timestamptz after.
DO $$ BEGIN PERFORM pg_stat_statements_reset(); END $$;

SELECT count(*) FROM qs WHERE a = 5;
SELECT count(*) FROM qs WHERE a = 6;
SELECT count(*) FROM qs WHERE a = 7;
SELECT count(*) FROM qs WHERE b = 3;
SELECT count(*) FROM qs x JOIN qs y ON y.id = x.a WHERE x.a = 3;

-- Same queryid for all three a = N queries: one row, calls 3.
-- The join used two indexes: each row names the other one.
SELECT indexname, toplevel, index_calls_executed, calls, rows, rows_per_call,
       pct_calls_using_index, other_indexes, is_unique, is_partial,
       total_exec_ms >= 0 AND mean_exec_ms >= 0 AND max_exec_ms >= min_exec_ms AS has_times,
       shared_blks_hit + shared_blks_read > 0 AS has_buffers,
       cache_hit_pct BETWEEN 0 AND 100 AS hit_pct_ok,
       roles = ARRAY[current_user]::name[] AS roles_ok,
       query
  FROM pg_index_query_stats
 WHERE tablename = 'qs'
 ORDER BY query, indexname;

SELECT indexname, indexdef, index_bytes > 0 AS has_size
  FROM pg_index_query_stats
 WHERE indexname = 'qs_b_small_idx';

-- pg_stat_statements forgets the queries (reset or eviction): the
-- dependency is still listed, statistics are NULL.
DO $$ BEGIN PERFORM pg_stat_statements_reset(); END $$;
SELECT indexname, index_calls_executed, calls IS NULL AS stats_null, query IS NULL AS text_null
  FROM pg_index_query_stats
 WHERE tablename = 'qs'
 ORDER BY indexname, index_calls_executed;

-- Not an install-time dependency: pg_stat_statements can be dropped, and
-- the view then says what is missing.
DROP EXTENSION pg_stat_statements;
SELECT count(*) FROM pg_index_query_stats;
-- 0.10: the index definition, or NULL for an index that no longer exists
-- (also when it is dropped while the definition is read).
SELECT pg_index_def_or_null('qs_a_idx'::regclass) = pg_get_indexdef('qs_a_idx'::regclass) AS same_def,
       pg_index_def_or_null(0) IS NULL AS null_for_missing;
