-- Upgrade path 0.1 -> 0.2 keeps working and adds the roll-up view.
DROP EXTENSION pg_stat_index_queries;
CREATE EXTENSION pg_stat_index_queries VERSION '0.1';
SELECT to_regclass('pg_index_dependents_rollup') IS NULL AS rollup_absent_in_0_1;
ALTER EXTENSION pg_stat_index_queries UPDATE TO '0.2';
SELECT extversion FROM pg_extension WHERE extname = 'pg_stat_index_queries';
SELECT to_regclass('pg_index_dependents_rollup') IS NOT NULL AS rollup_present_in_0_2;
-- 0.2 -> 0.3: pg_index_no_dependents understands partitioned indexes.
ALTER EXTENSION pg_stat_index_queries UPDATE TO '0.3';
SELECT extversion FROM pg_extension WHERE extname = 'pg_stat_index_queries';
SELECT pg_get_viewdef('pg_index_no_dependents'::regclass) LIKE '%pg_partition_root%'
       AS no_dependents_is_partition_aware;
-- 0.3 -> 0.4: pg_index_query_stats added.
SELECT to_regclass('pg_index_query_stats') IS NULL AS query_stats_absent_in_0_3;
ALTER EXTENSION pg_stat_index_queries UPDATE TO '0.4';
SELECT extversion FROM pg_extension WHERE extname = 'pg_stat_index_queries';
SELECT to_regclass('pg_index_query_stats') IS NOT NULL AS query_stats_present_in_0_4;
-- 0.4 -> 0.5: pg_index_role, pg_index_usage; role columns.
SELECT to_regclass('pg_index_usage') IS NULL AS usage_absent_in_0_4;
ALTER EXTENSION pg_stat_index_queries UPDATE TO '0.5';
SELECT extversion FROM pg_extension WHERE extname = 'pg_stat_index_queries';
SELECT to_regclass('pg_index_usage') IS NOT NULL AS usage_present_in_0_5;
-- 0.5 -> 0.6: pg_stat_index_queries_sampled(); pg_index_usage knows about sampling.
SELECT to_regprocedure('pg_stat_index_queries_sampled()') IS NULL AS sampled_absent_in_0_5;
ALTER EXTENSION pg_stat_index_queries UPDATE TO '0.6';
SELECT extversion FROM pg_extension WHERE extname = 'pg_stat_index_queries';
SELECT pg_stat_index_queries_sampled() AS sampled_after_update;
-- 0.6 -> 0.7: table and column statistics (T08); hints in pg_index_usage.
SELECT to_regclass('pg_index_table_stats') IS NULL AS stats_absent_in_0_6;
ALTER EXTENSION pg_stat_index_queries UPDATE TO '0.7';
SELECT extversion FROM pg_extension WHERE extname = 'pg_stat_index_queries';
SELECT to_regclass('pg_index_table_stats') IS NOT NULL AS table_stats,
       to_regclass('pg_index_column_stats') IS NOT NULL AS column_stats,
       to_regprocedure('pg_index_hints(regclass)') IS NOT NULL AS hints;
-- 0.7 -> 0.8: column sets per query (T07); pg_index_column_usage.
SELECT to_regclass('pg_index_column_usage') IS NULL AS column_usage_absent_in_0_7;
ALTER EXTENSION pg_stat_index_queries UPDATE TO '0.8';
SELECT extversion FROM pg_extension WHERE extname = 'pg_stat_index_queries';
SELECT to_regclass('pg_index_column_usage') IS NOT NULL AS column_usage,
       count(*) FILTER (WHERE attname IN ('cond_columns', 'order_columns', 'columns_complete')) AS new_columns
  FROM pg_attribute WHERE attrelid = 'pg_stat_index_queries'::regclass AND attnum > 0;
-- 0.8 -> 0.9: pg_index_sole_path (T02).
SELECT to_regclass('pg_index_sole_path') IS NULL AS sole_path_absent_in_0_8;
ALTER EXTENSION pg_stat_index_queries UPDATE TO '0.9';
SELECT extversion FROM pg_extension WHERE extname = 'pg_stat_index_queries';
SELECT to_regclass('pg_index_sole_path') IS NOT NULL AS sole_path;
-- The upgraded objects (0.1 -> ... -> 0.9) must be identical to a fresh install.
CREATE TEMP TABLE defs_upgraded AS
SELECT CASE d.classid WHEN 'pg_proc'::regclass THEN 'function ' || d.objid::regprocedure::text
                      ELSE 'view ' || d.objid::regclass::text END AS name,
       CASE d.classid WHEN 'pg_proc'::regclass THEN pg_get_functiondef(d.objid)
                      ELSE pg_get_viewdef(d.objid) END AS def
  FROM pg_depend d
 WHERE d.refclassid = 'pg_extension'::regclass AND d.deptype = 'e'
   AND d.refobjid = (SELECT oid FROM pg_extension WHERE extname = 'pg_stat_index_queries')
   AND (d.classid = 'pg_proc'::regclass
        OR (d.classid = 'pg_class'::regclass AND (SELECT relkind FROM pg_class WHERE oid = d.objid) = 'v'));
DROP EXTENSION pg_stat_index_queries;
CREATE EXTENSION pg_stat_index_queries;
SELECT name AS differs_from_fresh_install
  FROM (SELECT CASE d.classid WHEN 'pg_proc'::regclass THEN 'function ' || d.objid::regprocedure::text
                              ELSE 'view ' || d.objid::regclass::text END AS name,
               CASE d.classid WHEN 'pg_proc'::regclass THEN pg_get_functiondef(d.objid)
                              ELSE pg_get_viewdef(d.objid) END AS def
          FROM pg_depend d
         WHERE d.refclassid = 'pg_extension'::regclass AND d.deptype = 'e'
           AND d.refobjid = (SELECT oid FROM pg_extension WHERE extname = 'pg_stat_index_queries')
           AND (d.classid = 'pg_proc'::regclass
                OR (d.classid = 'pg_class'::regclass AND (SELECT relkind FROM pg_class WHERE oid = d.objid) = 'v'))) fresh
  FULL JOIN defs_upgraded USING (name)
 WHERE fresh.def IS DISTINCT FROM defs_upgraded.def
 ORDER BY 1;
