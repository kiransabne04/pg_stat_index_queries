-- Index lab: the second database (index_lab2). Included by lab.sql before
-- the seed, so the reconnects happen early: with IAM authentication (Aurora
-- express configuration) a password token is only valid for 15 minutes for
-- new connections, and \c reuses it.

\echo '=== workload: other database (index_lab2)'
SELECT current_database() AS lab_db \gset
\c index_lab2
DROP SCHEMA IF EXISTS lab CASCADE;
CREATE SCHEMA lab;
CREATE TABLE lab.dbx (id int PRIMARY KEY, v int);
INSERT INTO lab.dbx SELECT g, g % 2000 FROM generate_series(1, 20000) g;
CREATE INDEX dbx_v_idx ON lab.dbx (v);
VACUUM ANALYZE lab.dbx;
\o /dev/null
SELECT format('SELECT count(*) FROM lab.dbx WHERE v = %s /* lab:W39 */', g) FROM generate_series(1, 5) g \gexec
\o
EXPLAIN (COSTS OFF) SELECT count(*) FROM lab.dbx WHERE v = 1;
\c :lab_db
SET client_min_messages = warning;

