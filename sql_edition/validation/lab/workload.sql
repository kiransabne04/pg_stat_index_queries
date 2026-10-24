-- Index lab: workload definitions, execution, ground truth and lifecycle
-- changes. Included by lab.sql. Every statement carries a /* lab:Wnn */
-- comment (at the end, as sqlcommenter-style tools add it; W36 also has a
-- leading comment, which pg_stat_statements keeps before PG 18 and drops in 18)
-- so its pg_stat_statements entry can be mapped back to the case.

\echo '=== workload: cases'
INSERT INTO lab.cases (tag, area, title, match, known_gap) VALUES
 ('W01', 'scan',      'PK lookup (Index Scan)', 'exact', NULL),
 ('W02', 'index type','Expression index lower(email)', 'exact', NULL),
 ('W03', 'scan',      'Rare value on low-cardinality column', 'exact', NULL),
 ('W04', 'partial',   'Partial index without constant (deleted_at IS NULL), typed literals', 'exact', NULL),
 ('W05', 'index type','GIN jsonb_path_ops @>', 'exact', NULL),
 ('W06', 'index type','BRIN range on correlated column', 'exact', NULL),
 ('W07', 'index type','GiST KNN ORDER BY <-> LIMIT', 'exact', NULL),
 ('W08', 'index type','Hash index equality', 'exact', NULL),
 ('W09', 'index type','GIN pg_trgm LIKE', 'exact', NULL),
 ('W10', 'redundancy','Duplicate index pair (planner picks one)', 'exact', NULL),
 ('W11', 'scan',      'Only index for a lookup (drop-impact target)', 'exact', NULL),
 ('W12', 'redundancy','Customer lookup: single-column and composite index both qualify', 'exact', NULL),
 ('W13', 'redundancy','Composite index (customer_id, created_at)', 'exact', NULL),
 ('W14', 'plans',     'Skewed value: same query, index or seq scan by parameter', 'exact', NULL),
 ('W15', 'partial',   'Partial index with constant (status = ''pending'')', 'exact', NULL),
 ('W16', 'scan',      'ORDER BY ... LIMIT with no WHERE (Index Scan Backward)', 'exact', NULL),
 ('W17', 'scan',      'Covering index INCLUDE (Index Only Scan)', 'exact', NULL),
 ('W18', 'scan',      'Join: index on inner side of nested loop', 'exact', NULL),
 ('W19', 'scan',      'OR across two indexes (BitmapOr)', 'exact', NULL),
 ('W20', 'shape',     'CTE + LATERAL + UNION ALL', 'exact', NULL),
 ('W21', 'shape',     'IN list and = ANY(ARRAY[...])', 'exact', NULL),
 ('W22', 'shape',     'Query through a view (table not named in query text)', 'exact', NULL),
 ('W23', 'partition', 'Partitioned table, pruned to one partition', 'exact', NULL),
 ('W24', 'partition', 'Partitioned table, all partitions', 'exact', NULL),
 ('W25', 'naming',    'Mixed-case index name "Mixed Case Idx"', 'exact', NULL),
 ('W26', 'naming',    'Index name with spaces', 'exact', NULL),
 ('W27', 'naming',    'Non-ASCII index name', 'exact', NULL),
 ('W28', 'naming',    'Index name truncated to 63 bytes', 'exact', NULL),
 ('W29', 'naming',    'Same index name in two schemas (lab.amb, lab_b.amb)', 'exact',
         'plan text has no schema: both same-named indexes are credited (flagged ambiguous)'),
 ('W30', 'lifecycle', 'Index renamed after the plan was captured', 'exact',
         'plan text keeps the old name, which no longer resolves'),
 ('W31', 'lifecycle', 'Index dropped and recreated with the same name', 'exact', NULL),
 ('W32', 'scan',      'Seq-scan-only query (no index)', 'exact', NULL),
 ('W33', 'shape',     'UPDATE by primary key (DML)', 'exact', NULL),
 ('W34', 'shape',     'PREPARE / EXECUTE', 'subset', NULL),
 ('W35', 'nesting',   'Query inside a PL/pgSQL function (nested statement)', 'exact', NULL),
 ('W36', 'shape',     'Leading comment before SELECT', 'exact', NULL),
 ('W37', 'timeout',   'Query whose planning takes 0.2 s', 'exact', NULL),
 ('W39', 'database',  'Same table/index names queried in another database', 'exact', NULL),
 ('W40', 'replica',   'Workload run only on a reader / replica', 'exact', NULL),
 ('W41', 'role',      'Lookup through a UNIQUE constraint''s index', 'exact', NULL),
 ('W42', 'role',      'Overlap search through an EXCLUDE constraint''s index', 'exact', NULL),
 ('W90', 'shape',     'Calls lab.f_customer_refunds() (top-level wrapper of W35)', 'subset', NULL);

