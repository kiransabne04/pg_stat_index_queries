/* pg_index_deps--0.7--0.8.sql */

\echo Use "ALTER EXTENSION pg_index_deps UPDATE TO '0.8'" to load this file. \quit

-- Security fixes. index_drop_impact plans a query only when a role with the
-- caller's privileges recorded it (new parameter p_trust_other_roles), calls
-- HypoPG, pg_stat_statements, pg_stat_index_queries and the plan sources by
-- their extension's schema, keeps its own name lookups out of the caller's
-- search_path, and skips query text containing ";".

-- Schema-qualified name of function p_name(p_args) that belongs to
-- extension p_ext, or NULL. p_ext NULL: a function in pg_catalog or in any
-- extension (aurora_stat_plans is built into Aurora). Other extensions'
-- objects are called by this name, never through the caller's search_path,
-- so a same-named function in a schema earlier in it never runs.
CREATE FUNCTION index_deps.ext_function(p_ext name, p_name name, p_args regtype[])
RETURNS text
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT format('%I.%I', n.nspname, p.proname)
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE p.proname = p_name
       AND p.proargtypes = array_to_string(p_args::oid[], ' ')::oidvector
       AND (EXISTS (SELECT 1
                      FROM pg_depend d
                      JOIN pg_extension e ON e.oid = d.refobjid
                     WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid
                       AND d.refclassid = 'pg_extension'::regclass AND d.deptype = 'e'
                       AND (p_ext IS NULL OR e.extname = p_ext))
            OR (p_ext IS NULL AND n.nspname = 'pg_catalog'))
     ORDER BY n.nspname <> 'pg_catalog'
     LIMIT 1
$$;

-- Schema-qualified name of relation p_name that belongs to extension
-- p_ext, or NULL.
CREATE FUNCTION index_deps.ext_relation(p_ext name, p_name name)
RETURNS text
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT format('%I.%I', n.nspname, c.relname)
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_depend d ON d.classid = 'pg_class'::regclass AND d.objid = c.oid
                      AND d.refclassid = 'pg_extension'::regclass AND d.deptype = 'e'
      JOIN pg_extension e ON e.oid = d.refobjid AND e.extname = p_ext
     WHERE c.relname = p_name
     LIMIT 1
$$;

CREATE OR REPLACE FUNCTION index_deps.resolved_plan_source()
RETURNS text
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    src text := coalesce((SELECT value FROM index_deps.config WHERE key = 'plan_source'), 'auto');
BEGIN
    IF src <> 'auto' THEN
        RETURN src;
    END IF;
    IF index_deps.ext_function(NULL, 'aurora_stat_plans', '{boolean}') IS NOT NULL THEN
        RETURN 'aurora_stat_plans';
    ELSIF index_deps.ext_function('pg_stat_plans', 'pg_stat_plans', '{boolean}') IS NOT NULL THEN
        RETURN 'pg_stat_plans';
    END IF;
    RETURN 'none';
END;
$$;

-- One row per (queryid, planid) in the current database, with plan text.
CREATE OR REPLACE FUNCTION index_deps.plan_source()
RETURNS TABLE (queryid bigint, planid bigint, calls bigint, plan_text text, source text)
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    src text := index_deps.resolved_plan_source();
    fn  text;
BEGIN
    IF src IN ('aurora_stat_plans', 'pg_stat_plans') THEN
        fn := index_deps.ext_function(CASE src WHEN 'pg_stat_plans' THEN 'pg_stat_plans' END,
                                      src, '{boolean}');
        IF fn IS NULL THEN
            RAISE EXCEPTION 'plan_source is % but %(boolean) is not installed', src, src;
        END IF;
    END IF;
    IF src = 'aurora_stat_plans' THEN
        -- Aurora PostgreSQL 14.10 / 15.5+; needs aurora_compute_plan_id = on.
        RETURN QUERY EXECUTE format($q$
            SELECT s.queryid::bigint, s.planid::bigint, sum(s.calls)::bigint,
                   max(s.explain_plan)::text, 'aurora_stat_plans'::text
              FROM %s(true) s
             WHERE s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
               AND s.explain_plan IS NOT NULL
             GROUP BY 1, 2 $q$, fn);
    ELSIF src = 'pg_stat_plans' THEN
        RETURN QUERY EXECUTE format($q$
            SELECT s.queryid::bigint, s.planid::bigint, sum(s.calls)::bigint,
                   max(s.plan)::text, 'pg_stat_plans'::text
              FROM %s(true) s
             WHERE s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
               AND s.plan IS NOT NULL
             GROUP BY 1, 2 $q$, fn);
    ELSIF src = 'none' THEN
        RETURN;
    ELSE
        RETURN QUERY EXECUTE format(
            'SELECT queryid::bigint, planid::bigint, calls::bigint, plan_text::text, %L::text FROM %s',
            'table:' || src, src::regclass);
    END IF;
