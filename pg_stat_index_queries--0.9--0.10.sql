/* pg_stat_index_queries--0.9--0.10.sql */

\echo Use "ALTER EXTENSION pg_stat_index_queries UPDATE TO '0.10'" to load this file. \quit

-- What an index is for besides speeding up queries, and what dropping it
-- would break. index_role: primary key | unique constraint | exclusion
-- constraint | unique index | index. index_notes: foreign keys that
-- reference it, replica identity, clustered, invalid, partial, expression,
-- partitions, foreign keys on its own table that it supports. drop_blocker:
-- why DROP INDEX fails or changes behaviour (NULL when nothing but query
-- speed depends on it). An index that serves a foreign key's checks gets
-- a drop_blocker too: those checks run as nested statements, which are
-- often not recorded, and without the index every delete or key update on
-- the referenced table scans this one.
CREATE OR REPLACE FUNCTION pg_index_role(
    p_index regclass,
    OUT index_role text,
    OUT index_notes text[],
    OUT drop_blocker text)
LANGUAGE sql STABLE
AS $$
    WITH ix AS (
        SELECT x.indexrelid, x.indrelid, x.indisunique, x.indisreplident, x.indisclustered,
               x.indisvalid, x.indpred, x.indexprs, i.relkind, i.relispartition,
               x.indkey, x.indnkeyatts,
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
    -- Foreign keys on this index's table whose checks can use it: its
    -- leading key columns are the foreign key's columns (any order), or no
    -- index on the table is, and it starts with one of them.
    fkc AS (
        SELECT f.conname, f.conrelid, f.confrelid, f.conkey,
               (SELECT array_agg(a ORDER BY a) FROM unnest(f.conkey) a) AS cols
          FROM pg_constraint f, ix
         WHERE f.contype = 'f' AND f.conrelid = ix.indrelid
    ),
    sup AS (
        SELECT array_agg(format('supports foreign key %s on %s (checks on deletes and key updates in %s)',
                                fkc.conname, fkc.conrelid::regclass, fkc.confrelid::regclass)
                         ORDER BY fkc.conname) AS sups,
               string_agg(format('%s (to %s)', fkc.conname, fkc.confrelid::regclass), ', '
                          ORDER BY fkc.conname) AS sup_names
          FROM fkc, ix
         WHERE ix.indpred IS NULL AND ix.indisvalid
           AND ((SELECT array_agg(a ORDER BY a)
                   FROM unnest(ix.indkey::int2[]) WITH ORDINALITY u(a, n)
                  WHERE n <= least(cardinality(fkc.conkey), ix.indnkeyatts)) = fkc.cols
                OR (ix.indkey[0] = ANY (fkc.conkey)
                    AND NOT EXISTS (
                        SELECT 1 FROM pg_index o
                         WHERE o.indrelid = fkc.conrelid AND o.indpred IS NULL AND o.indisvalid
                           AND (SELECT array_agg(a ORDER BY a)
                                  FROM unnest(o.indkey::int2[]) WITH ORDINALITY u(a, n)
                                 WHERE n <= least(cardinality(fkc.conkey), o.indnkeyatts)) = fkc.cols)))
    ),
    r AS (
        SELECT ix.indexrelid, ix.indrelid, ix.indisunique, ix.indisreplident, ix.indisclustered,
               ix.indisvalid, ix.indpred, ix.indexprs, ix.relkind, ix.relispartition,
               ix.parent_index, ix.nulls_not_distinct,
               k.conname, k.contype, k.condeferrable, fk.refs, sup.sups, sup.sup_names,
               CASE k.contype WHEN 'p' THEN 'primary key'
                              WHEN 'u' THEN 'unique constraint'
                              WHEN 'x' THEN 'exclusion constraint'
                              ELSE CASE WHEN ix.indisunique THEN 'unique index' ELSE 'index' END
               END AS role
          FROM ix LEFT JOIN k ON true LEFT JOIN fk ON true LEFT JOIN sup ON true
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
           ]::text[], NULL) || coalesce(r.refs, '{}') || coalesce(r.sups, '{}'),
           nullif(concat_ws('; ',
               CASE WHEN r.contype IS NOT NULL
                    THEN format('enforces %s %s: DROP INDEX fails, dropping the constraint removes the guarantee',
                                r.role, r.conname) END,
               CASE WHEN r.contype IS NULL AND r.indisunique
                    THEN 'enforces uniqueness: dropping it allows duplicates' END,
               CASE WHEN r.refs IS NOT NULL
                    THEN 'foreign keys depend on it: ' || array_to_string(r.refs, ', ') END,
               CASE WHEN r.sup_names IS NOT NULL
                    THEN 'foreign-key checks use it: ' || r.sup_names
                         || '; without it each delete or key update on the referenced table scans this one'
                         || ' (these checks are nested statements, recorded only when nested statements are tracked)' END,
               CASE WHEN r.indisreplident
                    THEN 'replica identity: logical replication and CDC use it' END,
               CASE WHEN r.relispartition
                    THEN 'attached to partitioned index ' || r.parent_index || ': drop that instead' END
           ), '')
      FROM r
