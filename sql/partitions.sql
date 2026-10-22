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
-- no_dependents: the parent index counts as used when a partition index was
-- used; an unused parent index is listed once with the size of the whole
-- tree; attached partition indexes are not listed on their own; an index on
-- a single partition (no parent) is listed by itself.
CREATE INDEX ev_v_idx ON ev (v);
CREATE INDEX ev_1_only_idx ON ev_1 (v);
SELECT tablename, indexname, index_bytes > 0 AS has_size
  FROM pg_index_no_dependents WHERE tablename LIKE 'ev%' ORDER BY indexname;
-- counters left behind by dropped partition indexes don't break the view
DROP INDEX ev_tenant_idx;
SELECT tablename, indexname
  FROM pg_index_no_dependents WHERE tablename LIKE 'ev%' ORDER BY indexname;
