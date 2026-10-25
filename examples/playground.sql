-- Playground smoke test for pg_stat_index_queries and pg_index_deps.
--
-- Synthetic data only (generate_series + a fixed random seed). Rerunnable:
-- everything lives in schema "playground", which is dropped and recreated,
-- and the statistics are reset at the start of the workload.
--
-- Needs the Docker playground (PG 16+: pg_stat_plans and EXPLAIN GENERIC_PLAN):
--   docker compose -f docker/docker-compose.yml up -d --build db
--   docker compose -f docker/docker-compose.yml exec -T db \
--     psql -U postgres -X -f - < examples/playground.sql
-- or with a host psql:
--   psql postgresql://postgres:postgres@localhost:55432/postgres -X -f examples/playground.sql
--
-- Resets pg_stat_index_queries, pg_stat_statements and pg_stat_plans for the
-- whole server: don't run it against a server whose stats you care about.

\set ON_ERROR_STOP on
\pset footer off
SET client_min_messages = warning;

-- ---------------------------------------------------------------------------
-- Schema and data
-- ---------------------------------------------------------------------------
DROP SCHEMA IF EXISTS playground CASCADE;
CREATE SCHEMA playground;
SET search_path = playground, public;

CREATE TABLE orders (
    id          bigint PRIMARY KEY,
    customer_id int NOT NULL,
    status      text NOT NULL,
    region      text NOT NULL,
    amount      numeric(10,2) NOT NULL,
    created_at  timestamptz NOT NULL
);

SELECT setseed(0.42);
INSERT INTO orders
SELECT g,
       1 + (random() * 4999)::int,
       (ARRAY['new','paid','shipped','delivered','cancelled'])[1 + (random() * 4)::int],
       (ARRAY['north','south','east','west'])[1 + (random() * 3)::int],
       round((5 + random() * 495)::numeric, 2),
       timestamptz '2026-01-01' + (random() * 270) * interval '1 day'
  FROM generate_series(1, 100000) g;

CREATE INDEX orders_customer_idx       ON orders (customer_id);
CREATE INDEX orders_status_created_idx ON orders (status, created_at);
CREATE INDEX orders_created_idx        ON orders (created_at);
CREATE INDEX orders_region_amount_idx  ON orders (region, amount);  -- nothing queries this

-- Same data, range-partitioned by month (Jan-Sep 2026). The index on the
-- parent creates one index per partition; the rollup view folds them back.
CREATE TABLE orders_by_month (LIKE orders) PARTITION BY RANGE (created_at);
SELECT format('CREATE TABLE orders_by_month_%s PARTITION OF orders_by_month
                 FOR VALUES FROM (%L) TO (%L)',
              to_char(m, 'YYYY_MM'), m, m + interval '1 month')
  FROM generate_series(timestamptz '2026-01-01', '2026-09-01', interval '1 month') m
\gexec
INSERT INTO orders_by_month (id, customer_id, status, region, amount, created_at)
SELECT id, customer_id, status, region, amount, created_at FROM orders;
CREATE INDEX orders_by_month_customer_idx ON orders_by_month (customer_id);
CREATE INDEX orders_by_month_region_idx   ON orders_by_month (region);  -- unused

VACUUM ANALYZE orders;
VACUUM ANALYZE orders_by_month;

-- ---------------------------------------------------------------------------
-- Mixed workload. \gexec runs each generated statement as its own top-level
-- statement, like an application would.
-- ---------------------------------------------------------------------------
SELECT pg_stat_index_queries_reset();
SELECT pg_stat_statements_reset() IS NOT NULL AS statements_reset;
SELECT pg_stat_plans_reset() IS NOT NULL AS plans_reset;

SELECT setseed(0.7);
\o /dev/null
-- Point lookups by primary key.
SELECT format('SELECT id, customer_id, status, amount FROM orders WHERE id = %s', 1 + (random() * 99999)::int)
  FROM generate_series(1, 300) \gexec
-- Orders of one customer.
SELECT format('SELECT id, amount FROM orders WHERE customer_id = %s ORDER BY id',
              1 + (random() * 4999)::int)
  FROM generate_series(1, 200) \gexec
-- Recent orders in a status (dashboard).
SELECT format($q$SELECT count(*) FROM orders WHERE status = %L
                   AND created_at >= timestamptz '2026-09-20' - %s * interval '1 day'$q$,
              (ARRAY['new','paid','shipped'])[1 + (random() * 2)::int], 1 + (random() * 6)::int)
  FROM generate_series(1, 100) \gexec
-- Daily revenue for a short window.
SELECT format($q$SELECT date_trunc('day', created_at), sum(amount) FROM orders
                 WHERE created_at BETWEEN timestamptz '2026-06-01' + %s * interval '1 day'
                                      AND timestamptz '2026-06-02' + %s * interval '1 day'
                 GROUP BY 1$q$, g, g)
  FROM generate_series(1, 50) g \gexec
-- Report over the whole table (sequential scan, uses no index).
SELECT format('SELECT region, sum(amount) FROM orders WHERE amount > %s GROUP BY region', g * 10)
  FROM generate_series(1, 20) g \gexec
-- Partitioned table: customer lookups scan every partition's index.
SELECT format('SELECT count(*) FROM orders_by_month WHERE customer_id = %s',
              1 + (random() * 4999)::int)
  FROM generate_series(1, 100) \gexec
-- Partitioned table: one customer in one month (partition pruning).
SELECT format($q$SELECT count(*) FROM orders_by_month WHERE customer_id = %s
                 AND created_at >= '2026-03-01' AND created_at < '2026-04-01'$q$,
              1 + (random() * 4999)::int)
  FROM generate_series(1, 50) \gexec