\echo '=== workload: statements'
INSERT INTO lab.workload (tag, kind, stmt)
SELECT tag, kind, stmt FROM (
  SELECT 'W01' tag, 'sql' kind, format('SELECT email FROM lab.customers WHERE id = %s /* lab:W01 */', g * 7919 % 200000 + 1) stmt FROM generate_series(1, 20) g
  UNION ALL SELECT 'W02', 'sql', format('SELECT id FROM lab.customers WHERE lower(email) = lower(%L) /* lab:W02 */', 'User' || g * 31 || '@example.com') FROM generate_series(1, 10) g
  UNION ALL SELECT 'W03', 'sql', 'SELECT count(*) FROM lab.customers WHERE country = ''ZZ'' /* lab:W03 */' FROM generate_series(1, 5) g
  UNION ALL SELECT 'W04', 'sql', format('SELECT id, created_at FROM lab.customers WHERE deleted_at IS NULL AND created_at > timestamptz %L + interval %L ORDER BY created_at LIMIT 20 /* lab:W04 */', '2026-03-01', g || ' days') FROM generate_series(1, 10) g
  UNION ALL SELECT 'W05', 'sql', 'SELECT count(*) FROM lab.customers WHERE profile @> ''{"tier": "gold"}'' /* lab:W05 */' FROM generate_series(1, 5) g
  UNION ALL SELECT 'W06', 'sql', format('SELECT count(*) FROM lab.customers WHERE created_at BETWEEN %L AND %L /* lab:W06 */', '2025-02-01', '2025-02-0' || (1 + g)) FROM generate_series(1, 5) g
  UNION ALL SELECT 'W07', 'sql', format('SELECT id FROM lab.customers ORDER BY geo <-> point(%s, %s) LIMIT 5 /* lab:W07 */', g * 97 % 1000, g * 53 % 1000) FROM generate_series(1, 10) g
  UNION ALL SELECT 'W08', 'sql', format('SELECT name FROM lab.products WHERE sku = %L /* lab:W08 */', 'SKU-' || g * 37) FROM generate_series(1, 10) g
  UNION ALL SELECT 'W09', 'sql', format('SELECT id FROM lab.products WHERE name LIKE %L /* lab:W09 */', '%widget-1' || g || '3%') FROM generate_series(1, 5) g
  UNION ALL SELECT 'W10', 'sql', format('SELECT count(price) FROM lab.products WHERE category = %s /* lab:W10 */', g * 13 % 200) FROM generate_series(1, 10) g
  UNION ALL SELECT 'W11', 'sql', format('SELECT sum(qty) FROM lab.order_items WHERE product_id = %s /* lab:W11 */', g * 101 % 20000 + 1) FROM generate_series(1, 10) g
  UNION ALL SELECT 'W12', 'sql', format('SELECT id, amount FROM lab.orders WHERE customer_id = %s /* lab:W12 */', g * 211 % 200000 + 1) FROM generate_series(1, 20) g
  UNION ALL SELECT 'W13', 'sql', format('SELECT count(*) FROM lab.orders WHERE customer_id = %s AND created_at >= %L /* lab:W13 */', g * 307 % 200000 + 1, '2026-06-01') FROM generate_series(1, 10) g
  UNION ALL SELECT 'W14', 'sql', format('SELECT sum(amount) FROM lab.orders WHERE status = %L /* lab:W14 */', CASE WHEN g <= 10 THEN 'refund' ELSE 'shipped' END) FROM generate_series(1, 15) g
  UNION ALL SELECT 'W15', 'sql', format('SELECT id FROM lab.orders WHERE status = %L AND created_at > %L ORDER BY created_at LIMIT 50 /* lab:W15 */', 'pending', '2026-09-0' || g) FROM generate_series(1, 9) g
  UNION ALL SELECT 'W16', 'sql', format('SELECT id, created_at FROM lab.orders ORDER BY created_at DESC LIMIT %s /* lab:W16 */', 5 + g) FROM generate_series(1, 5) g
  UNION ALL SELECT 'W17', 'sql', format('SELECT sum(amount) FROM lab.orders WHERE region = %s /* lab:W17 */', g) FROM generate_series(1, 10) g
  UNION ALL SELECT 'W18', 'sql', format('SELECT c.email, o.amount FROM lab.customers c JOIN lab.orders o ON o.customer_id = c.id WHERE c.id = %s /* lab:W18 */', g * 401 % 200000 + 1) FROM generate_series(1, 10) g
  UNION ALL SELECT 'W19', 'sql', format('SELECT count(*) FROM lab.orders WHERE customer_id = %s OR status = %L /* lab:W19 */', g * 503 % 200000 + 1, 'refund') FROM generate_series(1, 5) g
  UNION ALL SELECT 'W20', 'sql', format('WITH c AS (SELECT id FROM lab.customers WHERE country = %L) SELECT x.id FROM c CROSS JOIN LATERAL (SELECT o.id FROM lab.orders o WHERE o.customer_id = c.id ORDER BY o.created_at DESC LIMIT 3) x UNION ALL SELECT id FROM lab.orders WHERE id = %s /* lab:W20 */', 'ZZ', g) FROM generate_series(1, 5) g
  UNION ALL SELECT 'W21', 'sql', format('SELECT count(*) FROM lab.orders WHERE id IN (%s, %s, %s) OR id = ANY (ARRAY[%s, %s]) /* lab:W21 */', g, g + 10, g + 20, g + 30, g + 40) FROM generate_series(1, 5) g
  UNION ALL SELECT 'W22', 'sql', format('SELECT count(*) FROM lab.v_pending WHERE created_at > %L /* lab:W22 */', '2026-10-0' || g) FROM generate_series(1, 5) g
  UNION ALL SELECT 'W23', 'sql', format('SELECT count(*) FROM lab.events WHERE customer_id = %s AND created_at >= %L AND created_at < %L /* lab:W23 */', g * 601 % 200000 + 1, '2026-03-01', '2026-04-01') FROM generate_series(1, 10) g
  UNION ALL SELECT 'W24', 'sql', format('SELECT count(*) FROM lab.events WHERE customer_id = %s /* lab:W24 */', g * 701 % 200000 + 1) FROM generate_series(1, 10) g
  UNION ALL SELECT 'W25', 'sql', format('SELECT count(*) FROM lab."Mixed Case Tbl" WHERE "Val" = %s /* lab:W25 */', g) FROM generate_series(1, 5) g
  UNION ALL SELECT 'W26', 'sql', format('SELECT count(*) FROM lab."Mixed Case Tbl" WHERE w = %s /* lab:W26 */', g) FROM generate_series(1, 5) g
  UNION ALL SELECT 'W27', 'sql', format('SELECT count(*) FROM lab."Mixed Case Tbl" WHERE u = %s /* lab:W27 */', g) FROM generate_series(1, 5) g
  UNION ALL SELECT 'W28', 'sql', format('SELECT count(*) FROM lab."Mixed Case Tbl" WHERE l = %s /* lab:W28 */', g) FROM generate_series(1, 5) g
  UNION ALL SELECT 'W29', 'sql', format('SELECT count(*) FROM lab.amb WHERE v = %s /* lab:W29 */', g) FROM generate_series(1, 5) g
  UNION ALL SELECT 'W30', 'sql', format('SELECT count(*) FROM lab.life WHERE a = %s /* lab:W30 */', g) FROM generate_series(1, 5) g
  UNION ALL SELECT 'W31', 'sql', format('SELECT count(*) FROM lab.life WHERE b = %s /* lab:W31 */', g) FROM generate_series(1, 5) g
  UNION ALL SELECT 'W32', 'sql', format('SELECT count(*) FROM lab.orders WHERE amount::text LIKE %L /* lab:W32 */', '%.' || g || '7') FROM generate_series(1, 3) g
  UNION ALL SELECT 'W34', 'prepare', 'PREPARE lab_by_customer(int) AS SELECT count(*) FROM lab.orders o JOIN lab.order_items i ON i.order_id = o.id WHERE o.customer_id = $1 /* lab:W34 */'
  UNION ALL SELECT 'W34', 'exec', format('EXECUTE lab_by_customer(%s)', g * 809 % 200000 + 1) FROM generate_series(1, 10) g
  UNION ALL SELECT 'W35', 'truth', format('SELECT count(*) FROM lab.orders WHERE customer_id = %s AND status = ''refund''', g * 907 % 200000 + 1) FROM generate_series(1, 5) g
  UNION ALL SELECT 'W90', 'nested', format('SELECT lab.f_customer_refunds(%s) /* lab:W90 */', g * 907 % 200000 + 1) FROM generate_series(1, 5) g
  UNION ALL SELECT 'W36', 'sql', format('/* app:checkout */ SELECT amount FROM lab.orders WHERE id = %s /* lab:W36 */', g * 1009) FROM generate_series(1, 5) g
  UNION ALL SELECT 'W37', 'sql', format('SELECT id FROM lab.timeout_t WHERE a = %s AND lab.slow_plan() = 1 /* lab:W37 */', g) FROM generate_series(1, 3) g
  UNION ALL SELECT 'W41', 'sql', format('SELECT id FROM lab.customers WHERE email = %L /* lab:W41 */', 'user' || g * 53 || '@example.com') FROM generate_series(1, 10) g
  UNION ALL SELECT 'W42', 'sql', format('SELECT count(*) FROM lab.bookings WHERE during && tstzrange(%L, %L) /* lab:W42 */', timestamptz '2026-02-01' + g * interval '1 day', timestamptz '2026-02-01' + g * interval '1 day' + interval '3 hours') FROM generate_series(1, 5) g
  UNION ALL SELECT 'W39', 'other_db', format('SELECT count(*) FROM lab.dbx WHERE v = %s /* lab:W39 */', g) FROM generate_series(1, 5) g
  -- DML last: it touches the visibility map that index-only scans rely on.
  UNION ALL SELECT 'W33', 'sql', format('UPDATE lab.orders SET amount = amount WHERE id = %s /* lab:W33 */', g * 1201) FROM generate_series(1, 5) g
) w;

