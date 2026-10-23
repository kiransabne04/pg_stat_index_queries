/* pg_stat_index_queries--0.3--0.4.sql */

\echo Use "ALTER EXTENSION pg_stat_index_queries UPDATE TO '0.4'" to load this file. \quit

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
            SELECT * FROM pg_index_dependents
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
          LEFT JOIN s ON s.queryid = d.queryid AND s.toplevel = d.toplevel
    $q$, v_pgss);
END;
$$;

CREATE VIEW pg_index_query_stats AS
    SELECT * FROM pg_index_query_stats();

GRANT SELECT ON pg_index_query_stats TO PUBLIC;
