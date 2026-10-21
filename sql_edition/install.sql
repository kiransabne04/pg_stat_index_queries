-- pg_index_deps 0.1, plain install (generated, do not edit)
CREATE SCHEMA IF NOT EXISTS index_deps;
SET search_path = index_deps, public;
/* pg_index_deps--0.1.sql
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
CREATE VIEW index_deps.index_no_dependents AS
SELECT n.nspname AS schemaname,
       t.relname AS tablename,
       i.relname AS indexname,
       x.indexrelid,
       pg_relation_size(x.indexrelid) AS index_bytes,
       index_deps.resolved_plan_source() AS source
  FROM pg_index x
  JOIN pg_class i ON i.oid = x.indexrelid
  JOIN pg_class t ON t.oid = x.indrelid
  JOIN pg_namespace n ON n.oid = i.relnamespace
 WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'index_deps')
   AND n.nspname NOT LIKE 'pg_toast%'
   AND NOT x.indisprimary
   AND NOT x.indisunique
   AND NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conindid = x.indexrelid)
   AND NOT EXISTS (SELECT 1 FROM index_deps.index_dependents d WHERE d.indexrelid = x.indexrelid);

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
    v_old_timeout  text := current_setting('statement_timeout');
    v_hidden       boolean := false;
    v_source       text;
    r              record;
    j_with         jsonb;
    j_without      jsonb;
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

    SELECT ic.relname, tc.relname INTO v_index_name, v_table_name
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

        IF r.query !~* '^\s*(select|with|values|table)\M'
           AND NOT (p_include_dml AND r.query ~* '^\s*(insert|update|delete|merge)\M') THEN
            note := 'skipped: not a read query (set p_include_dml => true to EXPLAIN DML)';
            RETURN NEXT;
            CONTINUE;
        END IF;

        BEGIN
            PERFORM set_config('statement_timeout', p_timeout_ms::text, true);

            EXECUTE 'EXPLAIN (GENERIC_PLAN, FORMAT JSON) ' || r.query INTO j_with;

            PERFORM hypopg_hide_index(p_index::oid);
            v_hidden := true;

            EXECUTE 'EXPLAIN (GENERIC_PLAN, FORMAT JSON) ' || r.query INTO j_without;

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
