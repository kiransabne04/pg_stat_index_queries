-- Drop-impact check with HypoPG + EXPLAIN (GENERIC_PLAN).
CREATE EXTENSION hypopg;

SELECT count(*) FROM o WHERE c = 7;

SELECT uses_index_now, uses_index_after, plan_changed,
       cost_without > cost_with AS gets_more_expensive, note, query
  FROM index_deps.index_drop_impact('o_c_idx')
 WHERE query LIKE '%FROM o WHERE c =%';

-- The index is never left hidden.
SELECT count(*) AS still_hidden FROM hypopg_hidden_indexes();

-- Error path: a dependent query that no longer plans (column dropped).
ALTER TABLE o ADD COLUMN x int;
SELECT count(*) FROM o WHERE c = 9 AND x IS NULL;
ALTER TABLE o DROP COLUMN x;
SELECT note LIKE 'skipped: column "x" does not exist%' AS skipped_cleanly
  FROM index_deps.index_drop_impact('o_c_idx')
 WHERE query LIKE '%x IS NULL%';
SELECT count(*) AS still_hidden FROM hypopg_hidden_indexes();

-- Non-read queries are skipped unless asked.
UPDATE o SET s = s WHERE c = 11;
SELECT note FROM index_deps.index_drop_impact('o_c_idx') WHERE query LIKE 'UPDATE o%';

-- Errors
SELECT index_deps.index_drop_impact('o'::regclass);

-- Query text EXPLAIN can't take as is: typed literals and PREPARE.
SELECT q AS input, index_deps.explainable_query(q) AS explained
  FROM unnest(ARRAY[
    'SELECT id, ts FROM t WHERE ts >= timestamptz $1 - $2 * interval $3',
    'SELECT timestamp with time zone $1, double precision $2, character varying $3',
    'SELECT id, a FROM t WHERE a BETWEEN $1 AND $2 LIMIT $3',
    'SELECT $1 AT TIME ZONE $2',
    'SELECT a FROM t WHERE b LIKE $1 ESCAPE $2',
    'PREPARE p(int, numeric(10,2)) AS SELECT $1 + $2, $10',
    'prepare "Q"  as select 1',
    'SELECT 1',
    '/* app:checkout */ SELECT id, a FROM t WHERE a = $1',
    E'-- traced\n  /* a */ /* b */ PREPARE p(int) AS SELECT $1',
    'SELECT 1 /* trailing comment stays */'
  ]) AS q;

SELECT count(*) FROM o WHERE c = 8 AND now() - interval '1 day' < now();
PREPARE q8(int) AS SELECT count(*) FROM o WHERE c = $1;
EXECUTE q8(3);
DEALLOCATE q8;
SELECT left(query, 40) AS query, note, uses_index_now, uses_index_after
  FROM index_deps.index_drop_impact('o_c_idx')
 WHERE query LIKE '%interval%' OR query LIKE 'PREPARE q8%'
 ORDER BY query;
SELECT count(*) AS still_hidden FROM hypopg_hidden_indexes();

-- Partial indexes. pg_stat_statements replaces constants with $n, so a
-- generic plan can't prove "status = $1" implies the index predicate
-- "status = 'open'" and never uses the index. Real executions did, so the
-- result must be unknown, not "plan unchanged".
CREATE TABLE pi (id int, k int, status text, deleted_at timestamptz);
INSERT INTO pi SELECT g, g % 500,
       CASE WHEN g % 100 = 0 THEN 'open' ELSE 'closed' END,
       CASE WHEN g % 100 = 0 THEN NULL ELSE now() END
  FROM generate_series(1, 100000) g;
CREATE INDEX pi_open_idx ON pi (k) WHERE status = 'open';
CREATE INDEX pi_live_idx ON pi (id) WHERE deleted_at IS NULL;
VACUUM ANALYZE pi;
SELECT count(*) FROM pi WHERE status = 'open' AND k = 100;
SELECT count(*) FROM pi WHERE deleted_at IS NULL AND id < 5000;
SELECT left(query, 50) AS query, uses_index_now, plan_changed, note
  FROM index_deps.index_drop_impact('pi_open_idx')
 WHERE query LIKE '%FROM pi%'
 ORDER BY query;
