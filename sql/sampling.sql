-- 0.6: backend-local batching (flush_interval) and sampling (sample_rate).
CREATE TABLE sm (id int PRIMARY KEY, a int);
CREATE INDEX sm_a_idx ON sm (a);
INSERT INTO sm SELECT g, g % 100 FROM generate_series(1, 10000) g;
VACUUM ANALYZE sm;
SET enable_seqscan = off;
SHOW pg_stat_index_queries.flush_interval;
SHOW pg_stat_index_queries.sample_rate;

-- Batching: with a long flush interval the counts stay in this backend,
-- but the backend's own reads flush them first, so they are exact.
SELECT pg_stat_index_queries_reset();
SET pg_stat_index_queries.flush_interval = '60s';
SELECT count(*) FROM sm WHERE a = 1;
SELECT count(*) FROM sm WHERE a = 2;
SELECT count(*) FROM sm WHERE a = 3;
SELECT indexname, calls_executed, calls_planned
  FROM pg_index_dependents WHERE tablename = 'sm' ORDER BY indexname;
-- flush_interval = 0: shared memory after every statement (0.5 behaviour).
SET pg_stat_index_queries.flush_interval = 0;
SELECT count(*) FROM sm WHERE a = 4;
SELECT indexname, calls_executed
  FROM pg_index_dependents WHERE tablename = 'sm' ORDER BY indexname;
RESET pg_stat_index_queries.flush_interval;

-- Reset drops this backend's pending counts too.
SET pg_stat_index_queries.flush_interval = '60s';
SELECT count(*) FROM sm WHERE a = 5;
SELECT pg_stat_index_queries_reset();
SELECT count(*) AS after_reset FROM pg_index_dependents WHERE tablename = 'sm';
RESET pg_stat_index_queries.flush_interval;

-- sample_rate = 1: exact, nothing marked as sampled.
SELECT count(*) FROM sm WHERE a = 6;
SELECT count(*) FROM sm WHERE a = 7;
SELECT calls_executed, pg_stat_index_queries_sampled() AS sampled
  FROM pg_index_dependents WHERE indexname = 'sm_a_idx';

-- sample_rate = 0: nothing recorded; sampling is flagged, and an index
-- with no recorded use is "unknown", not a drop candidate.
SELECT pg_stat_index_queries_reset();
SET pg_stat_index_queries.sample_rate = 0;
SELECT count(*) FROM sm WHERE a = 8;
SELECT count(*) FROM sm WHERE id = 9;
SELECT count(*) AS recorded FROM pg_index_dependents WHERE tablename = 'sm';
SELECT pg_stat_index_queries_sampled() AS sampled;
SELECT indexname, left(verdict, 46) AS verdict FROM pg_index_usage WHERE tablename = 'sm' ORDER BY indexname;
RESET pg_stat_index_queries.sample_rate;

-- sample_rate = 0.5: about half of 400 statements are recorded, each
-- adding 2, so the estimate is even and close to 400 (300-500 is beyond
-- 5 standard deviations).
SELECT pg_stat_index_queries_reset();
SET pg_stat_index_queries.sample_rate = 0.5;
\set ECHO none
\o /dev/null
SELECT format('SELECT count(*) FROM sm WHERE a = %s', g % 100) FROM generate_series(1, 400) g \gexec
\o
\set ECHO all
RESET pg_stat_index_queries.sample_rate;
SELECT calls_executed % 2 = 0 AS even, calls_executed BETWEEN 300 AND 500 AS plausible
  FROM pg_index_dependents WHERE indexname = 'sm_a_idx';

-- The reset clears the sampled flag.
SELECT pg_stat_index_queries_reset();
SELECT pg_stat_index_queries_sampled() AS sampled_after_reset;
RESET enable_seqscan;
DROP TABLE sm;
