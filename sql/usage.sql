-- 0.5: pg_index_role() and pg_index_usage.
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE TABLE ur (id int PRIMARY KEY, code text CONSTRAINT ur_code_key UNIQUE, k int NOT NULL);
CREATE UNIQUE INDEX ur_k_uq ON ur (k);
CREATE INDEX ur_lower_code_idx ON ur (lower(code));
CREATE INDEX ur_unused_idx ON ur (code, k);
ALTER TABLE ur REPLICA IDENTITY USING INDEX ur_k_uq;
CREATE TABLE ur_child (id int, ur_id int REFERENCES ur);
CREATE TABLE ur_ev (id int, at date) PARTITION BY RANGE (at);
CREATE TABLE ur_ev_2026 PARTITION OF ur_ev FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');
CREATE INDEX ur_ev_id_idx ON ur_ev (id);
INSERT INTO ur SELECT g, 'c' || g, g FROM generate_series(1, 1000) g;
INSERT INTO ur_ev SELECT g, date '2026-03-01' FROM generate_series(1, 1000) g;
VACUUM ANALYZE ur, ur_ev;
SET enable_seqscan = off;

SELECT i.relname AS index, r.index_role, r.index_notes, r.drop_blocker
  FROM pg_class i
  CROSS JOIN LATERAL pg_index_role(i.oid) r
 WHERE i.relname LIKE 'ur%' AND i.relkind IN ('i', 'I')
 ORDER BY i.relname;

SELECT pg_stat_index_queries_reset();
SELECT count(*) FROM ur WHERE id = 5;
SELECT count(*) FROM ur WHERE lower(code) = 'c7';
SELECT count(*) FROM ur_ev WHERE id = 9;

SELECT indexname, index_role FROM pg_index_dependents
 WHERE tablename LIKE 'ur%' ORDER BY indexname;

SELECT tablename, indexname, queries, calls_executed,
       replace(verdict, tracked_since::text, '<tracked_since>') AS verdict
  FROM pg_index_usage WHERE tablename LIKE 'ur%' ORDER BY tablename, indexname;

SELECT indexname, index_role, index_notes FROM pg_index_query_stats
 WHERE tablename = 'ur' ORDER BY indexname;
RESET enable_seqscan;
DROP TABLE ur_child, ur, ur_ev;