END;
$$;

-- New parameter: drop and recreate (no view or function depends on it).
DROP FUNCTION index_deps.index_drop_impact(regclass, boolean, integer, integer);

-- Planning a query runs IMMUTABLE functions in it that have constant
-- arguments, with the caller's privileges. So a query is planned only when
-- a role that has the caller's privileges (the caller, a superuser, a member
-- of the caller's role) recorded it, unless p_trust_other_roles. SET ROLE
-- would not help: code in the query can RESET ROLE through a VOLATILE call.
-- Names in this function resolve in pg_catalog and, for other extensions,
-- their own schema; the caller's search_path applies only to the query
-- text being explained.
CREATE FUNCTION index_deps.index_drop_impact(
    p_index             regclass,
    p_include_dml       boolean DEFAULT false,
    p_timeout_ms        integer DEFAULT 30000,
    p_max_queries       integer DEFAULT 50,
    p_trust_other_roles boolean DEFAULT false)
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
    query            text,
    drop_blocker     text)
LANGUAGE plpgsql VOLATILE
AS $$
DECLARE
    v_path         text := pg_catalog.current_setting('search_path');
    v_index_label  text := p_index::text;
    v_index_name   text;
    v_table_name   text;
    v_pred         text;
    v_pred_const   boolean;
    v_blocker      text;
    v_stats_note   text;
    v_hidden       boolean := false;
    v_source       text;
    v_cands        jsonb;
    v_start        timestamptz := pg_catalog.clock_timestamp();
    v_hide         text;
    v_unhide       text;
    v_pgss         text;
    v_siq          text;
    v_explain      text;
    r              record;
    j_with         jsonb;
    j_without      jsonb;
    v_sql          text;
