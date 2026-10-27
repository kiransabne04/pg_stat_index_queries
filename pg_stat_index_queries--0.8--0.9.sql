/* pg_stat_index_queries--0.8--0.9.sql */

\echo Use "ALTER EXTENSION pg_stat_index_queries UPDATE TO '0.9'" to load this file. \quit

-- One row per (index, query) recorded since the last reset (partition
-- indexes folded into their parent, top-level and nested calls merged), with
-- how much the query depends on the index on that table:
--   high   = the only index on the table the query executed with: dropping
--            it changes that query's plan (a seq scan or a plan not seen yet)
--   medium = the query also executed with other indexes on the same table
--            (other_indexes); it may fall back to one of them
--   low    = only planned, never executed (a scan that never ran)
-- Recorded use only: an index the query never used here can still be its
-- fallback, and evictions or sampling can hide uses (pg_index_usage says so).
CREATE VIEW pg_index_sole_path AS
WITH s AS (
    SELECT coalesce(pg_partition_root(s.indexrelid), s.indexrelid) AS indexrelid,
           s.queryid,
           s.toplevel,
           max(s.calls_executed) AS calls_executed,
           max(s.last_seen) AS last_seen
      FROM pg_stat_index_queries() s
     WHERE s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
       AND EXISTS (SELECT 1 FROM pg_class c WHERE c.oid = s.indexrelid)
     GROUP BY 1, 2, 3
),
q AS (
    SELECT s.indexrelid, x.indrelid, s.queryid,
           sum(s.calls_executed)::bigint AS calls_executed,
           max(s.last_seen) AS last_seen
      FROM s
      JOIN pg_index x ON x.indexrelid = s.indexrelid
     GROUP BY 1, 2, 3
)
SELECT n.nspname AS schemaname,
       t.relname AS tablename,
       i.relname AS indexname,
       q.indexrelid,
       q.queryid,
       q.calls_executed,
       q.last_seen,
       ARRAY(SELECT o.indexrelid::regclass::text
               FROM q o
              WHERE o.indrelid = q.indrelid AND o.queryid = q.queryid
                AND o.indexrelid <> q.indexrelid AND o.calls_executed > 0
              ORDER BY 1) AS other_indexes,
       CASE
         WHEN q.calls_executed = 0 THEN 'low'
         WHEN EXISTS (SELECT 1 FROM q o
                       WHERE o.indrelid = q.indrelid AND o.queryid = q.queryid
                         AND o.indexrelid <> q.indexrelid AND o.calls_executed > 0)
           THEN 'medium'
         ELSE 'high'
       END AS risk
  FROM q
  JOIN pg_class i ON i.oid = q.indexrelid
  JOIN pg_class t ON t.oid = q.indrelid
  JOIN pg_namespace n ON n.oid = i.relnamespace;

GRANT SELECT ON pg_index_sole_path TO PUBLIC;
