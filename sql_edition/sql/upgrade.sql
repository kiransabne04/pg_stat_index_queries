-- Upgrade path 0.1 -> 0.2.
DROP EXTENSION pg_index_deps;
CREATE EXTENSION pg_index_deps VERSION '0.1';
SELECT extversion FROM pg_extension WHERE extname = 'pg_index_deps';
-- 0.1: with no plan source every index is listed as having no dependents.
CREATE TABLE up (id int, a int);
CREATE INDEX up_a_idx ON up (a);
UPDATE index_deps.config SET value = 'none' WHERE key = 'plan_source';
SELECT indexname FROM index_deps.index_no_dependents WHERE tablename = 'up';
ALTER EXTENSION pg_index_deps UPDATE TO '0.2';
SELECT extversion FROM pg_extension WHERE extname = 'pg_index_deps';
-- 0.2: nothing listed when nothing is known; config survives the update.
SELECT value AS plan_source FROM index_deps.config WHERE key = 'plan_source';
SELECT count(*) AS listed FROM index_deps.index_no_dependents WHERE tablename = 'up';
-- 0.2 adds the query rewriter used by index_drop_impact.
SELECT index_deps.explainable_query('SELECT interval $1') AS explained;
-- 0.2 -> 0.3: index_query_stats added.
SELECT to_regclass('index_deps.index_query_stats') IS NULL AS query_stats_absent_in_0_2;
ALTER EXTENSION pg_index_deps UPDATE TO '0.3';
SELECT extversion FROM pg_extension WHERE extname = 'pg_index_deps';
SELECT to_regclass('index_deps.index_query_stats') IS NOT NULL AS query_stats_present_in_0_3;
-- 0.3 -> 0.4: index_role, index_usage, unresolved_plan_indexes; drop_impact
-- rewritten (drop_blocker column); config readable by everyone.
SELECT to_regclass('index_deps.index_usage') IS NULL AS usage_absent_in_0_3;
ALTER EXTENSION pg_index_deps UPDATE TO '0.4';
SELECT extversion FROM pg_extension WHERE extname = 'pg_index_deps';
SELECT to_regclass('index_deps.index_usage') IS NOT NULL AS usage_present,
       to_regclass('index_deps.unresolved_plan_indexes') IS NOT NULL AS unresolved_present,
       EXISTS (SELECT 1 FROM aclexplode((SELECT relacl FROM pg_class WHERE oid = 'index_deps.config'::regclass)) a
                WHERE a.grantee = 0 AND a.privilege_type = 'SELECT') AS config_public;
SELECT value AS plan_source_kept FROM index_deps.config WHERE key = 'plan_source';
-- 0.4 -> 0.5: same objects, written without SELECT *; output unchanged.
ALTER EXTENSION pg_index_deps UPDATE TO '0.5';
SELECT extversion FROM pg_extension WHERE extname = 'pg_index_deps';
-- No function body selects * (expect no rows).
SELECT p.proname AS uses_select_star
  FROM pg_proc p
 WHERE p.pronamespace = 'index_deps'::regnamespace
   AND p.prosrc ~ '(SELECT \*|\m[a-z_]+\.\*)';
-- 0.5 -> 0.6: table and column statistics (T08); hints in index_usage.
SELECT to_regclass('index_deps.index_table_stats') IS NULL AS stats_absent_in_0_5;
ALTER EXTENSION pg_index_deps UPDATE TO '0.6';
SELECT extversion FROM pg_extension WHERE extname = 'pg_index_deps';
SELECT to_regclass('index_deps.index_table_stats') IS NOT NULL AS table_stats,
       to_regclass('index_deps.index_column_stats') IS NOT NULL AS column_stats,
       to_regprocedure('index_deps.index_hints(regclass)') IS NOT NULL AS hints;
-- 0.6 -> 0.7: index_role notes and blocks indexes that serve a foreign key.
CREATE TABLE up_parent (id int PRIMARY KEY);
CREATE TABLE up_child (id int PRIMARY KEY, pid int REFERENCES up_parent);
CREATE INDEX up_child_pid_idx ON up_child (pid);
SELECT drop_blocker IS NULL AS no_blocker_in_0_6 FROM index_deps.index_role('up_child_pid_idx');
ALTER EXTENSION pg_index_deps UPDATE TO '0.7';
SELECT extversion FROM pg_extension WHERE extname = 'pg_index_deps';
SELECT drop_blocker LIKE 'foreign-key checks use it: up_child_pid_fkey%' AS fk_blocker
  FROM index_deps.index_role('up_child_pid_idx');
DROP TABLE up_child, up_parent;
-- The upgraded objects (0.1 -> ... -> 0.7) must be identical to a fresh install.
CREATE TEMP TABLE defs_upgraded AS
SELECT 'function ' || p.oid::regprocedure::text AS name, pg_get_functiondef(p.oid) AS def
  FROM pg_proc p WHERE p.pronamespace = 'index_deps'::regnamespace
UNION ALL
SELECT 'view ' || c.relname, pg_get_viewdef(c.oid)
  FROM pg_class c WHERE c.relnamespace = 'index_deps'::regnamespace AND c.relkind = 'v';
DROP EXTENSION pg_index_deps;
CREATE EXTENSION pg_index_deps;
SELECT name AS differs_from_fresh_install
  FROM (SELECT 'function ' || p.oid::regprocedure::text AS name, pg_get_functiondef(p.oid) AS def
          FROM pg_proc p WHERE p.pronamespace = 'index_deps'::regnamespace
        UNION ALL
        SELECT 'view ' || c.relname, pg_get_viewdef(c.oid)
          FROM pg_class c WHERE c.relnamespace = 'index_deps'::regnamespace AND c.relkind = 'v') fresh
  FULL JOIN defs_upgraded USING (name)
 WHERE fresh.def IS DISTINCT FROM defs_upgraded.def
 ORDER BY 1;
