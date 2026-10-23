/* pg_index_deps--0.2--0.3.sql */

\echo Use "ALTER EXTENSION pg_index_deps UPDATE TO '0.3'" to load this file. \quit

-- One row per (index, query) from captured plans, with what a developer
-- needs to debug it: the index definition and size, scan types, which other
-- indexes the query's plans used, and the query's statistics from
-- pg_stat_statements (summed over roles and top-level/nested; times in ms).
-- Statistics are NULL when pg_stat_statements no longer has the query.
-- pg_stat_statements is looked up when called, not at install time.
CREATE FUNCTION index_deps.index_query_stats(
    OUT schemaname name,
    OUT tablename name,
    OUT indexname text,
    OUT indexrelid oid,
    OUT indexdef text,
    OUT index_bytes bigint,
    OUT is_unique bool,
    OUT is_partial bool,
    OUT queryid bigint,
    OUT index_plans bigint,
    OUT index_calls bigint,
    OUT pct_calls_using_index numeric,
    OUT scan_types text,
    OUT ambiguous bool,
    OUT source text,
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
    OUT query text)
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
        RAISE EXCEPTION 'index_query_stats needs pg_stat_statements'
            USING HINT = 'CREATE EXTENSION pg_stat_statements; (on RDS/Aurora it is preloaded by default)';
    END IF;

    -- blk_read_time/blk_write_time were renamed shared_blk_*_time in PG 17;
    -- read them through jsonb so the same text works on every version.
    RETURN QUERY EXECUTE format($q$
        WITH d AS (
            SELECT * FROM index_deps.index_dependents
        ),
        s AS (
            SELECT p.queryid,
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
             GROUP BY p.queryid
        )
        SELECT d.schemaname, d.tablename, d.indexname, d.indexrelid,
               pg_get_indexdef(d.indexrelid),
               pg_relation_size(d.indexrelid),
               x.indisunique,
               x.indpred IS NOT NULL,
               d.queryid, d.plans, d.calls,
               round(100.0 * d.calls / nullif(s.calls, 0), 1),
               d.scan_types, d.ambiguous, d.source,
               (SELECT array_agg(DISTINCT o.indexrelid::regclass::text)
                  FROM d o
                 WHERE o.queryid = d.queryid AND o.indexrelid <> d.indexrelid),
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
          LEFT JOIN s ON s.queryid = d.queryid
    $q$, v_pgss);
END;
$$;

CREATE VIEW index_deps.index_query_stats AS
    SELECT * FROM index_deps.index_query_stats();

GRANT SELECT ON index_deps.index_query_stats TO PUBLIC;
