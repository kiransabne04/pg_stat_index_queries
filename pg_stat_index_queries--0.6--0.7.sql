/* pg_stat_index_queries--0.6--0.7.sql */

\echo Use "ALTER EXTENSION pg_stat_index_queries UPDATE TO '0.7'" to load this file. \quit

-- One row per index: the table it sits on (summed over the leaf partitions
-- of a partitioned table) and the index's own scan counters.
-- table_rows_est is the planner's estimate from the last VACUUM/ANALYZE
-- (NULL if never analyzed). Counters are since the last statistics reset
-- and per instance.
CREATE VIEW pg_index_table_stats AS
WITH idx AS (
    SELECT n.nspname AS schemaname, t.relname AS tablename, i.relname AS indexname,
           x.indexrelid, x.indrelid, x.indisunique, x.indpred IS NOT NULL AS is_partial,
           x.indnkeyatts, x.indkey::int2[] AS indkey
      FROM pg_index x
      JOIN pg_class i ON i.oid = x.indexrelid
      JOIN pg_class t ON t.oid = x.indrelid
      JOIN pg_namespace n ON n.oid = i.relnamespace
     WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
       AND n.nspname NOT LIKE 'pg_toast%'
),
tbl AS (
    SELECT idx.indexrelid,
           sum(c.reltuples) FILTER (WHERE c.reltuples >= 0) AS rows_est,
           bool_or(c.reltuples < 0) AS has_unanalyzed_part,
           sum(c.relpages)::bigint AS pages,
           sum(pg_relation_size(c.oid))::bigint AS table_bytes,
           sum(s.n_live_tup)::bigint AS n_live_tup,
           sum(s.n_dead_tup)::bigint AS n_dead_tup,
           sum(s.n_tup_ins)::bigint AS inserts,
           sum(s.n_tup_upd)::bigint AS updates,
           sum(s.n_tup_hot_upd)::bigint AS hot_updates,
           sum(s.n_tup_del)::bigint AS deletes,
           sum(s.seq_scan)::bigint AS seq_scan,
           sum(s.seq_tup_read)::bigint AS seq_tup_read,
           sum(s.idx_scan)::bigint AS table_idx_scan,
           max(greatest(s.last_analyze, s.last_autoanalyze)) AS last_analyzed,
           sum(s.n_mod_since_analyze)::bigint AS n_mod_since_analyze,
           -- Same rule as autovacuum's analyze trigger (50 rows + 10%), per partition.
           bool_or(greatest(s.last_analyze, s.last_autoanalyze) IS NULL
                   OR s.n_mod_since_analyze > 50 + 0.1 * greatest(c.reltuples, 0)) AS stats_stale
      FROM idx
      -- Leaf partitions; pg_partition_tree() returns nothing for a table
      -- outside any partition tree, so fall back to the table itself.
      CROSS JOIN LATERAL (SELECT p.relid FROM pg_partition_tree(idx.indrelid) p WHERE p.isleaf
                          UNION ALL
                          SELECT idx.indrelid WHERE NOT EXISTS (SELECT 1 FROM pg_partition_tree(idx.indrelid))) l
      JOIN pg_class c ON c.oid = l.relid
      LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
     GROUP BY idx.indexrelid
),
ist AS (
    SELECT idx.indexrelid,
           sum(pg_relation_size(p.relid))::bigint AS index_bytes,
           sum(si.idx_scan)::bigint AS idx_scan,
           sum(si.idx_tup_read)::bigint AS idx_tup_read,
           sum(si.idx_tup_fetch)::bigint AS idx_tup_fetch,
           -- last_idx_scan exists from PG 16; read through jsonb so 15 works too.
           max((to_jsonb(si) ->> 'last_idx_scan')::timestamptz) AS last_idx_scan
      FROM idx
      CROSS JOIN LATERAL (SELECT p.relid FROM pg_partition_tree(idx.indexrelid) p
                          UNION ALL
                          SELECT idx.indexrelid WHERE NOT EXISTS (SELECT 1 FROM pg_partition_tree(idx.indexrelid))) p
      LEFT JOIN pg_stat_user_indexes si ON si.indexrelid = p.relid
     GROUP BY idx.indexrelid
),
ext AS (
    SELECT idx.indexrelid,
           array_agg(DISTINCT e.stxname::text ORDER BY e.stxname::text) AS extended_stats
      FROM idx
      JOIN pg_statistic_ext e ON e.stxrelid = idx.indrelid
     WHERE (SELECT count(*) FROM unnest(e.stxkeys::int2[]) AS k(attnum)
             WHERE k.attnum = ANY (idx.indkey[0:idx.indnkeyatts - 1])) >= 2
     GROUP BY idx.indexrelid
)
SELECT idx.schemaname, idx.tablename, idx.indexname, idx.indexrelid,
       idx.indisunique AS is_unique, idx.is_partial,
       idx.indnkeyatts AS key_columns,
       CASE WHEN tbl.has_unanalyzed_part THEN NULL ELSE tbl.rows_est END AS table_rows_est,
       tbl.pages AS table_pages, tbl.table_bytes, ist.index_bytes,
       round(100.0 * ist.index_bytes / nullif(tbl.table_bytes, 0), 1) AS index_to_table_pct,
       tbl.n_live_tup, tbl.n_dead_tup,
       round(100.0 * tbl.n_dead_tup / nullif(tbl.n_live_tup + tbl.n_dead_tup, 0), 1) AS dead_pct,
       tbl.inserts, tbl.updates, tbl.hot_updates, tbl.deletes,
       round(100.0 * tbl.hot_updates / nullif(tbl.updates, 0), 1) AS hot_update_pct,
       tbl.seq_scan, tbl.seq_tup_read, tbl.table_idx_scan,
       ist.idx_scan, ist.idx_tup_read, ist.idx_tup_fetch, ist.last_idx_scan,
       tbl.last_analyzed, tbl.n_mod_since_analyze, coalesce(tbl.stats_stale, true) AS stats_stale,
       -- Only when the size is known (a never-vacuumed, never-analyzed table has none).
       coalesce(NOT tbl.has_unanalyzed_part AND (tbl.rows_est < 1000 OR tbl.pages < 8), false) AS small_table,
       coalesce(ext.extended_stats, '{}') AS extended_stats
  FROM idx
  LEFT JOIN tbl ON tbl.indexrelid = idx.indexrelid
  LEFT JOIN ist ON ist.indexrelid = idx.indexrelid
  LEFT JOIN ext ON ext.indexrelid = idx.indexrelid;

