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
    'SELECT * FROM t WHERE ts >= timestamptz $1 - $2 * interval $3',
    'SELECT timestamp with time zone $1, double precision $2, character varying $3',
    'SELECT * FROM t WHERE a BETWEEN $1 AND $2 LIMIT $3',
    'SELECT $1 AT TIME ZONE $2',
    'SELECT a FROM t WHERE b LIKE $1 ESCAPE $2',
    'PREPARE p(int, numeric(10,2)) AS SELECT $1 + $2, $10',
    'prepare "Q"  as select 1',
    'SELECT 1'
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
