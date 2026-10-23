-- pg_index_deps 0.2, plain install (generated, do not edit)
CREATE SCHEMA IF NOT EXISTS index_deps;
SET search_path = index_deps, public;
/* pg_index_deps--0.2.sql
 *
 * SQL edition of pg_stat_index_queries. No C code, so it installs on managed
 * Postgres (Amazon Aurora, RDS) as well as self-hosted servers.
 *
 *  - index_deps.plan_index_usage / index_dependents: which queries use each
 *    index, read from captured plan text (aurora_stat_plans on Aurora,
 *    pg_stat_plans when self-hosted). Approximate: counts calls per plan that
 *    names the index, not confirmed executions.
 *  - index_deps.index_drop_impact(): hides an index with HypoPG and re-plans
 *    each dependent query with EXPLAIN (GENERIC_PLAN). Never drops anything
 *    and never executes a query. Needs PostgreSQL 16+ and HypoPG 1.4+.
 */


-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

CREATE TABLE index_deps.config (
    key   text PRIMARY KEY,
    value text NOT NULL
);

-- plan_source: auto | aurora_stat_plans | pg_stat_plans | none | <table name>
-- A table name is for tests: it must have columns
-- (queryid bigint, planid bigint, calls bigint, plan_text text).
INSERT INTO index_deps.config VALUES ('plan_source', 'auto');


-- ---------------------------------------------------------------------------
-- Plan source adapter
-- ---------------------------------------------------------------------------

CREATE FUNCTION index_deps.resolved_plan_source()
RETURNS text
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    src text := coalesce((SELECT value FROM index_deps.config WHERE key = 'plan_source'), 'auto');
BEGIN
    IF src <> 'auto' THEN
        RETURN src;
    END IF;
    IF to_regprocedure('aurora_stat_plans(boolean)') IS NOT NULL THEN
        RETURN 'aurora_stat_plans';
    ELSIF to_regprocedure('pg_stat_plans(boolean)') IS NOT NULL THEN
        RETURN 'pg_stat_plans';
    END IF;
    RETURN 'none';
END;
$$;

-- One row per (queryid, planid) in the current database, with plan text.
CREATE FUNCTION index_deps.plan_source()
RETURNS TABLE (queryid bigint, planid bigint, calls bigint, plan_text text, source text)
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    src text := index_deps.resolved_plan_source();
BEGIN
    IF src = 'aurora_stat_plans' THEN
        -- Aurora PostgreSQL 14.10 / 15.5+; needs aurora_compute_plan_id = on.
        RETURN QUERY EXECUTE $q$
            SELECT s.queryid::bigint, s.planid::bigint, sum(s.calls)::bigint,
                   max(s.explain_plan)::text, 'aurora_stat_plans'::text
              FROM aurora_stat_plans(true) s
             WHERE s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
               AND s.explain_plan IS NOT NULL
             GROUP BY 1, 2 $q$;
    ELSIF src = 'pg_stat_plans' THEN
        RETURN QUERY EXECUTE $q$
            SELECT s.queryid::bigint, s.planid::bigint, sum(s.calls)::bigint,
                   max(s.plan)::text, 'pg_stat_plans'::text
              FROM pg_stat_plans(true) s
             WHERE s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
               AND s.plan IS NOT NULL
             GROUP BY 1, 2 $q$;
    ELSIF src = 'none' THEN
        RETURN;
    ELSE
        RETURN QUERY EXECUTE format(
            'SELECT queryid::bigint, planid::bigint, calls::bigint, plan_text::text, %L::text FROM %s',
            'table:' || src, src::regclass);
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Parse index usage out of plan text
-- ---------------------------------------------------------------------------

-- Strip surrounding double quotes from an identifier printed by EXPLAIN.
CREATE FUNCTION index_deps.unquote_ident(text)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT
AS $$ SELECT CASE WHEN left($1, 1) = '"' AND right($1, 1) = '"'
                  THEN replace(substr($1, 2, length($1) - 2), '""', '"')
                  ELSE $1 END $$;

