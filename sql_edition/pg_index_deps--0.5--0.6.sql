/* pg_index_deps--0.5--0.6.sql */

\echo Use "ALTER EXTENSION pg_index_deps UPDATE TO '0.6'" to load this file. \quit

-- One row per index: the table it sits on (summed over the leaf partitions
-- of a partitioned table) and the index's own scan counters.
-- table_rows_est is the planner's estimate from the last VACUUM/ANALYZE
-- (NULL if never analyzed). Counters are since the last statistics reset
-- and per instance.
CREATE VIEW index_deps.index_table_stats AS
WITH idx AS (
    SELECT n.nspname AS schemaname, t.relname AS tablename, i.relname AS indexname,
           x.indexrelid, x.indrelid, x.indisunique, x.indpred IS NOT NULL AS is_partial,
           x.indnkeyatts, x.indkey::int2[] AS indkey
      FROM pg_index x
      JOIN pg_class i ON i.oid = x.indexrelid
      JOIN pg_class t ON t.oid = x.indrelid
      JOIN pg_namespace n ON n.oid = i.relnamespace
     WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'index_deps')
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
CREATE VIEW index_deps.index_column_stats AS
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
     WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'index_deps')
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
CREATE FUNCTION index_deps.index_hints(p_index regclass)
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
      FROM index_deps.index_table_stats ts
      LEFT JOIN index_deps.index_column_stats cs ON cs.indexrelid = ts.indexrelid AND cs.key_position = 1
     WHERE ts.indexrelid = p_index
$$;

GRANT SELECT ON index_deps.index_table_stats, index_deps.index_column_stats TO PUBLIC;

-- One row per index (partition indexes folded into their parent): its role,
-- how many captured queries used it, and a verdict.
-- 0.6: hints column (index_hints) at the end.
CREATE OR REPLACE VIEW index_deps.index_usage AS
WITH idx AS (
    SELECT n.nspname AS schemaname, t.relname AS tablename, i.relname AS indexname,
           x.indexrelid, x.indisvalid, t.oid AS tableoid,
           coalesce((SELECT sum(pg_relation_size(p.relid))
                       FROM pg_partition_tree(x.indexrelid) p),
                    pg_relation_size(x.indexrelid))::bigint AS index_bytes
      FROM pg_index x
      JOIN pg_class i ON i.oid = x.indexrelid
      JOIN pg_class t ON t.oid = x.indrelid
      JOIN pg_namespace n ON n.oid = i.relnamespace
     WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'index_deps')
       AND n.nspname NOT LIKE 'pg_toast%'
       AND NOT i.relispartition
),
dep AS (
    SELECT coalesce(pg_partition_root(d.indexrelid), d.indexrelid) AS indexrelid,
           count(DISTINCT d.queryid) AS queries, sum(d.calls)::bigint AS calls,
           bool_or(d.ambiguous) AS ambiguous
      FROM index_deps.index_dependents d
     GROUP BY 1
),
unres AS (
    SELECT u.table_hint, string_agg(DISTINCT u.index_name, ', ') AS names
      FROM index_deps.unresolved_plan_indexes u
     GROUP BY 1
)
SELECT idx.schemaname, idx.tablename, idx.indexname, idx.indexrelid,
       r.index_role, r.index_notes, r.drop_blocker, idx.index_bytes,
       coalesce(dep.queries, 0) AS queries,
       coalesce(dep.calls, 0) AS calls,
       CASE
         WHEN index_deps.resolved_plan_source() = 'none'
           THEN 'unknown: no plan source (use index_drop_impact to test queries)'
         WHEN dep.queries > 0
           THEN format('used by %s %s', dep.queries, CASE WHEN dep.queries = 1 THEN 'query' ELSE 'queries' END)
                || CASE WHEN dep.ambiguous THEN ' (ambiguous name: may be another schema''s index)' ELSE '' END
         WHEN un.names IS NOT NULL
           THEN 'unknown: plans on this table name ' || un.names || ', which no longer exists (renamed or dropped?)'
         WHEN NOT idx.indisvalid
           THEN 'invalid: never used by the planner; drop it or REINDEX'
         WHEN r.drop_blocker IS NOT NULL
           THEN 'no captured query uses it, but ' || r.drop_blocker
         ELSE 'no captured query uses it: drop candidate (check on replicas and over a full business cycle)'
       END AS verdict,
       index_deps.resolved_plan_source() AS source,
       index_deps.index_hints(idx.indexrelid) AS hints
  FROM idx
  CROSS JOIN LATERAL index_deps.index_role(idx.indexrelid) r
  LEFT JOIN dep ON dep.indexrelid = idx.indexrelid
  LEFT JOIN LATERAL (
       SELECT string_agg(DISTINCT u.names, ', ') AS names
         FROM unres u
        WHERE u.table_hint IS NULL OR u.table_hint = idx.tablename
           OR u.table_hint IN (SELECT pt.relname FROM pg_partition_tree(idx.tableoid) a
                                 JOIN pg_class pt ON pt.oid = a.relid)) un ON true;

