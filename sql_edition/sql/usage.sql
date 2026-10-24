-- 0.4: index_role(), index_usage, unresolved plan index names, grants.
CREATE SCHEMA u;
CREATE TABLE u.parent (id int PRIMARY KEY, code text CONSTRAINT parent_code_key UNIQUE, k int NOT NULL);
CREATE UNIQUE INDEX parent_k_uq ON u.parent (k);
CREATE INDEX parent_lower_code_idx ON u.parent (lower(code));
CREATE INDEX parent_k_partial_idx ON u.parent (k) WHERE code IS NOT NULL;
CREATE INDEX parent_unused_idx ON u.parent (code, k);
ALTER TABLE u.parent REPLICA IDENTITY USING INDEX parent_k_uq;
ALTER TABLE u.parent CLUSTER ON parent_pkey;
CREATE TABLE u.child (id int, parent_id int REFERENCES u.parent, code text REFERENCES u.parent (code));
CREATE TABLE u.booking (room int, during tstzrange,
                        CONSTRAINT booking_no_overlap EXCLUDE USING gist (during WITH &&));
CREATE TABLE u.ev (id int, at date) PARTITION BY RANGE (at);
CREATE TABLE u.ev_2026 PARTITION OF u.ev FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');
CREATE INDEX ev_id_idx ON u.ev (id);
CREATE INDEX ev_at_idx ON u.ev (at);
INSERT INTO u.parent SELECT g, 'c' || g, g FROM generate_series(1, 100) g;
-- Invalid index, as left by a failed CREATE INDEX CONCURRENTLY.
CREATE INDEX CONCURRENTLY parent_invalid_idx ON u.parent ((100 / (k - 50)));

SELECT i.relname AS index, r.index_role, r.index_notes, r.drop_blocker
  FROM pg_class i
  JOIN pg_namespace n ON n.oid = i.relnamespace
  CROSS JOIN LATERAL index_deps.index_role(i.oid) r
 WHERE n.nspname = 'u' AND i.relkind IN ('i', 'I')
 ORDER BY i.relname;

-- Plans (fixture): pkey and the expression index used; a plan names
-- ev_old_idx, which no longer exists on u.ev; one plan names an index on a
-- table that is gone.
CREATE TABLE u.plans (queryid bigint, planid bigint, calls bigint, plan_text text);
INSERT INTO u.plans VALUES
 (101, 1, 10, E'Index Scan using parent_pkey on parent\n  Index Cond: (id = $1)'),
 (102, 1, 4,  E'Bitmap Heap Scan on parent\n  ->  Bitmap Index Scan on parent_lower_code_idx'),
 (103, 1, 2,  E'Append\n  ->  Index Scan using ev_2026_id_idx on ev_2026 ev_1'),
 (104, 1, 3,  E'Index Scan using ev_old_idx on ev_2026 ev_1\n  Index Cond: (id = 1)'),
 (105, 1, 1,  E'Index Scan using gone_idx on gone_table');
UPDATE index_deps.config SET value = 'u.plans' WHERE key = 'plan_source';

SELECT index_name, table_hint, calls FROM index_deps.unresolved_plan_indexes ORDER BY index_name;

SELECT indexname, index_role FROM index_deps.index_dependents
 WHERE schemaname = 'u' ORDER BY indexname;

-- ev_old_idx (renamed?) is named in a plan on partition ev_2026, so u.ev's
-- unused index ev_at_idx is unknown, not a drop candidate. gone_idx's table
-- hint matches no table here, so it withholds nothing.
SELECT tablename, indexname, queries, calls, verdict
  FROM index_deps.index_usage WHERE schemaname = 'u' ORDER BY tablename, indexname;

SELECT indexname FROM index_deps.index_no_dependents WHERE schemaname = 'u' ORDER BY indexname;

-- No plan source: every verdict is unknown.
UPDATE index_deps.config SET value = 'none' WHERE key = 'plan_source';
SELECT DISTINCT verdict FROM index_deps.index_usage WHERE schemaname = 'u';
UPDATE index_deps.config SET value = 'u.plans' WHERE key = 'plan_source';

-- A role without any special privileges can read the views (0.3 failed:
-- permission denied for table config).
CREATE ROLE u_analyst NOLOGIN;
GRANT USAGE ON SCHEMA u TO u_analyst;
GRANT SELECT ON u.plans TO u_analyst;
SET ROLE u_analyst;
SELECT count(*) > 0 AS sees_usage FROM index_deps.index_usage WHERE schemaname = 'u';
SELECT count(*) AS dependents FROM index_deps.index_dependents WHERE schemaname = 'u';
RESET ROLE;
DROP OWNED BY u_analyst;
DROP ROLE u_analyst;

UPDATE index_deps.config SET value = 'auto' WHERE key = 'plan_source';
DROP SCHEMA u CASCADE;
