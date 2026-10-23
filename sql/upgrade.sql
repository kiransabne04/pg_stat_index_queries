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
