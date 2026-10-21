/* pg_stat_index_queries--0.1--0.2.sql */

\echo Use "ALTER EXTENSION pg_stat_index_queries UPDATE TO '0.2'" to load this file. \quit

-- Partitioned tables: roll child-partition indexes up to the partitioned
-- (parent) index. Non-partition indexes map to themselves.
-- calls_executed = most calls on any one partition index (a lower bound on
-- statements, since one statement can scan several partitions);
-- partition_scans_executed = total across partitions.
CREATE VIEW pg_index_dependents_rollup AS
    SELECT n.nspname AS schemaname,
           t.relname AS tablename,
           i.relname AS indexname,
           r.root_indexrelid AS indexrelid,
           r.queryid,
           r.toplevel,
           r.partitions_used,
           r.calls_executed,
           r.calls_planned,
           r.partition_scans_executed,
           r.first_seen,
           r.last_seen
      FROM (SELECT coalesce(pg_partition_root(s.indexrelid), s.indexrelid) AS root_indexrelid,
                   s.queryid,
                   s.toplevel,
                   count(*) AS partitions_used,
                   max(s.calls_executed)::bigint AS calls_executed,
                   max(s.calls_planned)::bigint AS calls_planned,
                   sum(s.calls_executed)::bigint AS partition_scans_executed,
                   min(s.first_seen) AS first_seen,
                   max(s.last_seen) AS last_seen
              FROM pg_stat_index_queries() s
             WHERE s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
               AND EXISTS (SELECT 1 FROM pg_class c WHERE c.oid = s.indexrelid)
             GROUP BY 1, 2, 3) r
      JOIN pg_class i ON i.oid = r.root_indexrelid
      JOIN pg_index x ON x.indexrelid = r.root_indexrelid
      JOIN pg_class t ON t.oid = x.indrelid
      JOIN pg_namespace n ON n.oid = i.relnamespace;

GRANT SELECT ON pg_index_dependents_rollup TO PUBLIC;