-- Every index reference found in every captured plan.
-- Handles: Index Scan [Backward] using IDX on TBL, Index Only Scan [Backward]
-- using IDX on TBL, Bitmap Index Scan on IDX. Plans in text format.
CREATE VIEW index_deps.plan_index_usage AS
SELECT DISTINCT
       p.queryid,
       p.planid,
       p.calls,
       p.source,
       CASE m[1] WHEN 'Index Only Scan' THEN 'index_only'
                 WHEN 'Index Scan' THEN 'index'
                 ELSE 'bitmap' END                      AS scan_type,
       index_deps.unquote_ident(m[2])                   AS index_name,
       index_deps.unquote_ident(nullif(m[3], ''))       AS table_name,
       p.plan_text
  FROM index_deps.plan_source() p,
       LATERAL regexp_matches(
           p.plan_text,
           '(Index Only Scan|Index Scan|Bitmap Index Scan)(?: Backward)? (?:using|on) ("(?:[^"]|"")+"|[^[:space:]]+)(?: on ("(?:[^"]|"")+"|[^[:space:]]+))?',
           'g') AS m;

-- Resolve index names to OIDs in the current database.
-- EXPLAIN prints unqualified names, so the same name in two schemas is
-- ambiguous; such rows have ambiguous = true and one row per candidate.
CREATE VIEW index_deps.index_dependents AS
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
    SELECT u.*, i.oid AS indexrelid, n.nspname AS schemaname, t.relname AS tablename,
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
       min(source)          AS source
  FROM candidates
 GROUP BY schemaname, tablename, index_name, indexrelid, queryid;

-- User indexes that no captured plan references. Only as good as the plan
-- source: queries without a captured plan, or evicted from
-- pg_stat_statements, are invisible. Excludes PK, unique and constraint indexes.
-- With no plan source (plan_source = none, e.g. RDS) it returns no rows:
-- nothing is known about any index, so nothing is reported as unused.
-- Partitioned tables: one row per partitioned (parent) index, which counts
-- as referenced when any index in its partition tree is; index_bytes is the
-- whole tree. Attached partition indexes aren't listed on their own.
CREATE VIEW index_deps.index_no_dependents AS
SELECT n.nspname AS schemaname,
       t.relname AS tablename,
       i.relname AS indexname,
       x.indexrelid,
       coalesce((SELECT sum(pg_relation_size(p.relid))
                   FROM pg_partition_tree(x.indexrelid) p),
                pg_relation_size(x.indexrelid))::bigint AS index_bytes,
       index_deps.resolved_plan_source() AS source
  FROM pg_index x
  JOIN pg_class i ON i.oid = x.indexrelid
  JOIN pg_class t ON t.oid = x.indrelid
  JOIN pg_namespace n ON n.oid = i.relnamespace
 WHERE index_deps.resolved_plan_source() <> 'none'
   AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'index_deps')
   AND n.nspname NOT LIKE 'pg_toast%'
   AND NOT x.indisprimary
   AND NOT x.indisunique
   AND NOT i.relispartition
   AND NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conindid = x.indexrelid)
   AND NOT EXISTS (SELECT 1 FROM index_deps.index_dependents d
                    WHERE coalesce(pg_partition_root(d.indexrelid), d.indexrelid) = x.indexrelid);

-- ---------------------------------------------------------------------------
-- Drop-impact check
-- ---------------------------------------------------------------------------

-- Shape of a JSON plan: node types and index names in tree order, no costs.
CREATE FUNCTION index_deps.plan_shape(p_plan jsonb)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT
AS $$
    SELECT string_agg(coalesce(v->>'Node Type', '') ||
                      coalesce(' using ' || (v->>'Index Name'), '') ||
                      coalesce(' on ' || (v->>'Relation Name'), ''), ' > ')
      FROM jsonb_path_query(p_plan, 'strict $.**') AS v
     WHERE jsonb_typeof(v) = 'object' AND v ? 'Node Type'
$$;

