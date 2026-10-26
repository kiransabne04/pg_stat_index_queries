-- Plan source 'none' keeps index_usage independent of the captured plans of other tests.
UPDATE index_deps.config SET value = 'none' WHERE key = 'plan_source';
-- T08: table and column statistics behind each index, and the hints.
-- Tables are small enough that ANALYZE reads every row, so distinct counts,
-- most common values and null fractions are exact. Autovacuum is off on
-- these tables so nothing analyzes them behind the test's back.
CREATE SCHEMA st;
CREATE TABLE st.small (id int PRIMARY KEY, v int) WITH (autovacuum_enabled = false);
INSERT INTO st.small SELECT g, g FROM generate_series(1, 100) g;
CREATE INDEX small_v_idx ON st.small (v);

CREATE TABLE st.big (id int PRIMARY KEY, uni int, low int, skew int, lowskew int, nul int, a int, b int, txt text)
  WITH (autovacuum_enabled = false);
INSERT INTO st.big
SELECT g, g, g % 3, CASE WHEN g % 100 = 0 THEN g ELSE 0 END,
       CASE WHEN g % 200 = 0 THEN 2 WHEN g % 20 = 0 THEN 1 ELSE 0 END,
       CASE WHEN g % 10 = 0 THEN g END, g % 50, g % 50, 'Name' || (g % 500)
  FROM generate_series(1, 20000) g;
CREATE INDEX big_uni_idx ON st.big (uni);
CREATE INDEX big_low_idx ON st.big (low);
CREATE INDEX big_skew_idx ON st.big (skew);
-- 3 values at 95%, 4.5% and 0.5%: skewed although distinct values are few.
CREATE INDEX big_lowskew_idx ON st.big (lowskew);
CREATE INDEX big_nul_idx ON st.big (nul);
CREATE INDEX big_nul_partial_idx ON st.big (nul) WHERE nul IS NOT NULL;
CREATE INDEX big_ab_idx ON st.big (a, b) INCLUDE (txt);
CREATE INDEX big_lower_idx ON st.big (lower(txt));

CREATE TABLE st.ev (id int, at date) PARTITION BY RANGE (at);
CREATE TABLE st.ev_1 PARTITION OF st.ev FOR VALUES FROM ('2026-01-01') TO ('2026-07-01') WITH (autovacuum_enabled = false);
CREATE TABLE st.ev_2 PARTITION OF st.ev FOR VALUES FROM ('2026-07-01') TO ('2027-01-01') WITH (autovacuum_enabled = false);
INSERT INTO st.ev SELECT g, date '2026-01-01' + (g % 360) FROM generate_series(1, 3000) g;
CREATE INDEX ev_id_idx ON st.ev (id);

CREATE TABLE st.never (id int, v int) WITH (autovacuum_enabled = false);
INSERT INTO st.never SELECT g, g FROM generate_series(1, 5000) g;
CREATE INDEX never_v_idx ON st.never (v);
-- VACUUM sets the row estimate (PG 18's CREATE INDEX no longer does) but is
-- not an ANALYZE: the table still counts as never analyzed.
VACUUM st.never;

-- Flush this session's pending insert counts first: counts that arrive after
-- ANALYZE would count as changes since the analyze.
SELECT pg_stat_force_next_flush();
ANALYZE st.small, st.big, st.ev;
SELECT pg_stat_force_next_flush();

-- Table level. (st.never was vacuumed but never analyzed.)
SELECT tablename, indexname, key_columns, table_rows_est, small_table, stats_stale,
       index_bytes > 0 AS has_size, cardinality(extended_stats) AS ext
  FROM index_deps.index_table_stats WHERE schemaname = 'st' ORDER BY tablename, indexname;

-- Column level: exact here because ANALYZE read every row.
SELECT indexname, key_position, column_expr, is_expression, has_stats,
       round(null_frac::numeric, 2) AS null_frac, distinct_est, skewed,
       round(top_value_freq::numeric, 2) AS top_freq, histogram_buckets > 0 AS has_histogram
  FROM index_deps.index_column_stats WHERE schemaname = 'st' AND tablename IN ('big', 'small', 'ev')
 ORDER BY indexname, key_position;

-- Hints.
SELECT i.relname AS indexname, h AS hint
  FROM pg_class i JOIN pg_namespace n ON n.oid = i.relnamespace
  CROSS JOIN LATERAL unnest(index_deps.index_hints(i.oid)) AS h
 WHERE n.nspname = 'st' AND i.relkind IN ('i', 'I') AND i.relname NOT LIKE 'ev\_%\_idx'
 ORDER BY 1, 2;

-- Extended statistics on (a, b) remove the independence hint.
CREATE STATISTICS st.big_ab_stats (ndistinct, dependencies) ON a, b FROM st.big;
ANALYZE st.big;
SELECT pg_stat_force_next_flush();
SELECT extended_stats FROM index_deps.index_table_stats WHERE indexname = 'big_ab_idx';
SELECT count(*) AS independence_hints
  FROM unnest(index_deps.index_hints('st.big_ab_idx')) AS h WHERE h LIKE 'multicolumn%';

-- Writes since the last analyze make the statistics stale; writes show as cost.
INSERT INTO st.big (id, uni, low, skew, nul, a, b, txt) SELECT g, g, 0, 0, NULL, 0, 0, 'x' FROM generate_series(20001, 25000) g;
UPDATE st.big SET txt = txt WHERE id <= 100;
SELECT pg_stat_force_next_flush();
SELECT stats_stale, n_mod_since_analyze >= 5000 AS changed, inserts >= 25000 AS inserts_counted,
       updates >= 100 AS updates_counted
  FROM index_deps.index_table_stats WHERE indexname = 'big_uni_idx';
SELECT h LIKE 'statistics stale: % rows changed since the last analyze; run ANALYZE before deciding' AS stale_hint
  FROM unnest(index_deps.index_hints('st.big_uni_idx')) AS h WHERE h LIKE 'statistics stale%';
-- big_uni_idx was never scanned: maintained on every insert for nothing.
-- Once a query uses it, the hint goes away.
SELECT count(*) AS write_cost_hints
  FROM unnest(index_deps.index_hints('st.big_uni_idx')) AS h WHERE h LIKE 'write cost without reads: % inserts and % non-HOT updates (%HOT)';
SET enable_seqscan = off;
SELECT count(*) FROM st.big WHERE uni = 7;
RESET enable_seqscan;
SELECT pg_stat_force_next_flush();
SELECT count(*) AS write_cost_hints_after_scan
  FROM unnest(index_deps.index_hints('st.big_uni_idx')) AS h WHERE h LIKE 'write cost%';

-- index_drop_impact warns that its estimate rests on stale statistics.
-- (Rows for INSERT/UPDATE are "skipped: not a read query" and have no estimate.)
SELECT count(*) > 0 AS evaluated,
       bool_and(note LIKE '%statistics stale: % rows changed since the last analyze; run ANALYZE before deciding%') AS stale_warned
  FROM index_deps.index_drop_impact('st.big_uni_idx')
 WHERE query LIKE '%st.big%' AND note NOT LIKE 'skipped%';

-- The per-index usage view carries the hints.
SELECT indexname, cardinality(hints) > 0 AS has_hints
  FROM index_deps.index_usage WHERE schemaname = 'st' AND indexname IN ('small_v_idx', 'big_uni_idx', 'never_v_idx')
 ORDER BY indexname;

DROP SCHEMA st CASCADE;
UPDATE index_deps.config SET value = 'auto' WHERE key = 'plan_source';