\echo '=== workload: run (output discarded)'
SELECT clock_timestamp() AS workload_start \gset
\o /dev/null
SELECT stmt FROM lab.workload WHERE kind IN ('sql', 'prepare', 'exec') ORDER BY ord \gexec
\o
SELECT round(extract(epoch FROM clock_timestamp() - :'workload_start'::timestamptz)::numeric, 1) AS workload_seconds;

-- W35 runs nested inside lab.f_customer_refunds() (called by W90). Only
-- visible with track = all, which is superuser-only on self-hosted servers
-- and may be refused on RDS/Aurora; record what we got. Only for these
-- calls: with track = all the lab's own EXPLAINs would be recorded too.
DO $$
BEGIN
    BEGIN
        SET pg_stat_statements.track = 'all';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'could not set pg_stat_statements.track: %', SQLERRM;
    END;
    IF current_setting('pg_stat_plans.track', true) IS NOT NULL THEN
        BEGIN
            SET pg_stat_plans.track = 'all';
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'could not set pg_stat_plans.track: %', SQLERRM;
        END;
    END IF;
    IF current_setting('pg_stat_index_queries.track', true) IS NOT NULL THEN
        BEGIN
            SET pg_stat_index_queries.track = 'all';
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'could not set pg_stat_index_queries.track: %', SQLERRM;
        END;
    END IF;
