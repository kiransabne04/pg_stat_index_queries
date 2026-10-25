CREATE EXTENSION pg_stat_index_queries;

CREATE TABLE t (id int PRIMARY KEY, a int, b int, pad text);
CREATE INDEX t_a_idx ON t (a);
CREATE INDEX t_b_idx ON t (b);
CREATE INDEX t_unused_idx ON t (pad);
INSERT INTO t SELECT g, g % 100, g % 50, repeat('x', 20) FROM generate_series(1, 20000) g;
VACUUM ANALYZE t;

SET enable_seqscan = off;

-- helper: counts for our table's indexes only
CREATE FUNCTION idx_counts()
RETURNS TABLE (indexname text, toplevel bool, calls_executed bigint, calls_planned bigint)
LANGUAGE sql AS $$
  SELECT s.indexrelid::regclass::text, s.toplevel,
         sum(s.calls_executed)::bigint, sum(s.calls_planned)::bigint
    FROM pg_stat_index_queries s
   WHERE s.indexrelid IN ('t_pkey'::regclass, 't_a_idx'::regclass,
                          't_b_idx'::regclass, 't_unused_idx'::regclass)
   GROUP BY 1, 2
   ORDER BY 1, 2
$$;

-- 1. plain index scan
SELECT pg_stat_index_queries_reset();
SELECT pad FROM t WHERE id = 42;
SELECT indexname, toplevel, calls_executed, calls_planned FROM idx_counts();

-- 2. index-only scan
SELECT pg_stat_index_queries_reset();
SELECT id FROM t WHERE id BETWEEN 10 AND 12;
SELECT indexname, toplevel, calls_executed, calls_planned FROM idx_counts();

-- 3. bitmap scan combining two indexes
SELECT pg_stat_index_queries_reset();
SET enable_indexscan = off;
SELECT count(*) FROM t WHERE a = 1 OR b = 2;
RESET enable_indexscan;
SELECT indexname, toplevel, calls_executed, calls_planned FROM idx_counts();

-- 4. index in the plan but never executed (one-time filter is false)
SELECT pg_stat_index_queries_reset();
SELECT pad FROM t WHERE id = 7 AND (SELECT false);
SELECT indexname, toplevel, calls_executed, calls_planned FROM idx_counts();

-- 5. prepared statement executed 5 times -> one queryid, 5 calls
SELECT pg_stat_index_queries_reset();
PREPARE p(int) AS SELECT pad FROM t WHERE id = $1;
EXECUTE p(1); EXECUTE p(2); EXECUTE p(3); EXECUTE p(4); EXECUTE p(5);
DEALLOCATE p;
SELECT indexname, toplevel, calls_executed, calls_planned FROM idx_counts();
SELECT count(DISTINCT queryid) AS distinct_queries
  FROM pg_stat_index_queries WHERE indexrelid = 't_pkey'::regclass;

-- 6. nested statements: ignored with track = top, recorded with track = all
SELECT pg_stat_index_queries_reset();
DO $$ BEGIN PERFORM pad FROM t WHERE a = 3; END $$;
SELECT indexname, toplevel, calls_executed, calls_planned FROM idx_counts();
SET pg_stat_index_queries.track = 'all';
DO $$ BEGIN PERFORM pad FROM t WHERE a = 3; END $$;
SELECT indexname, toplevel, calls_executed, calls_planned FROM idx_counts();
RESET pg_stat_index_queries.track;

-- 7. helper views
SELECT pg_stat_index_queries_reset();
SELECT pad FROM t WHERE id = 42;
SELECT indexname, calls_executed FROM pg_index_dependents
 WHERE tablename = 't' ORDER BY indexname;
SELECT indexname FROM pg_index_no_dependents
 WHERE tablename = 't' ORDER BY indexname;
SELECT tracked_since IS NOT NULL AS has_tracked_since
  FROM pg_index_no_dependents WHERE tablename = 't' LIMIT 1;

-- 8. catalog indexes are not tracked by default
SELECT count(*) AS catalog_entries
  FROM pg_stat_index_queries WHERE indexrelid < 16384;

-- 9. info and reset
SELECT entries > 0 AS has_entries, dealloc FROM pg_stat_index_queries_info;
SELECT pg_stat_index_queries_reset();
SELECT entries, dealloc FROM pg_stat_index_queries_info;