-- Prepared statement, executed repeatedly.
PREPARE by_customer(int) AS SELECT count(*) FROM orders WHERE customer_id = $1;
EXECUTE by_customer(10);
EXECUTE by_customer(20);
EXECUTE by_customer(30);
DEALLOCATE by_customer;
\o

-- pg_stat_plans flushes call counts lazily; make them visible now.
SELECT pg_stat_force_next_flush();

-- ---------------------------------------------------------------------------
-- Results
-- ---------------------------------------------------------------------------
\echo
\echo '=== pg_stat_index_queries_info'
SELECT entries, dealloc, stats_reset FROM pg_stat_index_queries_info;

\echo
\echo '=== pg_index_dependents (native): which queries use each index'
SELECT d.tablename, d.indexname, d.queryid, d.toplevel,
       d.calls_executed, d.calls_planned,
       left(regexp_replace(s.query, '\s+', ' ', 'g'), 70) AS query
  FROM pg_index_dependents d
  LEFT JOIN (SELECT DISTINCT ON (queryid) queryid, query
               FROM pg_stat_statements ORDER BY queryid, calls DESC) s
    ON s.queryid = d.queryid
 WHERE d.schemaname = 'playground' AND d.tablename = 'orders'
 ORDER BY d.indexname, d.calls_executed DESC;

\echo
\echo '=== pg_index_query_stats (native): each (index, query) with pg_stat_statements stats, slowest first'
SELECT indexname, index_calls_executed AS idx_calls, pct_calls_using_index AS pct,
       other_indexes, calls, round(mean_exec_ms::numeric, 3) AS mean_ms,
       round(total_exec_ms::numeric, 1) AS total_ms, rows_per_call,
       shared_blks_hit AS hit, shared_blks_read AS read, cache_hit_pct AS hit_pct,
       left(regexp_replace(query, '\s+', ' ', 'g'), 50) AS query
  FROM pg_index_query_stats
 WHERE schemaname = 'playground' AND tablename = 'orders'
 ORDER BY total_exec_ms DESC NULLS LAST;

\echo
\echo '=== pg_index_no_dependents (native): no executed use since tracked_since'
SELECT tablename, indexname, pg_size_pretty(index_bytes) AS size, tracked_since
  FROM pg_index_no_dependents
 WHERE schemaname = 'playground'
 ORDER BY tablename, indexname;

\echo
\echo '=== pg_index_dependents_rollup (native): partition indexes rolled up to the parent'
SELECT r.indexname, r.queryid, r.partitions_used, r.calls_executed,
       r.partition_scans_executed,
       left(regexp_replace(s.query, '\s+', ' ', 'g'), 70) AS query
  FROM pg_index_dependents_rollup r
  LEFT JOIN (SELECT DISTINCT ON (queryid) queryid, query
               FROM pg_stat_statements ORDER BY queryid, calls DESC) s
    ON s.queryid = r.queryid
 WHERE r.schemaname = 'playground' AND r.tablename = 'orders_by_month'
 ORDER BY r.indexname, r.partitions_used DESC;

\echo
\echo '=== same data per partition index (what the rollup folds together)'
SELECT tablename, indexname, count(*) AS queries, sum(calls_executed) AS calls_executed
  FROM pg_index_dependents
 WHERE schemaname = 'playground' AND tablename LIKE 'orders_by_month_%'
 GROUP BY 1, 2
 ORDER BY 1, 2;

\echo
\echo '=== index_deps.index_dependents (SQL edition, from pg_stat_plans plan text)'
SELECT tablename, indexname, count(*) AS queries, sum(calls) AS calls,
       string_agg(DISTINCT scan_types, ',') AS scan_types, bool_or(ambiguous) AS ambiguous,
       min(source) AS source
  FROM index_deps.index_dependents
 WHERE schemaname = 'playground' AND tablename = 'orders'
 GROUP BY 1, 2
 ORDER BY 1, 2;

\echo
\echo '=== index_deps.index_query_stats (SQL edition): same, from captured plans'
SELECT indexname, scan_types, index_calls AS idx_calls, other_indexes, calls,
       round(mean_exec_ms::numeric, 3) AS mean_ms, rows_per_call, cache_hit_pct AS hit_pct,
       left(regexp_replace(query, '\s+', ' ', 'g'), 50) AS query
  FROM index_deps.index_query_stats
 WHERE schemaname = 'playground' AND tablename = 'orders'
 ORDER BY total_exec_ms DESC NULLS LAST;

\echo
\echo '=== index_deps.index_drop_impact: used index (orders_customer_idx)'
SELECT queryid, calls, cost_with, cost_without, cost_ratio,
       uses_index_now, uses_index_after, plan_changed, note,
       left(regexp_replace(query, '\s+', ' ', 'g'), 60) AS query
  FROM index_deps.index_drop_impact('playground.orders_customer_idx')
 ORDER BY calls DESC;

\echo
\echo '=== index_deps.index_drop_impact: unused index (orders_region_amount_idx)'
SELECT queryid, calls, cost_with, cost_without, cost_ratio,
       uses_index_now, uses_index_after, plan_changed, note,
       left(regexp_replace(query, '\s+', ' ', 'g'), 60) AS query
  FROM index_deps.index_drop_impact('playground.orders_region_amount_idx')
 ORDER BY calls DESC;

\echo
\echo '=== no index left hidden by the drop-impact checks (expect 0)'
SELECT count(*) AS still_hidden FROM hypopg_hidden_indexes();