END $$;
INSERT INTO lab.env VALUES ('pg_stat_statements.track during W90', current_setting('pg_stat_statements.track', true));
\o /dev/null
SELECT stmt FROM lab.workload WHERE kind = 'nested' ORDER BY ord \gexec
\o
RESET pg_stat_statements.track;
DO $$ BEGIN
    IF current_setting('pg_stat_plans.track', true) IS NOT NULL THEN RESET pg_stat_plans.track; END IF;
    IF current_setting('pg_stat_index_queries.track', true) IS NOT NULL THEN RESET pg_stat_index_queries.track; END IF;
END $$;

\echo '=== workload: ground truth from EXPLAIN'
-- Same session, same statistics, same literals: the plan EXPLAIN prints is
-- the plan that ran (prepared statements may differ: W34 is matched as a
-- subset). Runs inside a function, so the EXPLAINs are nested statements and
-- don't show up as top-level entries.
CREATE FUNCTION lab.capture_truth() RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    r record;
    j json;
    n bigint := 0;
BEGIN
    FOR r IN SELECT DISTINCT tag, kind, stmt FROM lab.workload WHERE kind IN ('sql', 'exec', 'truth', 'nested') LOOP
        EXECUTE 'EXPLAIN (FORMAT JSON) ' || r.stmt INTO j;
        INSERT INTO lab.truth (tag, index_name)
        SELECT r.tag, i FROM lab.plan_indexes(j) i;
        n := n + 1;
        IF r.kind = 'exec' THEN
            -- Also the generic plan the prepared statement may switch to.
            EXECUTE 'EXPLAIN (FORMAT JSON, GENERIC_PLAN) ' ||
                    (SELECT regexp_replace(stmt, '^PREPARE \S+ AS ', '')
                       FROM lab.workload WHERE tag = r.tag AND kind = 'prepare')
               INTO j;
            INSERT INTO lab.truth (tag, index_name)
            SELECT r.tag, i FROM lab.plan_indexes(j) i;
        END IF;
    END LOOP;
    -- Resolve names; every workload table is in schema lab.
    UPDATE lab.truth t
       SET indexrelid = c.oid, qualname = format('%I.%I', n2.nspname, c.relname)
      FROM pg_class c JOIN pg_namespace n2 ON n2.oid = c.relnamespace
     WHERE c.relname = t.index_name AND n2.nspname = 'lab' AND c.relkind IN ('i', 'I');
    DELETE FROM lab.truth a USING lab.truth b
     WHERE a.ctid > b.ctid AND a.tag = b.tag AND a.index_name = b.index_name;
    RETURN n;
