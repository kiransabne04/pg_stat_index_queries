-- Security review (SQL edition 0.8).
-- 1. index_drop_impact plans other users' query text. Planning runs
--    IMMUTABLE functions with constant arguments with the caller's
--    privileges (SET ROLE is no barrier: code in the query can undo it), so
--    a query recorded only by a role without the caller's privileges is
--    skipped unless p_trust_other_roles. The caller's own queries are
--    planned.
-- 2. Objects of other extensions (HypoPG, pg_stat_statements) are called by
--    their extension's schema, so a same-named function earlier in the
--    caller's search_path is never run.
-- 3. A query text with ";" (possible only inside a comment) is skipped:
--    EXECUTE would run a second statement.
CREATE ROLE siq_low;
CREATE SCHEMA siq_low AUTHORIZATION siq_low;
CREATE TABLE sec_t (id int PRIMARY KEY, v int);
INSERT INTO sec_t SELECT g, g FROM generate_series(1, 1000) g;
ANALYZE sec_t;
GRANT SELECT ON sec_t TO siq_low;
SET ROLE siq_low;
CREATE TABLE siq_low.log (who text, what text);
-- Read-only commands are allowed in an IMMUTABLE function, and some are
-- powerful in a superuser's hands (COPY ... TO PROGRAM, pg_read_file).
-- Here it only records who ran it.
CREATE FUNCTION siq_low.evil() RETURNS int LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    PERFORM set_config('siq.evil_ran_as', current_user, false);
    RETURN 1;
END $$;
CREATE FUNCTION siq_low.hypopg_hide_index(oid) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO siq_low.log VALUES (current_user, 'fake hypopg');
    RETURN true;
END $$;
SELECT v FROM public.sec_t WHERE id = siq_low.evil();
DELETE FROM siq_low.log;
RESET ROLE;
-- The caller's own queries: planned, except the one with ";" in a comment.
SELECT v FROM public.sec_t WHERE id = 7;
SELECT v FROM public.sec_t /* ; */ WHERE id = 5 AND v > 0;

-- The caller has siq_low early in its search_path.
SELECT set_config('siq.evil_ran_as', 'nobody', false) IS NOT NULL AS cleared;
SET search_path = siq_low, public;
SELECT left(query, 45) AS query, cost_with IS NOT NULL AS planned, note
  FROM index_deps.index_drop_impact('public.sec_t_pkey')
 ORDER BY 1;
RESET search_path;
-- evil() never ran.
SELECT current_setting('siq.evil_ran_as') AS evil_ran_as;
-- The fake HypoPG function never ran.
SELECT who, what, count(*) FROM siq_low.log GROUP BY 1, 2 ORDER BY 1, 2;
SELECT count(*) AS still_hidden FROM hypopg_hidden_indexes();

-- p_trust_other_roles: planned with the caller's privileges, as documented.
SELECT left(query, 45) AS query, cost_with IS NOT NULL AS planned,
       note LIKE '%planned with your privileges although recorded only by siq_low%' AS noted
  FROM index_deps.index_drop_impact('public.sec_t_pkey', p_trust_other_roles => true)
 WHERE query LIKE '%evil%';
SELECT current_setting('siq.evil_ran_as') = current_user AS evil_ran_as_caller;
SELECT count(*) AS still_hidden FROM hypopg_hidden_indexes();
-- search_path is the caller's again afterwards.
SET search_path = siq_low, public;
SELECT count(*) AS rows FROM index_deps.index_drop_impact('public.sec_t_pkey');
SELECT current_setting('search_path') AS search_path;
RESET search_path;

-- 4. Without HypoPG, or without the right to use it, the check refuses to
--    run instead of planning with the index still visible.
DROP EXTENSION hypopg;
SELECT count(*) FROM index_deps.index_drop_impact('public.sec_t_pkey');
CREATE EXTENSION hypopg;
REVOKE EXECUTE ON FUNCTION hypopg_hide_index(oid) FROM PUBLIC;
SET ROLE siq_low;
SELECT count(*) FROM index_deps.index_drop_impact('public.sec_t_pkey');
RESET ROLE;
GRANT EXECUTE ON FUNCTION hypopg_hide_index(oid) TO PUBLIC;

DROP TABLE sec_t;
DROP SCHEMA siq_low CASCADE;
DROP ROLE siq_low;
