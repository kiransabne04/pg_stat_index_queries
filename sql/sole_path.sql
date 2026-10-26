-- 0.9 (T02): queries for which an index is the only one recorded on its table.
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE TABLE sp (id int PRIMARY KEY, a int, b int);
CREATE INDEX sp_a_idx ON sp (a);
CREATE INDEX sp_b_idx ON sp (b);
CREATE TABLE sp2 (id int PRIMARY KEY, sp_id int);
CREATE INDEX sp2_sp_id_idx ON sp2 (sp_id);
CREATE TABLE sp_ev (id int, at date) PARTITION BY RANGE (at);
CREATE TABLE sp_ev_1 PARTITION OF sp_ev FOR VALUES FROM ('2026-01-01') TO ('2026-07-01');
CREATE TABLE sp_ev_2 PARTITION OF sp_ev FOR VALUES FROM ('2026-07-01') TO ('2027-01-01');
CREATE INDEX sp_ev_id_idx ON sp_ev (id);
INSERT INTO sp SELECT g, g % 100, g % 70 FROM generate_series(1, 5000) g;
INSERT INTO sp2 SELECT g, g FROM generate_series(1, 5000) g;
INSERT INTO sp_ev SELECT g, date '2026-01-01' + (g % 360) FROM generate_series(1, 2000) g;
VACUUM ANALYZE sp, sp2, sp_ev;
SET enable_seqscan = off;

SELECT pg_stat_index_queries_reset();
SELECT pg_stat_statements_reset() IS NOT NULL AS pgss_reset;
SELECT count(*) FROM sp WHERE a = 5;                                -- high: sp_a_idx only
SELECT count(*) FROM sp WHERE a = 5;                                -- same query again
SET enable_indexscan = off;
SET enable_indexonlyscan = off;
SELECT count(*) FROM sp WHERE a = 1 OR b = 2;                       -- medium: BitmapOr of both
RESET enable_indexscan;
RESET enable_indexonlyscan;
SELECT count(*) FROM sp JOIN sp2 ON sp2.sp_id = sp.id WHERE sp.id = 7;  -- high on each table
SELECT count(*) FROM sp_ev WHERE id = 42;                           -- partitions folded: one row
PREPARE never_runs AS SELECT count(*) FROM sp WHERE b = 3 AND false = (SELECT true);
EXECUTE never_runs;                                                 -- low: planned, never executed
DEALLOCATE never_runs;

SELECT p.tablename, p.indexname, regexp_replace(q.query, '\s+', ' ', 'g') AS query,
       p.calls_executed, p.other_indexes, p.risk, p.last_seen IS NOT NULL AS seen
  FROM pg_index_sole_path p
  JOIN (SELECT queryid, min(query) AS query FROM pg_stat_statements GROUP BY queryid) q
    ON q.queryid = p.queryid
 WHERE p.tablename LIKE 'sp%'
 ORDER BY 1, 3, 2;

RESET enable_seqscan;
DROP TABLE sp, sp2, sp_ev;