BEGIN
    PERFORM pg_catalog.set_config('search_path', 'pg_catalog, pg_temp', true);

    IF current_setting('server_version_num')::int < 160000 THEN
        RAISE EXCEPTION 'index_drop_impact needs PostgreSQL 16 or later (EXPLAIN GENERIC_PLAN)';
    END IF;
    v_hide := format('SELECT %s($1)', index_deps.ext_function('hypopg', 'hypopg_hide_index', '{oid}'));
    v_unhide := format('SELECT %s($1)', index_deps.ext_function('hypopg', 'hypopg_unhide_index', '{oid}'));
    IF v_hide IS NULL OR v_unhide IS NULL THEN
        RAISE EXCEPTION 'HypoPG 1.4 or later is required'
            USING HINT = 'CREATE EXTENSION hypopg;';
    END IF;
    v_pgss := index_deps.ext_relation('pg_stat_statements', 'pg_stat_statements');
    IF v_pgss IS NULL THEN
        RAISE EXCEPTION 'pg_stat_statements is required (it provides the query text)';
    END IF;
    v_siq := index_deps.ext_relation('pg_stat_index_queries', 'pg_stat_index_queries');

    -- A partial index whose predicate compares to a constant can't be
    -- matched by a generic plan once pg_stat_statements has replaced the
    -- query's constants with $n. Constant-free predicates (IS NULL) can.
    SELECT ic.relname, tc.relname, pg_get_expr(x.indpred, x.indrelid),
           coalesce(x.indpred::text LIKE '%{CONST %', false)
      INTO v_index_name, v_table_name, v_pred, v_pred_const
      FROM pg_index x
      JOIN pg_class ic ON ic.oid = x.indexrelid
      JOIN pg_class tc ON tc.oid = x.indrelid
     WHERE x.indexrelid = p_index;
    IF NOT FOUND THEN
        RAISE EXCEPTION '% is not an index', v_index_label;
    END IF;
    -- These print relation names as the caller would see them.
    PERFORM pg_catalog.set_config('search_path', v_path, true);
    SELECT ir.drop_blocker INTO v_blocker FROM index_deps.index_role(p_index) ir;
    -- Estimates are only as good as the table's statistics (T08).
    SELECT string_agg(h, '; ') INTO v_stats_note
      FROM unnest(index_deps.index_hints(p_index)) AS h
     WHERE h LIKE 'statistics stale%' OR h LIKE 'table never analyzed%';
    PERFORM pg_catalog.set_config('search_path', 'pg_catalog, pg_temp', true);

    -- Candidate queries, best source first. Kept in a variable, not a temp
    -- table, so the function runs in read-only transactions.
    IF v_siq IS NOT NULL THEN
        v_source := 'pg_stat_index_queries';
        EXECUTE format($q$
            SELECT jsonb_agg(jsonb_build_array(c.queryid, c.calls))
              FROM (SELECT s.queryid, sum(s.calls_executed) AS calls
                      FROM %s s
                     WHERE s.indexrelid = $1
                       AND s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
                     GROUP BY 1) c $q$, v_siq) INTO v_cands USING p_index::oid;
    END IF;

    IF v_cands IS NULL AND index_deps.resolved_plan_source() <> 'none' THEN
        v_source := 'captured plans';
        SELECT jsonb_agg(jsonb_build_array(c.queryid, c.calls)) INTO v_cands
          FROM (SELECT d.queryid, sum(d.calls) AS calls
                  FROM index_deps.index_dependents d
                 WHERE d.indexrelid = p_index::oid
                 GROUP BY 1) c;
    END IF;

    IF v_cands IS NULL THEN
        -- Fallback: every statement whose text mentions the table.
        v_source := 'query text mentions table';
        EXECUTE format($q$
            SELECT jsonb_agg(jsonb_build_array(c.queryid, c.calls))
              FROM (SELECT s.queryid, sum(s.calls) AS calls
                      FROM %s s
                     WHERE s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
                       AND s.query ~* ('\m' || $1 || '\M')
                     GROUP BY 1) c $q$, v_pgss) INTO v_cands USING v_table_name;
    END IF;

    -- trusted: some role that recorded the query has the caller's
    -- privileges (pg_has_role USAGE; true for superusers). Dropped roles
    -- don't count. The text is one that such a role recorded when there is
    -- one (texts of one query ID can differ in comments).
    FOR r IN EXECUTE format($q$
        SELECT t.queryid, t.calls, coalesce(t.trusted_query, t.any_query) AS query,
               t.trusted_query IS NOT NULL AS trusted, t.roles
          FROM (SELECT (c.e ->> 0)::bigint AS queryid, (c.e ->> 1)::bigint AS calls,
                       max(s.query) FILTER (WHERE CASE WHEN ro.oid IS NOT NULL
                                                       THEN pg_has_role(s.userid, current_user, 'USAGE')
                                                       ELSE false END) AS trusted_query,
                       max(s.query) AS any_query,
                       string_agg(DISTINCT coalesce(ro.rolname::text, s.userid::text), ', ') AS roles
                  FROM jsonb_array_elements(coalesce($2, '[]')) AS c(e)
                  JOIN %s s
                    ON s.queryid = (c.e ->> 0)::bigint
                   AND s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
                  LEFT JOIN pg_roles ro ON ro.oid = s.userid
                 GROUP BY 1, 2) t
         ORDER BY 2 DESC NULLS LAST
         LIMIT $1 $q$, v_pgss) USING p_max_queries, v_cands
    LOOP
        queryid := r.queryid;
        calls := r.calls;
        query := left(r.query, 300);
        drop_blocker := v_blocker;
        cost_with := NULL; cost_without := NULL; cost_ratio := NULL;
        uses_index_now := NULL; uses_index_after := NULL; plan_changed := NULL;
        shape_with := NULL; shape_without := NULL;
        note := 'candidates from ' || v_source || coalesce('; ' || v_stats_note, '');

        IF clock_timestamp() - v_start > make_interval(secs => p_timeout_ms / 1000.0) THEN
            note := format('skipped: time budget used up (p_timeout_ms = %s)', p_timeout_ms);
            RETURN NEXT;
            CONTINUE;
        END IF;

        IF NOT r.trusted THEN
            IF NOT p_trust_other_roles THEN
                note := format('skipped: recorded only by %s, without your privileges; planning would run'
                               ' functions in its text as you (connect as that role to check it, or pass'
                               ' p_trust_other_roles => true)', r.roles);
                RETURN NEXT;
                CONTINUE;
            END IF;
            note := note || format('; planned with your privileges although recorded only by %s'
                                   ' (p_trust_other_roles)', r.roles);
        END IF;

        -- The rewriter resolves type names the way the query did.
        PERFORM pg_catalog.set_config('search_path', v_path, true);
        v_sql := index_deps.explainable_query(r.query);
        PERFORM pg_catalog.set_config('search_path', 'pg_catalog, pg_temp', true);

        IF v_sql !~* '^\s*(select|with|values|table)\M'
           AND NOT (p_include_dml AND v_sql ~* '^\s*(insert|update|delete|merge)\M') THEN
            note := 'skipped: not a read query (set p_include_dml => true to EXPLAIN DML)';
            RETURN NEXT;
            CONTINUE;
        END IF;

        -- pg_stat_statements stores one statement per entry, so a ";" left
        -- after a trailing one is in a comment or a quoted name; EXECUTE
        -- would run what follows it as a second statement.
        v_sql := regexp_replace(v_sql, ';\s*$', '');
        IF strpos(v_sql, ';') > 0 THEN
            note := 'skipped: the query text contains ";" (in a comment or quoted name)';
            RETURN NEXT;
            CONTINUE;
        END IF;
        v_explain := 'EXPLAIN (GENERIC_PLAN, FORMAT JSON) ' || v_sql;

        BEGIN
            -- search_path changes in this block are undone if it fails.
            PERFORM pg_catalog.set_config('search_path', v_path, true);
            EXECUTE v_explain INTO j_with;
            PERFORM pg_catalog.set_config('search_path', 'pg_catalog, pg_temp', true);

            EXECUTE v_hide USING p_index::oid;
            v_hidden := true;

            PERFORM pg_catalog.set_config('search_path', v_path, true);
            EXECUTE v_explain INTO j_without;
            PERFORM pg_catalog.set_config('search_path', 'pg_catalog, pg_temp', true);

            EXECUTE v_unhide USING p_index::oid;
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
            -- this query did, or the index is partial with a constant in its
            -- predicate (can't be proven against $n parameters: "status = $1"
            -- vs "WHERE status = 'open'"). "Unchanged" would understate the
            -- risk, so report unknown.
            IF NOT uses_index_now
               AND (v_source <> 'query text mentions table' OR v_pred_const) THEN
                plan_changed := NULL;
                note := 'unknown: the generic plan does not use the index'
                        || CASE WHEN v_source <> 'query text mentions table'
                                THEN ' but recorded plans of this query did' ELSE '' END
                        || CASE WHEN v_pred_const
                                THEN '; partial index (WHERE ' || v_pred
                                     || ') cannot be matched to $n parameters' ELSE '' END
                        || '; check with EXPLAIN using real values ('
                        || note || ')';
            END IF;

            -- HypoPG hypothetical indexes in this session take part in both
            -- plans, so the result isn't about the real schema.
            IF concat(shape_with, shape_without) ~ 'using <[0-9]+>' THEN
                note := note || '; warning: the plans use a hypothetical HypoPG index from this session'
                             || ' (hypopg_reset() to remove), so this is not the real schema';
            END IF;
        EXCEPTION
            WHEN query_canceled THEN
                -- Cancelled (statement_timeout, pg_cancel_backend): unhide,
                -- or the index stays hidden for the rest of the session.
                IF v_hidden THEN
                    EXECUTE v_unhide USING p_index::oid;
                END IF;
                RAISE;
            WHEN OTHERS THEN
                -- HypoPG state lives in backend memory, not in the
                -- transaction, so it must be undone here explicitly.
                IF v_hidden THEN
                    EXECUTE v_unhide USING p_index::oid;
                    v_hidden := false;
                END IF;
                note := 'skipped: ' || SQLERRM;
        END;

        RETURN NEXT;
    END LOOP;

    IF v_hidden THEN
        EXECUTE v_unhide USING p_index::oid;
    END IF;
    PERFORM pg_catalog.set_config('search_path', v_path, true);
    RETURN;
END;
$$;

COMMENT ON FUNCTION index_deps.index_drop_impact(regclass, boolean, integer, integer, boolean) IS
'Estimate what happens to dependent queries if an index is dropped. Hides the index with HypoPG (this session only), re-plans with EXPLAIN (GENERIC_PLAN), compares cost and plan shape. Never executes queries or drops anything. Works in read-only transactions. p_timeout_ms is a time budget for the whole call. Queries recorded only by roles without your privileges are skipped unless p_trust_other_roles (planning runs functions in the query text as you).';