-- Turn a pg_stat_statements query text into something EXPLAIN accepts:
--  - PREPARE name(types) AS <query>: keep <query>, cast $n to the declared
--    types.
--  - Typed literals: pg_stat_statements turns interval '1 day' into
--    interval $4, which doesn't parse; rewrite it as $4::interval. Only a
--    word that names a type (and isn't a reserved keyword such as AND) is
--    rewritten.
CREATE FUNCTION index_deps.explainable_query(p_query text)
RETURNS text
LANGUAGE plpgsql STABLE STRICT
AS $$
DECLARE
    q      text := p_query;
    m      text[];
    types  text[] := '{}';
    cur    text := '';
    depth  int := 0;
    ch     text;
    w      text;
    i      int;
BEGIN
    m := regexp_match(q, '^\s*PREPARE\s+(?:"(?:[^"]|"")+"|[[:alnum:]_]+)\s*(?:\(((?:[^()]|\([^()]*\))*)\))?\s+AS\s+(.*)$', 'is');
    IF m IS NOT NULL THEN
        q := m[2];
        -- Split the declared types on top-level commas (numeric(10,2) is one type).
        IF m[1] IS NOT NULL THEN
            FOR i IN 1 .. length(m[1]) LOOP
                ch := substr(m[1], i, 1);
                IF ch = '(' THEN depth := depth + 1;
                ELSIF ch = ')' THEN depth := depth - 1;
                END IF;
                IF ch = ',' AND depth = 0 THEN
                    types := types || btrim(cur);
                    cur := '';
                ELSE
                    cur := cur || ch;
                END IF;
            END LOOP;
            types := types || btrim(cur);
        END IF;
    END IF;

    -- Multi-word type names first, then single words.
    q := regexp_replace(q, '\m(timestamp|time)\s+(with|without)\s+time\s+zone\s+\$([0-9]+)',
                        '$\3::\1 \2 time zone', 'gi');
    q := regexp_replace(q, '\m(double)\s+precision\s+\$([0-9]+)', '$\2::double precision', 'gi');
    q := regexp_replace(q, '\m(character|bit)\s+varying\s+\$([0-9]+)', '$\2::\1 varying', 'gi');
    FOR w IN SELECT DISTINCT lower(x[1])
               FROM regexp_matches(q, '\m([[:alpha:]_][[:alnum:]_]*)\s+\$[0-9]+', 'g') AS x
    LOOP
        CONTINUE WHEN EXISTS (SELECT 1 FROM pg_get_keywords() k
                               WHERE k.word = w AND k.catcode IN ('R', 'T'));
        BEGIN
            CONTINUE WHEN to_regtype(w) IS NULL;
        EXCEPTION WHEN OTHERS THEN
            CONTINUE;
        END;
        q := regexp_replace(q, '\m' || w || '\s+\$([0-9]+)', '$\1::' || w, 'gi');
    END LOOP;

    -- Declared PREPARE types last, so $1::declared binds to the parameter.
    FOR i IN 1 .. coalesce(array_length(types, 1), 0) LOOP
        CONTINUE WHEN types[i] = '';
        q := regexp_replace(q, '\$' || i || '(?![0-9])', '$' || i || '::' || types[i], 'g');
    END LOOP;
    RETURN q;
END;
$$;

CREATE FUNCTION index_deps.index_drop_impact(
    p_index         regclass,
    p_include_dml   boolean DEFAULT false,
    p_timeout_ms    integer DEFAULT 2000,
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
    query            text)
LANGUAGE plpgsql VOLATILE
AS $$
DECLARE
    v_index_name   text;
    v_table_name   text;
    v_pred         text;
    v_old_timeout  text := current_setting('statement_timeout');
    v_hidden       boolean := false;
    v_source       text;
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

    SELECT ic.relname, tc.relname, pg_get_expr(x.indpred, x.indrelid)
      INTO v_index_name, v_table_name, v_pred
      FROM pg_index x
      JOIN pg_class ic ON ic.oid = x.indexrelid
      JOIN pg_class tc ON tc.oid = x.indrelid
     WHERE x.indexrelid = p_index;
    IF NOT FOUND THEN
        RAISE EXCEPTION '% is not an index', p_index;
    END IF;

    -- Candidate queries, best source first.
    IF to_regclass('pg_temp.index_deps_candidates') IS NULL THEN
        CREATE TEMP TABLE index_deps_candidates (queryid bigint, calls bigint);
    END IF;
    TRUNCATE index_deps_candidates;

    IF to_regclass('pg_stat_index_queries') IS NOT NULL THEN
        v_source := 'pg_stat_index_queries';
        EXECUTE $q$
            INSERT INTO index_deps_candidates
            SELECT s.queryid, sum(s.calls_executed)
              FROM pg_stat_index_queries s
             WHERE s.indexrelid = $1
               AND s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
             GROUP BY 1 $q$ USING p_index::oid;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM index_deps_candidates)
       AND index_deps.resolved_plan_source() <> 'none' THEN
        v_source := 'captured plans';
        INSERT INTO index_deps_candidates
        SELECT d.queryid, sum(d.calls)
          FROM index_deps.index_dependents d
         WHERE d.indexrelid = p_index::oid
         GROUP BY 1;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM index_deps_candidates) THEN
        -- Fallback: every statement whose text mentions the table.
        v_source := 'query text mentions table';
        EXECUTE $q$
            INSERT INTO index_deps_candidates
            SELECT s.queryid, sum(s.calls)
              FROM pg_stat_statements s
             WHERE s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
               AND s.query ~* ('\m' || $1 || '\M')
             GROUP BY 1 $q$ USING v_table_name;
    END IF;

    FOR r IN EXECUTE $q$
        SELECT c.queryid, c.calls, max(s.query) AS query
          FROM index_deps_candidates c
          JOIN pg_stat_statements s
            ON s.queryid = c.queryid
           AND s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
         GROUP BY c.queryid, c.calls
         ORDER BY c.calls DESC NULLS LAST
         LIMIT $1 $q$ USING p_max_queries
    LOOP
        queryid := r.queryid;
        calls := r.calls;
        query := left(r.query, 300);
        cost_with := NULL; cost_without := NULL; cost_ratio := NULL;
        uses_index_now := NULL; uses_index_after := NULL; plan_changed := NULL;
        shape_with := NULL; shape_without := NULL;
        note := 'candidates from ' || v_source;

        v_sql := index_deps.explainable_query(r.query);

        IF v_sql !~* '^\s*(select|with|values|table)\M'
           AND NOT (p_include_dml AND v_sql ~* '^\s*(insert|update|delete|merge)\M') THEN
            note := 'skipped: not a read query (set p_include_dml => true to EXPLAIN DML)';
            RETURN NEXT;
            CONTINUE;
        END IF;

        BEGIN
            PERFORM set_config('statement_timeout', p_timeout_ms::text, true);

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
            -- this query did, or the index is partial (its predicate can't
            -- be proven against $n parameters: "status = $1" vs
            -- "WHERE status = 'open'"). "Unchanged" would understate the
            -- risk, so report unknown.
            IF NOT uses_index_now
               AND (v_source <> 'query text mentions table' OR v_pred IS NOT NULL) THEN
                plan_changed := NULL;
                note := 'unknown: the generic plan does not use the index'
                        || CASE WHEN v_source <> 'query text mentions table'
                                THEN ' but recorded plans of this query did' ELSE '' END
                        || CASE WHEN v_pred IS NOT NULL
                                THEN '; partial index (WHERE ' || v_pred
                                     || ') cannot be matched to $n parameters' ELSE '' END
                        || '; check with EXPLAIN using real values ('
                        || note || ')';
            END IF;
        EXCEPTION WHEN OTHERS THEN
            -- HypoPG state lives in backend memory, not in the transaction,
            -- so it must be undone here explicitly.
            IF v_hidden THEN
                PERFORM hypopg_unhide_index(p_index::oid);
                v_hidden := false;
            END IF;
            note := 'skipped: ' || SQLERRM;
        END;

        RETURN NEXT;
    END LOOP;

    PERFORM set_config('statement_timeout', v_old_timeout, true);
    IF v_hidden THEN
        PERFORM hypopg_unhide_index(p_index::oid);
    END IF;
    RETURN;
END;
$$;

COMMENT ON FUNCTION index_deps.index_drop_impact(regclass, boolean, integer, integer) IS
'Estimate what happens to dependent queries if an index is dropped. Hides the index with HypoPG (this session only), re-plans with EXPLAIN (GENERIC_PLAN), compares cost and plan shape. Never executes queries or drops anything.';

GRANT USAGE ON SCHEMA index_deps TO PUBLIC;
GRANT SELECT ON index_deps.plan_index_usage, index_deps.index_dependents,
                index_deps.index_no_dependents TO PUBLIC;
