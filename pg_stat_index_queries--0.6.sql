/* pg_stat_index_queries--0.6.sql */

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
       END AS verdict
  FROM idx
  CROSS JOIN info
  CROSS JOIN LATERAL pg_index_role(idx.indexrelid) r
  LEFT JOIN used ON used.indexrelid = idx.indexrelid;

GRANT SELECT ON pg_index_usage TO PUBLIC;