-- 0.6: the note mentions stale or missing table statistics.
CREATE OR REPLACE FUNCTION index_deps.index_drop_impact(
    p_index         regclass,
    p_include_dml   boolean DEFAULT false,
    p_timeout_ms    integer DEFAULT 30000,
    p_max_queries   integer DEFAULT 50)
RETURNS TABLE (
    queryid          bigint,
    calls            bigint,
    cost_with        float8,
    cost_without     float8,
    cost_ratio       numeric,
    uses_index_now   boolean,
    uses_index_after boolean,
    plan_changed     boolean,
    shape_with       text,
    shape_without    text,
    note             text,
    query            text,
    drop_blocker     text)
LANGUAGE plpgsql VOLATILE
AS $$
DECLARE
    v_index_name   text;
    v_table_name   text;
    v_pred         text;
    v_pred_const   boolean;
    v_blocker      text;
    v_stats_note   text;
    v_hidden       boolean := false;
    v_source       text;
    v_cands        jsonb;
    v_start        timestamptz := clock_timestamp();
    r              record;
    j_with         jsonb;
    j_without      jsonb;
    v_sql          text;
BEGIN
    IF current_setting('server_version_num')::int < 160000 THEN
        RAISE EXCEPTION 'index_drop_impact needs PostgreSQL 16 or later (EXPLAIN GENERIC_PLAN)';
    END IF;
    IF to_regprocedure('hypopg_hide_index(oid)') IS NULL THEN
        RAISE EXCEPTION 'HypoPG 1.4 or later is required'
            USING HINT = 'CREATE EXTENSION hypopg;';
    END IF;
    IF to_regclass('pg_stat_statements') IS NULL THEN
        RAISE EXCEPTION 'pg_stat_statements is required (it provides the query text)';
    END IF;

    -- A partial index whose predicate compares to a constant can't be
    -- matched by a generic plan once pg_stat_statements has replaced the
    -- query's constants with $n. Constant-free predicates (IS NULL) can.
    SELECT ic.relname, tc.relname, pg_get_expr(x.indpred, x.indrelid),
           coalesce(x.indpred::text LIKE '%{CONST %', false)
      INTO v_index_name, v_table_name, v_pred, v_pred_const
      FROM pg_index x
      JOIN pg_class ic ON ic.oid = x.indexrelid
      JOIN pg_class tc ON tc.oid = x.indrelid
     WHERE x.indexrelid = p_index;
    IF NOT FOUND THEN
        RAISE EXCEPTION '% is not an index', p_index;
    END IF;
    SELECT ir.drop_blocker INTO v_blocker FROM index_deps.index_role(p_index) ir;
    -- Estimates are only as good as the table's statistics (T08).
    SELECT string_agg(h, '; ') INTO v_stats_note
      FROM unnest(index_deps.index_hints(p_index)) AS h
     WHERE h LIKE 'statistics stale%' OR h LIKE 'table never analyzed%';

    -- Candidate queries, best source first. Kept in a variable, not a temp
    -- table, so the function runs in read-only transactions.
    IF to_regclass('pg_stat_index_queries') IS NOT NULL THEN
        v_source := 'pg_stat_index_queries';
        EXECUTE $q$
            SELECT jsonb_agg(jsonb_build_array(c.queryid, c.calls))
              FROM (SELECT s.queryid, sum(s.calls_executed) AS calls
                      FROM pg_stat_index_queries s
                     WHERE s.indexrelid = $1
                       AND s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
                     GROUP BY 1) c $q$ INTO v_cands USING p_index::oid;
    END IF;

    IF v_cands IS NULL AND index_deps.resolved_plan_source() <> 'none' THEN
        v_source := 'captured plans';
        SELECT jsonb_agg(jsonb_build_array(c.queryid, c.calls)) INTO v_cands
          FROM (SELECT d.queryid, sum(d.calls) AS calls
                  FROM index_deps.index_dependents d
                 WHERE d.indexrelid = p_index::oid
                 GROUP BY 1) c;
    END IF;

    IF v_cands IS NULL THEN
        -- Fallback: every statement whose text mentions the table.
        v_source := 'query text mentions table';
        EXECUTE $q$
            SELECT jsonb_agg(jsonb_build_array(c.queryid, c.calls))
              FROM (SELECT s.queryid, sum(s.calls) AS calls
                      FROM pg_stat_statements s
                     WHERE s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
                       AND s.query ~* ('\m' || $1 || '\M')
                     GROUP BY 1) c $q$ INTO v_cands USING v_table_name;
    END IF;

    FOR r IN EXECUTE $q$
        SELECT (c.e ->> 0)::bigint AS queryid, (c.e ->> 1)::bigint AS calls, max(s.query) AS query
          FROM jsonb_array_elements(coalesce($2, '[]')) AS c(e)
          JOIN pg_stat_statements s
            ON s.queryid = (c.e ->> 0)::bigint
           AND s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
         GROUP BY 1, 2
         ORDER BY 2 DESC NULLS LAST
         LIMIT $1 $q$ USING p_max_queries, v_cands
    LOOP
        queryid := r.queryid;
        calls := r.calls;
        query := left(r.query, 300);
        drop_blocker := v_blocker;
        cost_with := NULL; cost_without := NULL; cost_ratio := NULL;
        uses_index_now := NULL; uses_index_after := NULL; plan_changed := NULL;
        shape_with := NULL; shape_without := NULL;
        note := 'candidates from ' || v_source || coalesce('; ' || v_stats_note, '');

        IF clock_timestamp() - v_start > make_interval(secs => p_timeout_ms / 1000.0) THEN
            note := format('skipped: time budget used up (p_timeout_ms = %s)', p_timeout_ms);
            RETURN NEXT;
            CONTINUE;
        END IF;

        v_sql := index_deps.explainable_query(r.query);

        IF v_sql !~* '^\s*(select|with|values|table)\M'
           AND NOT (p_include_dml AND v_sql ~* '^\s*(insert|update|delete|merge)\M') THEN
            note := 'skipped: not a read query (set p_include_dml => true to EXPLAIN DML)';
            RETURN NEXT;
            CONTINUE;
        END IF;

        BEGIN
            EXECUTE 'EXPLAIN (GENERIC_PLAN, FORMAT JSON) ' || v_sql INTO j_with;

            PERFORM hypopg_hide_index(p_index::oid);
            v_hidden := true;

            EXECUTE 'EXPLAIN (GENERIC_PLAN, FORMAT JSON) ' || v_sql INTO j_without;

            PERFORM hypopg_unhide_index(p_index::oid);
            v_hidden := false;

            cost_with := (j_with -> 0 -> 'Plan' ->> 'Total Cost')::float8;
            cost_without := (j_without -> 0 -> 'Plan' ->> 'Total Cost')::float8;
            cost_ratio := CASE WHEN cost_with > 0
                               THEN round((cost_without / cost_with)::numeric, 2) END;
            uses_index_now := jsonb_path_exists(j_with, 'strict $.** ? (@."Index Name" == $n)',
                                                jsonb_build_object('n', v_index_name));
            uses_index_after := jsonb_path_exists(j_without, 'strict $.** ? (@."Index Name" == $n)',
                                                  jsonb_build_object('n', v_index_name));
            shape_with := index_deps.plan_shape(j_with);
            shape_without := index_deps.plan_shape(j_without);
            plan_changed := shape_with IS DISTINCT FROM shape_without;

            -- The generic plan doesn't use the index, but recorded plans of
            -- this query did, or the index is partial with a constant in its
            -- predicate (can't be proven against $n parameters: "status = $1"
            -- vs "WHERE status = 'open'"). "Unchanged" would understate the
            -- risk, so report unknown.
            IF NOT uses_index_now
               AND (v_source <> 'query text mentions table' OR v_pred_const) THEN
                plan_changed := NULL;
                note := 'unknown: the generic plan does not use the index'
                        || CASE WHEN v_source <> 'query text mentions table'
                                THEN ' but recorded plans of this query did' ELSE '' END
                        || CASE WHEN v_pred_const
                                THEN '; partial index (WHERE ' || v_pred
                                     || ') cannot be matched to $n parameters' ELSE '' END
                        || '; check with EXPLAIN using real values ('
                        || note || ')';
            END IF;

            -- HypoPG hypothetical indexes in this session take part in both
            -- plans, so the result isn't about the real schema.
            IF concat(shape_with, shape_without) ~ 'using <[0-9]+>' THEN
                note := note || '; warning: the plans use a hypothetical HypoPG index from this session'
                             || ' (hypopg_reset() to remove), so this is not the real schema';
            END IF;
        EXCEPTION
            WHEN query_canceled THEN
                -- Cancelled (statement_timeout, pg_cancel_backend): unhide,
                -- or the index stays hidden for the rest of the session.
                IF v_hidden THEN
                    PERFORM hypopg_unhide_index(p_index::oid);
                END IF;
                RAISE;
            WHEN OTHERS THEN
                -- HypoPG state lives in backend memory, not in the
                -- transaction, so it must be undone here explicitly.
                IF v_hidden THEN
                    PERFORM hypopg_unhide_index(p_index::oid);
                    v_hidden := false;
                END IF;
                note := 'skipped: ' || SQLERRM;
        END;

        RETURN NEXT;
    END LOOP;

    IF v_hidden THEN
        PERFORM hypopg_unhide_index(p_index::oid);
    END IF;
    RETURN;
END;
$$;