$$;

-- Indexes in the current database and the queries that used them.
-- Join to pg_stat_statements on (dbid, queryid) for query text.
-- Column names come from pg_attribute; pg_get_indexdef only deparses
-- expression columns (it raises "cache lookup failed" when the index is
-- dropped while it runs).
CREATE OR REPLACE VIEW pg_index_dependents AS
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
           (SELECT r.index_role FROM pg_index_role(s.indexrelid) r) AS index_role,
           ARRAY(SELECT CASE WHEN x.indkey[c - 1] = 0 THEN pg_get_indexdef(s.indexrelid, c, true)
                             ELSE (SELECT quote_ident(a.attname) COLLATE "default" FROM pg_attribute a
                                    WHERE a.attrelid = x.indrelid AND a.attnum = x.indkey[c - 1]) END
                   FROM unnest(s.cond_columns) AS c ORDER BY c) AS cond_columns,
           ARRAY(SELECT CASE WHEN x.indkey[c - 1] = 0 THEN pg_get_indexdef(s.indexrelid, c, true)
                             ELSE (SELECT quote_ident(a.attname) COLLATE "default" FROM pg_attribute a
                                    WHERE a.attrelid = x.indrelid AND a.attnum = x.indkey[c - 1]) END
                   FROM unnest(s.order_columns) AS c ORDER BY c) AS order_columns,
           s.columns_complete
      FROM pg_stat_index_queries() s
      JOIN pg_class i ON i.oid = s.indexrelid
      JOIN pg_index x ON x.indexrelid = s.indexrelid
      JOIN pg_class t ON t.oid = x.indrelid
      JOIN pg_namespace n ON n.oid = i.relnamespace
     WHERE s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database());

