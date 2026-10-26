/* pg_stat_index_queries--0.7--0.8.sql */

\echo Use "ALTER EXTENSION pg_stat_index_queries UPDATE TO '0.8'" to load this file. \quit

-- pg_stat_index_queries() gains cond_columns, order_columns and
-- columns_complete. Its result type changes, so the function and every view
-- built on it are dropped and recreated (definitions as in --0.8.sql).
DROP VIEW pg_index_usage;
DROP VIEW pg_index_dependents_rollup;
DROP VIEW pg_index_no_dependents;
DROP VIEW pg_index_dependents;
DROP VIEW pg_stat_index_queries;
DROP FUNCTION pg_stat_index_queries();

CREATE FUNCTION pg_stat_index_queries(
    OUT dbid oid,
    OUT indexrelid oid,
    OUT queryid bigint,
    OUT toplevel bool,
    OUT calls_executed bigint,
    OUT calls_planned bigint,
    OUT first_seen timestamptz,
    OUT last_seen timestamptz,
    OUT cond_columns int2[],
    OUT order_columns int2[],
    OUT columns_complete bool
)
RETURNS SETOF record
AS 'MODULE_PATHNAME', 'pg_stat_index_queries_0_8'
LANGUAGE C STRICT VOLATILE PARALLEL SAFE;

-- cond_columns: index column numbers the query searched on (index
-- conditions); order_columns: columns it ordered by through the index
-- operator (e.g. KNN). Both from scans that ran, OR'd over executions.
-- columns_complete = false: counts loaded from a pre-0.8 stats file, so the
-- column sets miss those executions.
CREATE VIEW pg_stat_index_queries AS
    SELECT dbid, indexrelid, queryid, toplevel, calls_executed, calls_planned,
           first_seen, last_seen, cond_columns, order_columns, columns_complete
      FROM pg_stat_index_queries();

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
           (SELECT r.index_role FROM pg_index_role(s.indexrelid) r) AS index_role,
           ARRAY(SELECT pg_get_indexdef(s.indexrelid, c, true)
                   FROM unnest(s.cond_columns) AS c ORDER BY c) AS cond_columns,
           ARRAY(SELECT pg_get_indexdef(s.indexrelid, c, true)
                   FROM unnest(s.order_columns) AS c ORDER BY c) AS order_columns,
           s.columns_complete
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

GRANT SELECT ON pg_stat_index_queries, pg_index_dependents, pg_index_no_dependents TO PUBLIC;

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

-- One row per key column of each index (partition indexes folded into their
-- parent): how many recorded queries searched on it (index conditions) or
-- ordered by it through the index operator (e.g. KNN). A plain ordered scan
-- (ORDER BY on the index columns) and index-only coverage don't name
-- columns, so a column nobody searches on can still be needed for those.
CREATE VIEW pg_index_column_usage AS
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
           x.indexrelid, x.indnkeyatts
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
           pg_get_indexdef(idx.indexrelid, k.k, true) AS column_expr,
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

GRANT SELECT ON pg_index_column_usage TO PUBLIC;
