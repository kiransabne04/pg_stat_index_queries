/* pg_index_deps--0.1--0.2.sql */

\echo Use "ALTER EXTENSION pg_index_deps UPDATE TO '0.2'" to load this file. \quit

-- User indexes that no captured plan references. Only as good as the plan
-- source: queries without a captured plan, or evicted from
-- pg_stat_statements, are invisible. Excludes PK, unique and constraint indexes.
-- With no plan source (plan_source = none, e.g. RDS) it returns no rows:
-- nothing is known about any index, so nothing is reported as unused.
-- Partitioned tables: one row per partitioned (parent) index, which counts
-- as referenced when any index in its partition tree is; index_bytes is the
-- whole tree. Attached partition indexes aren't listed on their own.
CREATE OR REPLACE VIEW index_deps.index_no_dependents AS
SELECT n.nspname AS schemaname,
       t.relname AS tablename,
       i.relname AS indexname,
       x.indexrelid,
       coalesce((SELECT sum(pg_relation_size(p.relid))
                   FROM pg_partition_tree(x.indexrelid) p),
                pg_relation_size(x.indexrelid))::bigint AS index_bytes,
       index_deps.resolved_plan_source() AS source
  FROM pg_index x
  JOIN pg_class i ON i.oid = x.indexrelid
  JOIN pg_class t ON t.oid = x.indrelid
  JOIN pg_namespace n ON n.oid = i.relnamespace
 WHERE index_deps.resolved_plan_source() <> 'none'
   AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'index_deps')
   AND n.nspname NOT LIKE 'pg_toast%'
   AND NOT x.indisprimary
   AND NOT x.indisunique
   AND NOT i.relispartition
   AND NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conindid = x.indexrelid)
   AND NOT EXISTS (SELECT 1 FROM index_deps.index_dependents d
                    WHERE coalesce(pg_partition_root(d.indexrelid), d.indexrelid) = x.indexrelid);
