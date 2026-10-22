-- Validation run for pg_index_deps on Amazon Aurora PostgreSQL / Amazon RDS
-- for PostgreSQL (task T05). Checklist: docs/AURORA-VALIDATION.md.
--
--   psql "$URL" -X -f sql_edition/validation/managed_check.sql 2>&1 | tee managed_check.out
--
-- Optional psql variables:
--   -v keep=1          keep schema index_deps_check afterwards (default: drop it)
--   -v simulate_rds=1  force plan_source = none for this run (to rehearse the
--                      RDS path on a server that has a plan source)
--
-- What it touches: creates and drops schema index_deps_check (synthetic data
-- only), runs SELECTs on it, and calls index_deps.index_drop_impact(), which
-- only runs EXPLAIN. It does not reset pg_stat_statements or any other stats.
-- Writes two files to the client's current directory when aurora_stat_plans
-- exists: aurora_stat_plans_raw.jsonl and aurora_fixture.csv.
--
-- Needs: pg_index_deps installed (sql_edition/install.sql or pg_tle),
-- pg_stat_statements, and for the drop-impact part PG 16+ and HypoPG 1.4+.

\set ON_ERROR_STOP on
\pset footer off
\pset null '(null)'
SET client_min_messages = warning;

\echo '=== 1. Environment'
SELECT version();
SELECT current_setting('server_version_num') AS server_version_num,
       current_user, current_database(),
       (SELECT rolsuper FROM pg_roles WHERE rolname = current_user) AS superuser,
       (SELECT pg_has_role(current_user, oid, 'member')
          FROM pg_roles WHERE rolname = 'rds_superuser') AS rds_superuser;

SELECT to_regprocedure('aurora_version()') IS NOT NULL AS is_aurora,
       to_regprocedure('aurora_stat_plans(boolean)') IS NOT NULL AS has_aurora_stat_plans,
       to_regprocedure('pg_stat_plans(boolean)') IS NOT NULL AS has_pg_stat_plans,
       to_regprocedure('hypopg_hide_index(oid)') IS NOT NULL AS has_hypopg,
       to_regclass('pg_stat_statements') IS NOT NULL AS has_pg_stat_statements,
       current_setting('server_version_num')::int >= 160000 AS has_generic_plan,
       current_setting('server_version_num')::int >= 150000 AS has_force_flush
\gset
\echo is_aurora=:is_aurora aurora_stat_plans=:has_aurora_stat_plans pg_stat_plans=:has_pg_stat_plans hypopg=:has_hypopg pg_stat_statements=:has_pg_stat_statements pg16+=:has_generic_plan

\if :is_aurora
SELECT aurora_version();
\endif

SELECT name, setting
  FROM pg_settings
 WHERE name IN ('shared_preload_libraries', 'compute_query_id', 'aurora_compute_plan_id',
                'pg_stat_statements.track', 'pg_stat_statements.max')
    OR name LIKE 'aurora_stat_plans.%'
 ORDER BY name;

SELECT name, default_version, installed_version
  FROM pg_available_extensions
 WHERE name IN ('pg_stat_statements', 'hypopg', 'pg_tle', 'pg_index_deps', 'pg_stat_plans')
 ORDER BY name;

\echo '=== 2. pg_index_deps install'
SELECT n.nspname AS schema, count(p.oid) AS functions
  FROM pg_namespace n LEFT JOIN pg_proc p ON p.pronamespace = n.oid
 WHERE n.nspname = 'index_deps'
 GROUP BY 1;
SELECT extname, extversion FROM pg_extension WHERE extname = 'pg_index_deps';

\if :{?simulate_rds}
\echo 'simulate_rds: forcing plan_source = none for this run'
SELECT value AS saved_plan_source FROM index_deps.config WHERE key = 'plan_source' \gset
UPDATE index_deps.config SET value = 'none' WHERE key = 'plan_source';
\endif

SELECT index_deps.resolved_plan_source() AS resolved_plan_source;

\if :has_aurora_stat_plans
\echo '=== 3. aurora_stat_plans columns (compare with index_deps.plan_source())'
SELECT * FROM aurora_stat_plans(true) LIMIT 0 \gdesc
\endif

\echo '=== 4. Synthetic schema and workload'
DROP SCHEMA IF EXISTS index_deps_check CASCADE;
CREATE SCHEMA index_deps_check;
CREATE TABLE index_deps_check.t (
    id      int PRIMARY KEY,
    a       int NOT NULL,
    b       int NOT NULL,
    c       int NOT NULL,
    note    text NOT NULL
);
INSERT INTO index_deps_check.t
SELECT g, g % 1000, g % 97, g % 10, 'row ' || g FROM generate_series(1, 100000) g;
CREATE INDEX t_a_idx ON index_deps_check.t (a);
CREATE INDEX t_b_unused_idx ON index_deps_check.t (b);            -- never queried
CREATE INDEX "T Mixed Case Idx" ON index_deps_check.t (c, id);     -- quoted name in plans
VACUUM ANALYZE index_deps_check.t;

\o /dev/null
-- Index Scan
SELECT format('SELECT note FROM index_deps_check.t WHERE id = %s', g)
  FROM generate_series(1, 20) g \gexec
-- Bitmap Index Scan + Bitmap Heap Scan
SELECT format('SELECT count(note) FROM index_deps_check.t WHERE a = %s', g)
  FROM generate_series(1, 20) g \gexec
-- Index Only Scan on the quoted-name index
SELECT format('SELECT count(*) FROM index_deps_check.t WHERE c = %s AND id < 5000', g % 10)
  FROM generate_series(1, 20) g \gexec
