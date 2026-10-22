-- Live source: pg_stat_plans on a self-hosted server.
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pg_stat_plans;
DROP TABLE o CASCADE;
DROP SCHEMA s2 CASCADE;
CREATE TABLE o (id int PRIMARY KEY, c int, s int);
CREATE INDEX o_c_idx ON o (c);
CREATE INDEX o_s_idx ON o (s);
INSERT INTO o SELECT g, g % 1000, g % 7 FROM generate_series(1, 100000) g;
VACUUM ANALYZE o;

SELECT count(*) FROM o WHERE c = 5;
SELECT count(*) FROM o WHERE c = 6;
SELECT id FROM o WHERE id = 42;
-- pg_stat_plans flushes call counts lazily (up to 60 s); force it so the
-- calls check below doesn't depend on timing.
SELECT pg_stat_force_next_flush();

SELECT index_deps.resolved_plan_source();
SELECT indexname, calls >= 2 AS seen_twice_or_more, source
  FROM index_deps.index_dependents
 WHERE tablename = 'o' AND indexname = 'o_c_idx';
SELECT indexname, source
  FROM index_deps.index_dependents
 WHERE tablename = 'o' AND indexname = 'o_pkey';
SELECT indexname FROM index_deps.index_no_dependents WHERE tablename = 'o';