-- One row per index key column (INCLUDE columns left out) with the
-- planner's statistics from pg_stats. Expression columns use the statistics
-- ANALYZE keeps for the index itself. Columns the caller can't SELECT, or
-- tables never analyzed, have has_stats = false. All values are estimates
-- from the ANALYZE sample.
CREATE VIEW pg_index_column_stats AS
WITH idx AS (
    SELECT n.nspname AS schemaname, t.relname AS tablename, i.relname AS indexname,
           x.indexrelid, x.indrelid, x.indnkeyatts, x.indkey::int2[] AS indkey,
           t.relkind = 'p' AS partitioned,
           (SELECT sum(c.reltuples) FILTER (WHERE c.reltuples >= 0)
              FROM (SELECT p.relid FROM pg_partition_tree(x.indrelid) p WHERE p.isleaf
                    UNION ALL
                    SELECT x.indrelid WHERE NOT EXISTS (SELECT 1 FROM pg_partition_tree(x.indrelid))) l
              JOIN pg_class c ON c.oid = l.relid) AS rows_est
      FROM pg_index x
      JOIN pg_class i ON i.oid = x.indexrelid
      JOIN pg_class t ON t.oid = x.indrelid
      JOIN pg_namespace n ON n.oid = i.relnamespace
     WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
       AND n.nspname NOT LIKE 'pg_toast%'
),
col AS (
    SELECT idx.schemaname, idx.tablename, idx.indexname, idx.indexrelid, idx.rows_est,
           k.pos AS key_position,
           idx.indkey[k.pos - 1] = 0 AS is_expression,
           CASE WHEN idx.indkey[k.pos - 1] = 0 THEN pg_get_indexdef(idx.indexrelid, k.pos, true)
                ELSE ta.attname::text END AS column_expr,
           coalesce(st.null_frac, se.null_frac) AS null_frac,
           coalesce(st.avg_width, se.avg_width) AS avg_width,
           coalesce(st.n_distinct, se.n_distinct) AS n_distinct,
           coalesce(st.most_common_vals, se.most_common_vals)::text::text[] AS mcv,
           coalesce(st.most_common_freqs, se.most_common_freqs) AS mcf,
           coalesce(st.histogram_bounds, se.histogram_bounds)::text::text[] AS hist,
           coalesce(st.correlation, se.correlation) AS correlation,
           (st.attname IS NOT NULL OR se.attname IS NOT NULL) AS has_stats
      FROM idx
      CROSS JOIN LATERAL generate_series(1, idx.indnkeyatts) AS k(pos)
      JOIN pg_attribute ia ON ia.attrelid = idx.indexrelid AND ia.attnum = k.pos
      LEFT JOIN pg_attribute ta ON ta.attrelid = idx.indrelid AND ta.attnum = idx.indkey[k.pos - 1]
                               AND idx.indkey[k.pos - 1] <> 0
      LEFT JOIN pg_stats st ON idx.indkey[k.pos - 1] <> 0
                           AND st.schemaname = idx.schemaname AND st.tablename = idx.tablename
                           AND st.attname = ta.attname AND st.inherited = idx.partitioned
      LEFT JOIN pg_stats se ON idx.indkey[k.pos - 1] = 0
                           AND se.schemaname = idx.schemaname AND se.tablename = idx.indexname
                           AND se.attname = ia.attname
),
calc AS (
    SELECT col.schemaname, col.tablename, col.indexname, col.indexrelid, col.key_position,
           col.column_expr, col.is_expression, col.has_stats, col.null_frac, col.avg_width,
           col.n_distinct, col.mcv, col.mcf, col.hist, col.correlation,
           CASE WHEN col.n_distinct > 0 THEN col.n_distinct
                WHEN col.n_distinct < 0 THEN -col.n_distinct * col.rows_est END AS distinct_est,
           col.rows_est
      FROM col
)
SELECT schemaname, tablename, indexname, indexrelid, key_position, column_expr, is_expression,
       has_stats, null_frac, avg_width, n_distinct,
       round(distinct_est::numeric) AS distinct_est,
       round((rows_est * (1 - null_frac) / nullif(distinct_est, 0))::numeric, 1) AS rows_per_value_est,
       round(((1 - null_frac) / nullif(distinct_est, 0))::numeric, 6) AS equality_selectivity_est,
       mcv[1:5] AS most_common_vals,
       mcf[1:5] AS most_common_freqs,
       round((SELECT sum(f) FROM unnest(mcf) AS u(f))::numeric, 4) AS mcv_total_freq,
       mcf[1] AS top_value_freq,
       -- Skewed: the most common value covers at least 10% of the rows and
       -- either 5 times the average share of a value or 10 times the share
       -- of the rarest common value (with few distinct values the average
       -- is large, e.g. 95/4.5/0.5% over 3 values).
       coalesce(mcf[1] >= 0.10
                AND (mcf[1] > 5 * (1 - null_frac) / nullif(distinct_est, 0)
                     OR mcf[1] >= 10 * mcf[cardinality(mcf)]), false) AS skewed,
       greatest(cardinality(hist) - 1, 0) AS histogram_buckets,
       correlation
  FROM calc;

