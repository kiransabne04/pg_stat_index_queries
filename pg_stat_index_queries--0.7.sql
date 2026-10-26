/* pg_stat_index_queries--0.7.sql */

\echo Use "CREATE EXTENSION pg_stat_index_queries" to load this file. \quit

CREATE FUNCTION pg_stat_index_queries(
    OUT dbid oid,
    OUT indexrelid oid,
    OUT queryid bigint,
    OUT toplevel bool,
    OUT calls_executed bigint,
    OUT calls_planned bigint,
    OUT first_seen timestamptz,
    OUT last_seen timestamptz
)
RETURNS SETOF record
AS 'MODULE_PATHNAME', 'pg_stat_index_queries'
LANGUAGE C STRICT VOLATILE PARALLEL SAFE;

CREATE VIEW pg_stat_index_queries AS
    SELECT dbid, indexrelid, queryid, toplevel, calls_executed, calls_planned,
           first_seen, last_seen
      FROM pg_stat_index_queries();

CREATE FUNCTION pg_stat_index_queries_reset()
RETURNS void
AS 'MODULE_PATHNAME', 'pg_stat_index_queries_reset'
LANGUAGE C STRICT VOLATILE PARALLEL SAFE;

CREATE FUNCTION pg_stat_index_queries_info(
    OUT entries bigint,
    OUT dealloc bigint,
    OUT stats_reset timestamptz
)
RETURNS record
AS 'MODULE_PATHNAME', 'pg_stat_index_queries_info'
LANGUAGE C STRICT VOLATILE PARALLEL SAFE;

CREATE VIEW pg_stat_index_queries_info AS
    SELECT entries, dealloc, stats_reset FROM pg_stat_index_queries_info();

-- True if pg_stat_index_queries.sample_rate < 1 skipped any statement since
-- the last reset (then counts are estimates and "no recorded use" is unsure).
CREATE FUNCTION pg_stat_index_queries_sampled()
RETURNS boolean
AS 'MODULE_PATHNAME', 'pg_stat_index_queries_sampled'
LANGUAGE C STRICT VOLATILE PARALLEL SAFE;

-- What an index is for besides speeding up queries, and what dropping it
-- would break. index_role: primary key | unique constraint | exclusion
-- constraint | unique index | index. index_notes: foreign keys that
-- reference it, replica identity, clustered, invalid, partial, expression,
-- partitions. drop_blocker: why DROP INDEX fails or changes behaviour
-- (NULL when nothing but query speed depends on it).
CREATE FUNCTION pg_index_role(
    p_index regclass,
    OUT index_role text,
    OUT index_notes text[],
    OUT drop_blocker text)
