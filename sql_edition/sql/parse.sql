-- Parsing index references out of plan text (fixture source).
CREATE EXTENSION pg_index_deps;

CREATE TABLE o (id int PRIMARY KEY, c int, s int);
CREATE INDEX o_c_idx ON o (c);
CREATE INDEX o_s_idx ON o (s);
CREATE INDEX o_unused_idx ON o (s, c);
CREATE TABLE "Odd Table" (id int);
CREATE INDEX "Odd Idx" ON "Odd Table" (id);
-- Same index name in another schema, on a table also called o: ambiguous.
CREATE SCHEMA s2;
CREATE TABLE s2.o (c int);
CREATE INDEX o_c_idx ON s2.o (c);

CREATE TABLE fixture_plans (queryid bigint, planid bigint, calls bigint, plan_text text);
INSERT INTO fixture_plans VALUES
 (1, 11, 100, E'Index Scan using o_pkey on o\n  Index Cond: (id = $1)'),
 (2, 21, 40,  E'Aggregate\n  ->  Bitmap Heap Scan on o\n        Recheck Cond: ((c = 5) OR (s = 3))\n        ->  BitmapOr\n              ->  Bitmap Index Scan on o_c_idx\n                    Index Cond: (c = 5)\n              ->  Bitmap Index Scan on o_s_idx\n                    Index Cond: (s = 3)'),
 (3, 31, 7,   E'Index Only Scan Backward using o_pkey on o o1\n  Index Cond: (id < 10)'),
 (4, 41, 3,   E'Index Scan using "Odd Idx" on "Odd Table"\n  Index Cond: (id = 1)'),
 (5, 51, 9,   E'Seq Scan on o\n  Filter: (s = 2)'),
 (1, 12, 5,   E'Seq Scan on o\n  Filter: (id = 1)');

UPDATE index_deps.config SET value = 'public.fixture_plans' WHERE key = 'plan_source';

SELECT queryid, planid, calls, scan_type, index_name, table_name
  FROM index_deps.plan_index_usage
 ORDER BY queryid, planid, index_name;

SELECT schemaname, tablename, indexname, queryid, plans, calls, scan_types, ambiguous
  FROM index_deps.index_dependents
 ORDER BY indexname, schemaname, queryid;

SELECT indexname
  FROM index_deps.index_no_dependents
 WHERE schemaname = 'public'
 ORDER BY indexname;

-- 'none' returns nothing and doesn't error
UPDATE index_deps.config SET value = 'none' WHERE key = 'plan_source';
SELECT count(*) AS rows_with_none FROM index_deps.plan_index_usage;
UPDATE index_deps.config SET value = 'auto' WHERE key = 'plan_source';
SELECT index_deps.resolved_plan_source();