-- A predicate without constants ("IS NULL") survives normalization, so the
-- generic plan can use the index and the result is a normal estimate.
SELECT left(query, 50) AS query, uses_index_now, plan_changed, note
  FROM index_deps.index_drop_impact('pi_live_idx')
 WHERE query LIKE '%FROM pi%'
 ORDER BY query;
SELECT count(*) AS still_hidden FROM hypopg_hidden_indexes();

-- No plan source (RDS): candidates are statements whose text mentions the
-- table, so nothing says the index was used. A partial index with a constant
-- in its predicate is unknown for every query the generic plan doesn't use
-- it for (including ones that never needed it: safe, not precise). A
-- constant-free predicate isn't affected by $n, so "unchanged" stands.
UPDATE index_deps.config SET value = 'none' WHERE key = 'plan_source';
SELECT left(query, 50) AS query, uses_index_now, plan_changed, note
  FROM index_deps.index_drop_impact('pi_open_idx')
 WHERE query LIKE 'SELECT count(*) FROM pi%'
 ORDER BY query;
SELECT left(query, 50) AS query, uses_index_now, plan_changed, note
  FROM index_deps.index_drop_impact('pi_live_idx')
 WHERE query LIKE 'SELECT count(*) FROM pi%'
 ORDER BY query;
UPDATE index_deps.config SET value = 'auto' WHERE key = 'plan_source';
SELECT count(*) AS still_hidden FROM hypopg_hidden_indexes();

-- 0.4: runs in a read-only transaction (Aurora reader, hot standby).
BEGIN READ ONLY;
SELECT uses_index_now, uses_index_after, plan_changed, note
  FROM index_deps.index_drop_impact('o_c_idx')
 WHERE query LIKE '%FROM o WHERE c = $1';
COMMIT;

-- 0.4: p_timeout_ms is a budget for the whole call; once used up, the
-- remaining queries are reported as skipped.
SELECT DISTINCT note FROM index_deps.index_drop_impact('o_c_idx', p_timeout_ms => 0);

-- 0.4: a hypothetical HypoPG index in the session is flagged.
SELECT indexname LIKE '<%>btree_o_c' AS hypothetical FROM hypopg_create_index('CREATE INDEX ON o (c)');
SELECT note LIKE '%warning: the plans use a hypothetical HypoPG index%' AS warned
  FROM index_deps.index_drop_impact('o_c_idx')
 WHERE query LIKE '%FROM o WHERE c = $1';
SELECT hypopg_reset();

-- 0.4: drop_blocker says what else depends on the index.
SELECT DISTINCT drop_blocker FROM index_deps.index_drop_impact('o_pkey');

-- 0.4: cancelled while the index is hidden, it must still be unhidden.
-- Planning this query takes 0.5 s (immutable function folded at plan time):
-- EXPLAIN 0.5 s, hide, EXPLAIN 0.5 s; cancelled at 0.75 s, during the second.
CREATE FUNCTION slow_plan() RETURNS int LANGUAGE plpgsql IMMUTABLE AS
$$ BEGIN PERFORM pg_sleep(0.5); RETURN 1; END $$;
CREATE TABLE sp (id int, a int);
INSERT INTO sp SELECT g, g % 100 FROM generate_series(1, 10000) g;
CREATE INDEX sp_a_idx ON sp (a);
ANALYZE sp;
SELECT count(*) FROM sp WHERE a = 5 AND slow_plan() = 1;
SELECT pg_stat_force_next_flush();
\set VERBOSITY terse
SET statement_timeout = '750ms';
SELECT count(*) FROM index_deps.index_drop_impact('sp_a_idx');
RESET statement_timeout;
\set VERBOSITY default
SELECT count(*) AS still_hidden FROM hypopg_hidden_indexes();