LANGUAGE sql STABLE
AS $$
    WITH ix AS (
        SELECT x.indexrelid, x.indrelid, x.indisunique, x.indisreplident, x.indisclustered,
               x.indisvalid, x.indpred, x.indexprs, i.relkind, i.relispartition,
               (SELECT ip.inhparent::regclass::text FROM pg_inherits ip
                 WHERE ip.inhrelid = x.indexrelid) AS parent_index,
               to_jsonb(x) ->> 'indnullsnotdistinct' AS nulls_not_distinct
          FROM pg_index x JOIN pg_class i ON i.oid = x.indexrelid
         WHERE x.indexrelid = p_index
    ),
    k AS (
        SELECT c.conname, c.contype, c.condeferrable
          FROM pg_constraint c, ix
         WHERE c.conindid = ix.indexrelid AND c.conrelid = ix.indrelid
           AND c.contype IN ('p', 'u', 'x')
         LIMIT 1
    ),
    fk AS (
        SELECT array_agg(format('referenced by foreign key %s on %s', f.conname, f.conrelid::regclass)
                         ORDER BY f.conrelid::regclass::text, f.conname) AS refs
          FROM pg_constraint f, ix
         WHERE f.contype = 'f' AND f.conindid = ix.indexrelid AND f.conparentid = 0
    ),
    r AS (
        SELECT ix.indexrelid, ix.indrelid, ix.indisunique, ix.indisreplident, ix.indisclustered,
               ix.indisvalid, ix.indpred, ix.indexprs, ix.relkind, ix.relispartition,
               ix.parent_index, ix.nulls_not_distinct,
               k.conname, k.contype, k.condeferrable, fk.refs,
               CASE k.contype WHEN 'p' THEN 'primary key'
                              WHEN 'u' THEN 'unique constraint'
                              WHEN 'x' THEN 'exclusion constraint'
                              ELSE CASE WHEN ix.indisunique THEN 'unique index' ELSE 'index' END
               END AS role
          FROM ix LEFT JOIN k ON true LEFT JOIN fk ON true
    )
    SELECT r.role,
           array_remove(ARRAY[
               CASE WHEN r.condeferrable THEN 'deferrable constraint' END,
               CASE WHEN r.nulls_not_distinct = 'true' THEN 'nulls not distinct' END,
               CASE WHEN r.indisreplident THEN 'replica identity' END,
               CASE WHEN r.indisclustered THEN 'clustered (CLUSTER uses it)' END,
               CASE WHEN NOT r.indisvalid THEN 'invalid: the planner never uses it (failed CREATE INDEX CONCURRENTLY?)' END,
               CASE WHEN r.indpred IS NOT NULL THEN 'partial: WHERE ' || pg_get_expr(r.indpred, r.indrelid) END,
               CASE WHEN r.indexprs IS NOT NULL THEN 'expression index' END,
               CASE WHEN r.relkind = 'I' THEN 'partitioned index (one index per partition)' END,
               CASE WHEN r.relispartition THEN 'partition of index ' || r.parent_index END
           ]::text[], NULL) || coalesce(r.refs, '{}'),
           nullif(concat_ws('; ',
               CASE WHEN r.contype IS NOT NULL
                    THEN format('enforces %s %s: DROP INDEX fails, dropping the constraint removes the guarantee',
                                r.role, r.conname) END,
               CASE WHEN r.contype IS NULL AND r.indisunique
                    THEN 'enforces uniqueness: dropping it allows duplicates' END,
               CASE WHEN r.refs IS NOT NULL
                    THEN 'foreign keys depend on it: ' || array_to_string(r.refs, ', ') END,
               CASE WHEN r.indisreplident
                    THEN 'replica identity: logical replication and CDC use it' END,
               CASE WHEN r.relispartition
                    THEN 'attached to partitioned index ' || r.parent_index || ': drop that instead' END
           ), '')
      FROM r
$$;

-- Indexes in the current database and the queries that used them.
-- Join to pg_stat_statements on (dbid, queryid) for query text.
CREATE VIEW pg_index_dependents AS
    SELECT n.nspname AS schemaname,
           t.relname AS tablename,
           i.relname AS indexname,
           s.indexrelid,
           s.queryid,
           s.toplevel,
           s.calls_executed,
           s.calls_planned,
           s.first_seen,
           s.last_seen,
           (SELECT r.index_role FROM pg_index_role(s.indexrelid) r) AS index_role
      FROM pg_stat_index_queries() s
      JOIN pg_class i ON i.oid = s.indexrelid
      JOIN pg_index x ON x.indexrelid = s.indexrelid
      JOIN pg_class t ON t.oid = x.indrelid
      JOIN pg_namespace n ON n.oid = i.relnamespace
     WHERE s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database());

-- User indexes with no recorded executed use since the last reset.
-- Excludes primary keys, unique indexes and constraint-backed indexes.
-- Partitioned tables: one row per partitioned (parent) index, which counts
-- as used when any index in its partition tree was used; index_bytes is the
-- whole tree. Attached partition indexes aren't listed on their own (they
-- can't be dropped separately from the parent).
-- ALWAYS check tracked_since before acting on this list.
CREATE VIEW pg_index_no_dependents AS
    SELECT n.nspname AS schemaname,
           t.relname AS tablename,
           i.relname AS indexname,
           x.indexrelid,
           coalesce((SELECT sum(pg_relation_size(p.relid))
                       FROM pg_partition_tree(x.indexrelid) p),
                    pg_relation_size(x.indexrelid))::bigint AS index_bytes,
           (SELECT stats_reset FROM pg_stat_index_queries_info()) AS tracked_since
      FROM pg_index x
      JOIN pg_class i ON i.oid = x.indexrelid
      JOIN pg_class t ON t.oid = x.indrelid
      JOIN pg_namespace n ON n.oid = i.relnamespace
     WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
       AND n.nspname NOT LIKE 'pg_toast%'
       AND NOT x.indisprimary
       AND NOT x.indisunique
       AND NOT i.relispartition
       AND NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conindid = x.indexrelid)
       AND NOT EXISTS (
            SELECT 1 FROM pg_stat_index_queries() s
             WHERE coalesce(pg_partition_root(s.indexrelid), s.indexrelid) = x.indexrelid
               AND s.calls_executed > 0
               AND s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database()));

REVOKE ALL ON FUNCTION pg_stat_index_queries_reset() FROM PUBLIC;
GRANT SELECT ON pg_stat_index_queries, pg_stat_index_queries_info,
                pg_index_dependents, pg_index_no_dependents TO PUBLIC;