-- Index Scan Backward
SELECT format('SELECT id FROM index_deps_check.t WHERE id < %s ORDER BY id DESC LIMIT 5', 1000 + g)
  FROM generate_series(1, 20) g \gexec
-- Sequential scan (no index)
SELECT format('SELECT count(*) FROM index_deps_check.t WHERE note LIKE %L', 'row 1' || g || '%')
  FROM generate_series(1, 5) g \gexec
\o

-- Self-hosted pg_stat_plans flushes call counts lazily; force it (PG 15+).
\if :has_force_flush
SELECT pg_stat_force_next_flush();
\endif
SELECT pg_sleep(1);

\echo '=== 5. pg_stat_statements entries for the workload'
SELECT queryid, calls, left(regexp_replace(query, '\s+', ' ', 'g'), 80) AS query
  FROM pg_stat_statements
 WHERE query LIKE '%index_deps_check.t%' AND query NOT LIKE '%pg_stat_statements%'
   AND dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
 ORDER BY calls DESC, query;

\echo '=== 6. index_deps.plan_source() rows for the workload'
SELECT p.queryid, p.planid, p.calls, p.source,
       left(regexp_replace(p.plan_text, '\s+', ' ', 'g'), 100) AS plan_text
  FROM index_deps.plan_source() p
 WHERE p.queryid IN (SELECT queryid FROM pg_stat_statements WHERE query LIKE '%index_deps_check.t%')
 ORDER BY p.calls DESC, p.queryid;

\echo '=== 7. index_deps.plan_index_usage (parser output)'
SELECT u.queryid, u.scan_type, u.index_name, u.table_name, u.calls
  FROM index_deps.plan_index_usage u
 WHERE u.queryid IN (SELECT queryid FROM pg_stat_statements WHERE query LIKE '%index_deps_check.t%')
 ORDER BY u.index_name, u.scan_type;

\echo '=== 8. index_deps.index_dependents / index_no_dependents'
SELECT indexname, queryid, plans, calls, scan_types, ambiguous, source
  FROM index_deps.index_dependents
 WHERE schemaname = 'index_deps_check'
 ORDER BY indexname, calls DESC;
-- Expected with a plan source: t_a_idx (bitmap), t_pkey (index, and
-- index_only for the backward scan) and "T Mixed Case Idx" (index_only);
-- t_b_unused_idx missing.
-- Expected on RDS (no plan source): no rows.
SELECT indexname, pg_size_pretty(index_bytes) AS size, source
  FROM index_deps.index_no_dependents
 WHERE schemaname = 'index_deps_check'
 ORDER BY indexname;
-- Expected with a plan source: t_b_unused_idx only.

\if :has_aurora_stat_plans
\echo '=== 9. Fixture capture (files in the client current directory)'
\copy (SELECT to_jsonb(s) FROM aurora_stat_plans(true) s WHERE s.queryid IN (SELECT queryid FROM pg_stat_statements WHERE query LIKE '%index_deps_check.t%')) TO 'aurora_stat_plans_raw.jsonl'
\copy (SELECT queryid, planid, calls, explain_plan FROM aurora_stat_plans(true) s WHERE s.queryid IN (SELECT queryid FROM pg_stat_statements WHERE query LIKE '%index_deps_check.t%') ORDER BY queryid, planid) TO 'aurora_fixture.csv' WITH (FORMAT csv, HEADER)
\echo 'wrote aurora_stat_plans_raw.jsonl (all columns) and aurora_fixture.csv'
\else
\echo '=== 9. Fixture capture: skipped (no aurora_stat_plans)'
\endif

SELECT :'has_hypopg'::boolean AND :'has_generic_plan'::boolean
       AND :'has_pg_stat_statements'::boolean AS can_drop_impact \gset
\if :can_drop_impact
\echo '=== 10. index_drop_impact: used index t_a_idx'
SELECT queryid, calls, cost_with, cost_without, cost_ratio,
       uses_index_now, uses_index_after, plan_changed, note,
       left(regexp_replace(query, '\s+', ' ', 'g'), 60) AS query
  FROM index_deps.index_drop_impact('index_deps_check.t_a_idx')
 ORDER BY calls DESC, queryid;
-- Expected: the "WHERE a = $1" query with uses_index_now = t,
-- uses_index_after = f, cost_ratio > 1.

\echo '=== 11. index_drop_impact: unused index t_b_unused_idx'
SELECT queryid, calls, cost_ratio, uses_index_now, uses_index_after, plan_changed, note,
       left(regexp_replace(query, '\s+', ' ', 'g'), 60) AS query
  FROM index_deps.index_drop_impact('index_deps_check.t_b_unused_idx')
 ORDER BY calls DESC, queryid;
-- Expected: every row cost_ratio 1.00 and uses_index_now = f
-- (candidates from query text mentions table).

\echo '=== 12. No index left hidden (expect 0)'
SELECT count(*) AS still_hidden FROM hypopg_hidden_indexes();
\else
\echo '=== 10-12. index_drop_impact: skipped (needs PG 16+, HypoPG 1.4+ and pg_stat_statements)'
\endif

\if :{?simulate_rds}
UPDATE index_deps.config SET value = :'saved_plan_source' WHERE key = 'plan_source';
SELECT index_deps.resolved_plan_source() AS restored_plan_source;
\endif

\if :{?keep}
\echo 'keep set: schema index_deps_check left in place'
\else
DROP SCHEMA index_deps_check CASCADE;
\echo 'dropped schema index_deps_check'
\endif
\echo '=== done'
