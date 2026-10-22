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
