-- 0.8 (T07): which index columns each query searched on or ordered by.
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE TABLE cu (id int PRIMARY KEY, a int, b int, c int, txt text, p point);
CREATE INDEX cu_abc_idx ON cu (a, b, c);
CREATE INDEX cu_lower_idx ON cu (lower(txt));
CREATE INDEX cu_p_idx ON cu USING gist (p);
CREATE TABLE cu_ev (id int, at date) PARTITION BY RANGE (at);
CREATE TABLE cu_ev_1 PARTITION OF cu_ev FOR VALUES FROM ('2026-01-01') TO ('2026-07-01');
CREATE TABLE cu_ev_2 PARTITION OF cu_ev FOR VALUES FROM ('2026-07-01') TO ('2027-01-01');
CREATE INDEX cu_ev_at_id_idx ON cu_ev (at, id);
INSERT INTO cu SELECT g, g % 100, g % 7, g % 3, 'T' || g, point(g % 50, g / 50) FROM generate_series(1, 5000) g;
INSERT INTO cu_ev SELECT g, date '2026-01-01' + (g % 360) FROM generate_series(1, 2000) g;
VACUUM ANALYZE cu, cu_ev;
SET enable_seqscan = off;

SELECT pg_stat_index_queries_reset();
SELECT pg_stat_statements_reset() IS NOT NULL AS pgss_reset;
SELECT count(*) FROM cu WHERE a = 5;                           -- a
SELECT count(*) FROM cu WHERE a = 5 AND b = 3;                 -- a, b
SELECT count(*) FROM cu WHERE a = 5 AND b = 3;                 -- again: same query
SELECT count(*) FROM cu WHERE b = 3;                           -- b only
SELECT a FROM cu ORDER BY a, b, c LIMIT 1;                     -- ordered scan, no condition
SELECT count(*) FROM cu WHERE lower(txt) = 't7';               -- expression column
SELECT id FROM cu ORDER BY p <-> point(10, 10) LIMIT 1;        -- KNN: order_columns
SELECT count(*) FROM cu_ev WHERE at = date '2026-03-01';       -- partitioned, leading column
SET enable_indexscan = off;
SET enable_indexonlyscan = off;
SELECT count(*) FROM cu WHERE a = 1 OR c = 2;                  -- bitmap: BitmapOr of two scans
RESET enable_indexscan;
RESET enable_indexonlyscan;
SET enable_bitmapscan = off;
SELECT count(a) FROM cu WHERE a = 9 AND c = 1;                 -- index-only scan, a and c
RESET enable_bitmapscan;

-- Raw column numbers and names per (index, query).
SELECT d.indexname, regexp_replace(q.query, '\s+', ' ', 'g') AS query,
       d.calls_executed, s.cond_columns AS cond_nums, d.cond_columns, d.order_columns,
       d.columns_complete
  FROM pg_index_dependents d
  JOIN pg_stat_index_queries s ON s.indexrelid = d.indexrelid AND s.queryid = d.queryid
                              AND s.toplevel = d.toplevel
  JOIN (SELECT queryid, min(query) AS query FROM pg_stat_statements GROUP BY queryid) q
    ON q.queryid = d.queryid
 WHERE d.tablename LIKE 'cu%' AND d.calls_executed > 0
 ORDER BY 1, 2;

-- Per key column. Partition indexes are folded into the parent index.
SELECT indexname, key_position, column_expr, queries, queries_searched, calls_searched,
       queries_ordered, queries_columns_unknown, note
  FROM pg_index_column_usage
 WHERE tablename LIKE 'cu%' AND indexname <> 'cu_pkey'
 ORDER BY indexname, key_position;

-- A planned scan that never ran records no columns (calls_executed = 0).
PREPARE never_runs AS SELECT count(*) FROM cu WHERE a = 1 AND false = (SELECT true);
SELECT pg_stat_index_queries_reset();
EXECUTE never_runs;
SELECT calls_planned, calls_executed, cond_columns FROM pg_stat_index_queries
 WHERE indexrelid = 'cu_abc_idx'::regclass;
DEALLOCATE never_runs;

-- The 0.1-0.7 C symbol still returns the old 8 columns, so an extension not
-- yet updated keeps working with the new library.
CREATE FUNCTION old_shape(OUT dbid oid, OUT indexrelid oid, OUT queryid bigint,
                          OUT toplevel bool, OUT calls_executed bigint, OUT calls_planned bigint,
                          OUT first_seen timestamptz, OUT last_seen timestamptz)
RETURNS SETOF record AS 'pg_stat_index_queries', 'pg_stat_index_queries' LANGUAGE C STRICT;
SELECT count(*) FROM cu WHERE a = 3;
SELECT calls_executed FROM old_shape() WHERE indexrelid = 'cu_abc_idx'::regclass AND calls_executed > 0;
DROP FUNCTION old_shape();

RESET enable_seqscan;
DROP TABLE cu, cu_ev;
