-- Index lab: end-to-end validation of pg_index_deps (and the native
-- extension when present) on a synthetic workload. Run through run.sh,
-- which creates the databases index_lab and index_lab2 and installs the
-- extensions. Variables: label, scale (default 1), simulate_rds (optional).

\set ON_ERROR_STOP on
\pset footer off
\pset null '(null)'
SET client_min_messages = warning;
\if :{?scale}
\else
\set scale 1
\endif

SELECT current_database() = 'index_lab' AS in_lab_db \gset
\if :in_lab_db
\else
\echo 'lab.sql must run in database index_lab (use run.sh)'
\quit
\endif

\if :{?simulate_rds}
\echo 'simulate_rds: plan_source = none for this run'
UPDATE index_deps.config SET value = 'none' WHERE key = 'plan_source';
\endif

SELECT clock_timestamp() AS lab_start \gset
\ir otherdb.sql
\ir seed.sql
SELECT clock_timestamp() AS seed_done \gset
\ir workload.sql
\ir checks.sql
INSERT INTO lab.env VALUES
  ('seed seconds', round(extract(epoch FROM :'seed_done'::timestamptz - :'lab_start'::timestamptz)::numeric, 1)::text),
  ('total seconds (before report)', round(extract(epoch FROM clock_timestamp() - :'lab_start'::timestamptz)::numeric, 1)::text);
\ir report.sql
\echo '=== lab done'
