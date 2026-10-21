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