-- Partitioned tables: roll child-partition indexes up to the partitioned
-- (parent) index. Non-partition indexes map to themselves.
-- calls_executed = most calls on any one partition index (a lower bound on
-- statements, since one statement can scan several partitions);
-- partition_scans_executed = total across partitions.
CREATE VIEW pg_index_dependents_rollup AS
    SELECT n.nspname AS schemaname,
           t.relname AS tablename,
           i.relname AS indexname,
           r.root_indexrelid AS indexrelid,
           r.queryid,
           r.toplevel,
           r.partitions_used,
           r.calls_executed,
           r.calls_planned,
           r.partition_scans_executed,
           r.first_seen,
           r.last_seen
      FROM (SELECT coalesce(pg_partition_root(s.indexrelid), s.indexrelid) AS root_indexrelid,
                   s.queryid,
                   s.toplevel,
                   count(*) AS partitions_used,
                   max(s.calls_executed)::bigint AS calls_executed,
                   max(s.calls_planned)::bigint AS calls_planned,
                   sum(s.calls_executed)::bigint AS partition_scans_executed,
                   min(s.first_seen) AS first_seen,
                   max(s.last_seen) AS last_seen
              FROM pg_stat_index_queries() s
             WHERE s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
               AND EXISTS (SELECT 1 FROM pg_class c WHERE c.oid = s.indexrelid)
             GROUP BY 1, 2, 3) r
      JOIN pg_class i ON i.oid = r.root_indexrelid
      JOIN pg_index x ON x.indexrelid = r.root_indexrelid
      JOIN pg_class t ON t.oid = x.indrelid
      JOIN pg_namespace n ON n.oid = i.relnamespace;

GRANT SELECT ON pg_index_dependents_rollup TO PUBLIC;

