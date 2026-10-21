-- Partition roll-up: child-partition indexes map to the parent index.
SELECT pg_stat_index_queries_reset();
CREATE TABLE ev (id int, tenant int, v int) PARTITION BY RANGE (id);
CREATE TABLE ev_1 PARTITION OF ev FOR VALUES FROM (0) TO (1000);
CREATE TABLE ev_2 PARTITION OF ev FOR VALUES FROM (1000) TO (2000);
CREATE INDEX ev_tenant_idx ON ev (tenant);
INSERT INTO ev SELECT g, g % 10, g FROM generate_series(0, 1999) g;
VACUUM ANALYZE ev;
SET enable_seqscan = off;
SET enable_bitmapscan = off;
SELECT count(*) FROM ev WHERE tenant = 3;
RESET enable_bitmapscan;
RESET enable_seqscan;
-- raw view: one row per child index
SELECT indexrelid::regclass::text AS index, calls_executed
  FROM pg_stat_index_queries
 WHERE indexrelid IN (SELECT indexrelid FROM pg_index WHERE indrelid IN ('ev_1'::regclass, 'ev_2'::regclass))
 ORDER BY 1;
-- roll-up: one row for the parent index, two partitions used
SELECT indexname, partitions_used, calls_executed, partition_scans_executed
  FROM pg_index_dependents_rollup WHERE tablename = 'ev';
