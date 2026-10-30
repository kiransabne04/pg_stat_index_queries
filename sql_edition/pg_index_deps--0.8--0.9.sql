/* pg_index_deps--0.8--0.9.sql */

\echo Use "ALTER EXTENSION pg_index_deps UPDATE TO '0.9'" to load this file. \quit

-- 0.8 found no plan source on Aurora: it looked for aurora_stat_plans in
-- pg_proc, and Aurora hides its built-in functions from pg_proc queries,
-- so the dependents views were empty and drop impact fell back to matching
-- query text. pg_catalog functions are now found by resolving the
-- pg_catalog-qualified name.

-- Schema-qualified name of function p_name(p_args) that belongs to
-- extension p_ext, or NULL. p_ext NULL: a function in pg_catalog or in any
-- extension. pg_catalog is checked by resolving the qualified name, not by
-- reading pg_proc: Aurora hides its built-in functions (aurora_stat_plans,
-- OID 9888 on 17.11) from pg_proc queries. Other extensions' objects are
-- called by this name, never through the caller's search_path, so a
-- same-named function in a schema earlier in it never runs. One the caller
-- may not use (no USAGE on its schema, no EXECUTE) counts as absent.
CREATE OR REPLACE FUNCTION index_deps.ext_function(p_ext name, p_name name, p_args regtype[])
RETURNS text
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT coalesce(
        (SELECT format('pg_catalog.%I', p_name)
          WHERE p_ext IS NULL
            AND has_function_privilege(
                    to_regprocedure(format('pg_catalog.%I(%s)', p_name, array_to_string(p_args::text[], ', '))),
                    'EXECUTE')),
        (SELECT format('%I.%I', n.nspname, p.proname)
           FROM pg_proc p
           JOIN pg_namespace n ON n.oid = p.pronamespace
          WHERE p.proname = p_name
            AND p.proargtypes = array_to_string(p_args::oid[], ' ')::oidvector
            AND has_schema_privilege(n.oid, 'USAGE')
            AND has_function_privilege(p.oid, 'EXECUTE')
            AND EXISTS (SELECT 1
                          FROM pg_depend d
                          JOIN pg_extension e ON e.oid = d.refobjid
                         WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid
                           AND d.refclassid = 'pg_extension'::regclass AND d.deptype = 'e'
                           AND (p_ext IS NULL OR e.extname = p_ext))
          ORDER BY n.nspname
          LIMIT 1))
$$;