-- One row per (index, query) recorded since the last reset, with what a
-- developer needs to debug it: the index definition and size, how often the
-- query used the index, which other indexes it used, and the query's
-- statistics from pg_stat_statements (summed over roles; times in ms).
-- Statistics are NULL when pg_stat_statements no longer has the query
-- (evicted or reset); the row stays because the dependency is still real.
-- pg_stat_statements is looked up when called, not at install time, so it
-- can be installed, dropped or moved independently of this extension.
CREATE FUNCTION pg_index_query_stats(
    OUT schemaname name,
    OUT tablename name,
    OUT indexname name,
    OUT indexrelid oid,
    OUT indexdef text,
    OUT index_bytes bigint,
    OUT is_unique bool,
    OUT is_partial bool,
    OUT index_role text,
    OUT index_notes text[],
    OUT queryid bigint,
    OUT toplevel bool,
    OUT index_calls_executed bigint,
    OUT index_calls_planned bigint,
    OUT pct_calls_using_index numeric,
    OUT first_seen timestamptz,
    OUT last_seen timestamptz,
    OUT other_indexes text[],
    OUT calls bigint,
    OUT total_exec_ms float8,
    OUT mean_exec_ms float8,
    OUT min_exec_ms float8,
    OUT max_exec_ms float8,
    OUT plans bigint,
    OUT total_plan_ms float8,
    OUT mean_plan_ms float8,
    OUT rows bigint,
    OUT rows_per_call numeric,
    OUT shared_blks_hit bigint,
    OUT shared_blks_read bigint,
    OUT cache_hit_pct numeric,
    OUT shared_blks_dirtied bigint,
    OUT shared_blks_written bigint,
    OUT temp_blks_read bigint,
    OUT temp_blks_written bigint,
    OUT io_read_ms float8,
    OUT io_write_ms float8,
    OUT wal_bytes numeric,
    OUT roles name[],
    OUT query text
)
RETURNS SETOF record
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_pgss text;
BEGIN
    SELECT format('%I.pg_stat_statements', n.nspname) INTO v_pgss
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
     WHERE e.extname = 'pg_stat_statements';
    IF v_pgss IS NULL THEN
        RAISE EXCEPTION 'pg_index_query_stats needs pg_stat_statements'
            USING HINT = 'Add pg_stat_statements to shared_preload_libraries, restart, then CREATE EXTENSION pg_stat_statements;';
    END IF;

    -- blk_read_time/blk_write_time were renamed shared_blk_*_time in PG 17;
    -- read them through jsonb so the same text works on 15-18.
    RETURN QUERY EXECUTE format($q$
        WITH d AS (
            SELECT schemaname, tablename, indexname, indexrelid, queryid, toplevel,
                   calls_executed, calls_planned, first_seen, last_seen
              FROM pg_index_dependents
        ),
        s AS (
            SELECT p.queryid, p.toplevel,
                   sum(p.calls)::bigint               AS calls,
                   sum(p.total_exec_time)             AS total_exec_ms,
                   min(p.min_exec_time)               AS min_exec_ms,
                   max(p.max_exec_time)               AS max_exec_ms,
                   sum(p.plans)::bigint               AS plans,
                   sum(p.total_plan_time)             AS total_plan_ms,
                   sum(p.rows)::bigint                AS rows,
                   sum(p.shared_blks_hit)::bigint     AS shared_blks_hit,
                   sum(p.shared_blks_read)::bigint    AS shared_blks_read,
                   sum(p.shared_blks_dirtied)::bigint AS shared_blks_dirtied,
                   sum(p.shared_blks_written)::bigint AS shared_blks_written,
                   sum(p.temp_blks_read)::bigint      AS temp_blks_read,
                   sum(p.temp_blks_written)::bigint   AS temp_blks_written,
                   sum(coalesce(j->>'shared_blk_read_time', j->>'blk_read_time')::float8)   AS io_read_ms,
                   sum(coalesce(j->>'shared_blk_write_time', j->>'blk_write_time')::float8) AS io_write_ms,
                   sum(p.wal_bytes)                   AS wal_bytes,
                   array_agg(DISTINCT r.rolname ORDER BY r.rolname) AS roles,
                   max(p.query)                       AS query
              FROM %s p
              CROSS JOIN LATERAL to_jsonb(p) AS j
              LEFT JOIN pg_roles r ON r.oid = p.userid
             WHERE p.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
               AND p.queryid IN (SELECT d.queryid FROM d)
             GROUP BY p.queryid, p.toplevel
        )
        SELECT d.schemaname, d.tablename, d.indexname, d.indexrelid,
               pg_get_indexdef(d.indexrelid),
               pg_relation_size(d.indexrelid),
               x.indisunique,
               x.indpred IS NOT NULL,
               ir.index_role, ir.index_notes,
               d.queryid, d.toplevel,
               d.calls_executed, d.calls_planned,
               round(100.0 * d.calls_executed / nullif(s.calls, 0), 1),
               d.first_seen, d.last_seen,
               (SELECT array_agg(o.indexrelid::regclass::text ORDER BY o.indexrelid::regclass::text)
                  FROM d o
                 WHERE o.queryid = d.queryid AND o.toplevel = d.toplevel
                   AND o.indexrelid <> d.indexrelid),
               s.calls, s.total_exec_ms, s.total_exec_ms / nullif(s.calls, 0),
               s.min_exec_ms, s.max_exec_ms,
               s.plans, s.total_plan_ms, s.total_plan_ms / nullif(s.plans, 0),
               s.rows, round(s.rows::numeric / nullif(s.calls, 0), 2),
               s.shared_blks_hit, s.shared_blks_read,
               round(100.0 * s.shared_blks_hit / nullif(s.shared_blks_hit + s.shared_blks_read, 0), 1),
               s.shared_blks_dirtied, s.shared_blks_written,
               s.temp_blks_read, s.temp_blks_written,
               s.io_read_ms, s.io_write_ms, s.wal_bytes,
               s.roles, s.query
          FROM d
          JOIN pg_index x ON x.indexrelid = d.indexrelid
          CROSS JOIN LATERAL pg_index_role(d.indexrelid) ir
          LEFT JOIN s ON s.queryid = d.queryid AND s.toplevel = d.toplevel
    $q$, v_pgss);
END;
$$;

CREATE VIEW pg_index_query_stats AS
    SELECT schemaname, tablename, indexname, indexrelid, indexdef, index_bytes, is_unique,
           is_partial, index_role, index_notes, queryid, toplevel, index_calls_executed,
           index_calls_planned, pct_calls_using_index, first_seen, last_seen,
           other_indexes, calls, total_exec_ms, mean_exec_ms, min_exec_ms, max_exec_ms,
           plans, total_plan_ms, mean_plan_ms, rows, rows_per_call, shared_blks_hit,
           shared_blks_read, cache_hit_pct, shared_blks_dirtied, shared_blks_written,
           temp_blks_read, temp_blks_written, io_read_ms, io_write_ms, wal_bytes, roles,
           query
      FROM pg_index_query_stats();

GRANT SELECT ON pg_index_query_stats TO PUBLIC;

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
CREATE VIEW pg_index_usage AS
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

GRANT SELECT ON pg_index_usage TO PUBLIC;