-- Plain-language hints from the statistics above, for one index.
CREATE FUNCTION pg_index_hints(p_index regclass)
RETURNS text[]
LANGUAGE sql STABLE
AS $$
    SELECT array_remove(ARRAY[
        CASE WHEN ts.small_table
             THEN format('tiny table (~%s rows in %s %s): the planner may prefer a sequential scan anyway',
                         coalesce(ts.table_rows_est::bigint::text, '?'), ts.table_pages,
                         CASE WHEN ts.table_pages = 1 THEN 'page' ELSE 'pages' END) END,
        CASE WHEN ts.stats_stale AND ts.last_analyzed IS NULL
             THEN 'table never analyzed: planner estimates and these hints are guesses; run ANALYZE'
             WHEN ts.stats_stale
             THEN format('statistics stale: %s rows changed since the last analyze; run ANALYZE before deciding',
                         ts.n_mod_since_analyze) END,
        CASE WHEN cs.has_stats AND cs.distinct_est <= 10 AND NOT ts.is_unique AND NOT cs.skewed
             THEN format('leading column %s has only ~%s distinct values: an equality lookup returns ~%s%% of the table, so the planner rarely uses this index for it',
                         cs.column_expr, cs.distinct_est, round(100 * cs.equality_selectivity_est, 1)) END,
        CASE WHEN cs.skewed
             THEN format('leading column %s is skewed (top value %s%% of rows): the index helps queries on rare values only',
                         cs.column_expr, round((100 * cs.top_value_freq)::numeric, 1)) END,
        CASE WHEN cs.null_frac >= 0.5 AND NOT ts.is_partial
             THEN format('leading column %s is %s%% NULL: a partial index WHERE %s IS NOT NULL would be smaller',
                         cs.column_expr, round((100 * cs.null_frac)::numeric), cs.column_expr) END,
        CASE WHEN ts.key_columns >= 2 AND cardinality(ts.extended_stats) = 0
             THEN 'multicolumn index without extended statistics on its columns: the planner assumes they are independent (CREATE STATISTICS can help)' END,
        -- Maintained but never read: every write pays for it, no query gains.
        CASE WHEN coalesce(ts.idx_scan, 0) = 0
              AND coalesce(ts.inserts, 0) + coalesce(ts.updates, 0) - coalesce(ts.hot_updates, 0) > 0
             THEN format('write cost without reads: not scanned since the statistics reset, but maintained on %s inserts and %s non-HOT updates%s',
                         coalesce(ts.inserts, 0), coalesce(ts.updates, 0) - coalesce(ts.hot_updates, 0),
                         CASE WHEN ts.updates > 0 THEN format(' (%s%% of updates were HOT)', ts.hot_update_pct) ELSE '' END) END
    ]::text[], NULL)
      FROM pg_index_table_stats ts
      LEFT JOIN pg_index_column_stats cs ON cs.indexrelid = ts.indexrelid AND cs.key_position = 1
     WHERE ts.indexrelid = p_index
