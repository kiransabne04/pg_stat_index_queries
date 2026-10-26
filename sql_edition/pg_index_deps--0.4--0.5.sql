/* pg_index_deps--0.4--0.5.sql */

\echo Use "ALTER EXTENSION pg_index_deps UPDATE TO '0.5'" to load this file. \quit

-- Same objects as 0.4, written with column lists instead of SELECT * / alias.*.
-- Behaviour and output columns are unchanged.

CREATE OR REPLACE FUNCTION index_deps.index_role(
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

CREATE OR REPLACE VIEW index_deps.index_dependents AS
WITH usage AS (
    SELECT u.queryid, u.planid, u.calls, u.source, u.scan_type, u.index_name,
           coalesce(u.table_name,
                    -- Bitmap Index Scan lines don't name the table; take it
                    -- from the plan's Bitmap Heap Scan line when there is one.
                    (regexp_match(u.plan_text, 'Bitmap Heap Scan on ("(?:[^"]|"")+"|[^[:space:]]+)'))[1]
           ) AS table_hint
      FROM index_deps.plan_index_usage u
),
candidates AS (
    SELECT u.queryid, u.planid, u.calls, u.source, u.scan_type, u.index_name, u.table_hint,
           i.oid AS indexrelid, n.nspname AS schemaname, t.relname AS tablename,
           count(*) OVER (PARTITION BY u.queryid, u.planid, u.index_name) AS n_candidates
      FROM usage u
      JOIN pg_class i ON i.relname = u.index_name AND i.relkind IN ('i', 'I')
      JOIN pg_index x ON x.indexrelid = i.oid
      JOIN pg_class t ON t.oid = x.indrelid
      JOIN pg_namespace n ON n.oid = i.relnamespace
     WHERE u.table_hint IS NULL
        OR t.relname = index_deps.unquote_ident(u.table_hint)
)
SELECT schemaname,
       tablename,
       index_name           AS indexname,
       indexrelid,
       queryid,
       count(DISTINCT planid) AS plans,
       sum(calls)::bigint   AS calls,
       string_agg(DISTINCT scan_type, ',') AS scan_types,
       bool_or(n_candidates > 1) AS ambiguous,
       min(source)          AS source,
       (SELECT r.index_role FROM index_deps.index_role(indexrelid) r) AS index_role
  FROM candidates
 GROUP BY schemaname, tablename, index_name, indexrelid, queryid;

CREATE OR REPLACE FUNCTION index_deps.index_query_stats(
    OUT schemaname name,
    OUT tablename name,
    OUT indexname text,
    OUT indexrelid oid,
    OUT indexdef text,
    OUT index_bytes bigint,
    OUT is_unique bool,
    OUT is_partial bool,
    OUT index_role text,
    OUT index_notes text[],
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
            SELECT schemaname, tablename, indexname, indexrelid, queryid, plans, calls,
                   scan_types, ambiguous, source, index_role
              FROM index_deps.index_dependents
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
               ir.index_role, ir.index_notes,
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
          CROSS JOIN LATERAL index_deps.index_role(d.indexrelid) ir
          LEFT JOIN s ON s.queryid = d.queryid
    $q$, v_pgss);
END;
$$;

CREATE OR REPLACE VIEW index_deps.index_query_stats AS
    SELECT schemaname, tablename, indexname, indexrelid, indexdef, index_bytes, is_unique,
           is_partial, index_role, index_notes, queryid, index_plans, index_calls,
           pct_calls_using_index, scan_types, ambiguous, source, other_indexes, calls,
           total_exec_ms, mean_exec_ms, min_exec_ms, max_exec_ms, plans, total_plan_ms,
           mean_plan_ms, rows, rows_per_call, shared_blks_hit, shared_blks_read,
           cache_hit_pct, shared_blks_dirtied, shared_blks_written, temp_blks_read,
           temp_blks_written, io_read_ms, io_write_ms, wal_bytes, roles, query
      FROM index_deps.index_query_stats();
