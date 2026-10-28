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