-- One row per key column of each index (partition indexes folded into their
-- parent): how many recorded queries searched on it (index conditions) or
-- ordered by it through the index operator (e.g. KNN). A plain ordered scan
-- (ORDER BY on the index columns) and index-only coverage don't name
-- columns, so a column nobody searches on can still be needed for those.
CREATE OR REPLACE VIEW pg_index_column_usage AS
WITH info AS (
    SELECT stats_reset FROM pg_stat_index_queries_info()
),
s AS (
    SELECT coalesce(pg_partition_root(s.indexrelid), s.indexrelid) AS indexrelid,
           s.queryid, s.calls_executed, s.cond_columns, s.order_columns, s.columns_complete
      FROM pg_stat_index_queries() s
     WHERE s.calls_executed > 0
       AND s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
       AND EXISTS (SELECT 1 FROM pg_class c WHERE c.oid = s.indexrelid)
),
idx AS (
    SELECT n.nspname AS schemaname, t.relname AS tablename, i.relname AS indexname,
           x.indexrelid, x.indnkeyatts, x.indrelid, x.indkey
      FROM pg_index x
      JOIN pg_class i ON i.oid = x.indexrelid
      JOIN pg_class t ON t.oid = x.indrelid
      JOIN pg_namespace n ON n.oid = i.relnamespace
     WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
       AND n.nspname NOT LIKE 'pg_toast%'
       AND NOT i.relispartition
),
cols AS (
    SELECT idx.schemaname, idx.tablename, idx.indexname, idx.indexrelid,
           k.k AS key_position,
           CASE WHEN idx.indkey[k.k - 1] = 0 THEN pg_get_indexdef(idx.indexrelid, k.k, true)
                ELSE (SELECT quote_ident(a.attname) COLLATE "default" FROM pg_attribute a
                       WHERE a.attrelid = idx.indrelid AND a.attnum = idx.indkey[k.k - 1]) END AS column_expr,
           u.queries, u.queries_searched, u.calls_searched, u.queries_ordered,
           u.queries_columns_unknown
      FROM idx
     CROSS JOIN LATERAL generate_series(1, idx.indnkeyatts) AS k(k)
     CROSS JOIN LATERAL (
            SELECT count(DISTINCT s.queryid) AS queries,
                   count(DISTINCT s.queryid) FILTER (WHERE k.k = ANY (s.cond_columns)) AS queries_searched,
                   coalesce(sum(s.calls_executed) FILTER (WHERE k.k = ANY (s.cond_columns)), 0)::bigint AS calls_searched,
                   count(DISTINCT s.queryid) FILTER (WHERE k.k = ANY (s.order_columns)) AS queries_ordered,
                   count(DISTINCT s.queryid) FILTER (WHERE NOT s.columns_complete) AS queries_columns_unknown
              FROM s WHERE s.indexrelid = idx.indexrelid) u
)
SELECT cols.schemaname, cols.tablename, cols.indexname, cols.indexrelid,
       cols.key_position, cols.column_expr, cols.queries, cols.queries_searched,
       cols.calls_searched, cols.queries_ordered, cols.queries_columns_unknown,
       info.stats_reset AS tracked_since,
       CASE
         WHEN cols.queries = 0 OR cols.queries_searched > 0 OR cols.queries_ordered > 0
           THEN NULL
         WHEN cols.queries_columns_unknown > 0
           THEN format('unknown: %s of %s queries were recorded before column tracking (0.8); pg_stat_index_queries_reset() starts a complete record',
                       cols.queries_columns_unknown, cols.queries)
         WHEN cols.key_position = 1
           THEN 'leading column not searched on by any recorded query: the index serves ordering, full or index-only scans, or searches on later columns (skip scan)'
         ELSE 'not searched on by any recorded query: unless it is needed for ORDER BY or index-only scans, an index without it may do'
       END AS note
  FROM cols
  CROSS JOIN info;

-- The index definition, or NULL when the index is dropped while it is read.
-- pg_get_indexdef finds the index, then its columns; a DROP INDEX or REINDEX
-- CONCURRENTLY committing in between raises "cache lookup failed" (an
-- internal error), which would fail the whole query.
CREATE FUNCTION pg_index_def_or_null(p_index oid)
RETURNS text
LANGUAGE plpgsql STABLE
AS $$
BEGIN
    RETURN pg_get_indexdef(p_index);
EXCEPTION WHEN internal_error THEN
    RETURN NULL;
END;
$$;

-- One row per (index, query) recorded since the last reset, with what a
-- developer needs to debug it: the index definition and size, how often the
-- query used the index, which other indexes it used, and the query's
-- statistics from pg_stat_statements (summed over roles; times in ms).
-- Statistics are NULL when pg_stat_statements no longer has the query
-- (evicted or reset); the row stays because the dependency is still real.
-- pg_stat_statements is looked up when called, not at install time, so it
-- can be installed, dropped or moved independently of this extension.
CREATE OR REPLACE FUNCTION pg_index_query_stats(
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
               pg_index_def_or_null(d.indexrelid),
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
