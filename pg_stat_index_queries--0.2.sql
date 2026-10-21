/* pg_stat_index_queries--0.2.sql */

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
    SELECT * FROM pg_stat_index_queries();

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
    SELECT * FROM pg_stat_index_queries_info();

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
           s.last_seen
      FROM pg_stat_index_queries() s
      JOIN pg_class i ON i.oid = s.indexrelid
      JOIN pg_index x ON x.indexrelid = s.indexrelid
      JOIN pg_class t ON t.oid = x.indrelid
      JOIN pg_namespace n ON n.oid = i.relnamespace
     WHERE s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database());

-- User indexes with no recorded executed use since the last reset.
-- Excludes primary keys, unique indexes and constraint-backed indexes.
-- ALWAYS check tracked_since before acting on this list.
CREATE VIEW pg_index_no_dependents AS
    SELECT n.nspname AS schemaname,
           t.relname AS tablename,
           i.relname AS indexname,
           x.indexrelid,
           pg_relation_size(x.indexrelid) AS index_bytes,
           (SELECT stats_reset FROM pg_stat_index_queries_info()) AS tracked_since
      FROM pg_index x
      JOIN pg_class i ON i.oid = x.indexrelid
      JOIN pg_class t ON t.oid = x.indrelid
      JOIN pg_namespace n ON n.oid = i.relnamespace
     WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
       AND n.nspname NOT LIKE 'pg_toast%'
       AND NOT x.indisprimary
       AND NOT x.indisunique
       AND NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conindid = x.indexrelid)
       AND NOT EXISTS (
            SELECT 1 FROM pg_stat_index_queries() s
             WHERE s.indexrelid = x.indexrelid
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
