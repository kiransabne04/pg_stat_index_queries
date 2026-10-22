/* pg_stat_index_queries--0.2--0.3.sql */

\echo Use "ALTER EXTENSION pg_stat_index_queries UPDATE TO '0.3'" to load this file. \quit

-- User indexes with no recorded executed use since the last reset.
-- Excludes primary keys, unique indexes and constraint-backed indexes.
-- Partitioned tables: one row per partitioned (parent) index, which counts
-- as used when any index in its partition tree was used; index_bytes is the
-- whole tree. Attached partition indexes aren't listed on their own (they
-- can't be dropped separately from the parent).
-- ALWAYS check tracked_since before acting on this list.
CREATE OR REPLACE VIEW pg_index_no_dependents AS
    SELECT n.nspname AS schemaname,
           t.relname AS tablename,
           i.relname AS indexname,
           x.indexrelid,
           coalesce((SELECT sum(pg_relation_size(p.relid))
                       FROM pg_partition_tree(x.indexrelid) p),
                    pg_relation_size(x.indexrelid))::bigint AS index_bytes,
           (SELECT stats_reset FROM pg_stat_index_queries_info()) AS tracked_since
      FROM pg_index x
      JOIN pg_class i ON i.oid = x.indexrelid
      JOIN pg_class t ON t.oid = x.indrelid
      JOIN pg_namespace n ON n.oid = i.relnamespace
     WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
       AND n.nspname NOT LIKE 'pg_toast%'
       AND NOT x.indisprimary
       AND NOT x.indisunique
       AND NOT i.relispartition
       AND NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conindid = x.indexrelid)
       AND NOT EXISTS (
            SELECT 1 FROM pg_stat_index_queries() s
             WHERE coalesce(pg_partition_root(s.indexrelid), s.indexrelid) = x.indexrelid
               AND s.calls_executed > 0
               AND s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database()));