END;
$$;
SELECT lab.capture_truth() AS statements_explained;

-- Index OIDs and names as they were when the workload ran (the native
-- extension records OIDs; the lifecycle changes below rename/replace some).
CREATE TABLE lab.index_snapshot AS
SELECT c.oid, format('%I.%I', n.nspname, c.relname) AS qualname
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname IN ('lab', 'lab_b') AND c.relkind IN ('i', 'I');

\echo '=== workload: lifecycle changes after capture'
ALTER INDEX lab.life_renamed_idx RENAME TO life_renamed_idx_v2;
DROP INDEX lab.life_recreated_idx;
CREATE INDEX life_recreated_idx ON lab.life (b);

INSERT INTO lab.known_index_gaps VALUES
  ('lab.life_renamed_idx_v2', 'renamed after capture: plans name life_renamed_idx, which no longer exists'),
  ('lab_b.amb_v_idx', 'same name as lab.amb_v_idx: credited with lab.amb queries (ambiguous)'),
  ('lab.life_invalid_idx', 'withheld (conservative): plans on lab.life name life_renamed_idx, which no longer exists');

-- Self-hosted pg_stat_plans flushes lazily (PG 15+ has the flush function).
SELECT to_regprocedure('pg_stat_force_next_flush()') IS NOT NULL AS has_force_flush \gset
\if :has_force_flush
SELECT pg_stat_force_next_flush();
\endif
SELECT pg_sleep(2);