$$;

GRANT SELECT ON pg_index_table_stats, pg_index_column_stats TO PUBLIC;

-- One row per index (partition indexes folded into their parent): its role,
-- recorded use since tracked_since, and a verdict. Evictions
-- (pg_stat_index_queries_info.dealloc > 0) and sampling (sample_rate < 1
-- skipped statements) make "no recorded use" unknown.
-- 0.7: hints column (pg_index_hints) at the end.
CREATE OR REPLACE VIEW pg_index_usage AS
WITH info AS (
    SELECT stats_reset, dealloc, pg_stat_index_queries_sampled() AS sampled
      FROM pg_stat_index_queries_info()
),
idx AS (
    SELECT n.nspname AS schemaname, t.relname AS tablename, i.relname AS indexname,
           x.indexrelid, x.indisvalid,
           coalesce((SELECT sum(pg_relation_size(p.relid))
                       FROM pg_partition_tree(x.indexrelid) p),
                    pg_relation_size(x.indexrelid))::bigint AS index_bytes
      FROM pg_index x
      JOIN pg_class i ON i.oid = x.indexrelid
      JOIN pg_class t ON t.oid = x.indrelid
      JOIN pg_namespace n ON n.oid = i.relnamespace
     WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
       AND n.nspname NOT LIKE 'pg_toast%'
       AND NOT i.relispartition
),
used AS (
    SELECT coalesce(pg_partition_root(s.indexrelid), s.indexrelid) AS indexrelid,
           count(DISTINCT s.queryid) AS queries,
           sum(s.calls_executed)::bigint AS calls_executed,
           max(s.last_seen) AS last_seen
      FROM pg_stat_index_queries() s
     WHERE s.calls_executed > 0
       AND s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
       AND EXISTS (SELECT 1 FROM pg_class c WHERE c.oid = s.indexrelid)
     GROUP BY 1
)
SELECT idx.schemaname, idx.tablename, idx.indexname, idx.indexrelid,
       r.index_role, r.index_notes, r.drop_blocker, idx.index_bytes,
       coalesce(used.queries, 0) AS queries,
       coalesce(used.calls_executed, 0) AS calls_executed,
       used.last_seen,
       info.stats_reset AS tracked_since,
       CASE
         WHEN used.queries > 0
           THEN format('used by %s %s', used.queries, CASE WHEN used.queries = 1 THEN 'query' ELSE 'queries' END)
                || CASE WHEN info.sampled THEN ' (counts estimated: sampling)' ELSE '' END
         WHEN NOT idx.indisvalid
           THEN 'invalid: never used by the planner; drop it or REINDEX'
         WHEN info.dealloc > 0
           THEN format('unknown: %s entries were evicted since %s (raise pg_stat_index_queries.max)',
                       info.dealloc, info.stats_reset)
         WHEN info.sampled
           THEN format('unknown: sample_rate < 1 skipped statements since %s; a rarely used index can be missed',
                       info.stats_reset)
         WHEN r.drop_blocker IS NOT NULL
           THEN format('no recorded use since %s, but %s', info.stats_reset, r.drop_blocker)
         ELSE format('no recorded use since %s: drop candidate (check replicas and a full business cycle)',
                     info.stats_reset)
       END AS verdict,
       pg_index_hints(idx.indexrelid) AS hints
  FROM idx
  CROSS JOIN info
  CROSS JOIN LATERAL pg_index_role(idx.indexrelid) r
  LEFT JOIN used ON used.indexrelid = idx.indexrelid;
