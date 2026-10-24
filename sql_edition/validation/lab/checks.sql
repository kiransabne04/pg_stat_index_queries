-- Index lab: checks. Included by lab.sql after the workload. Each check
-- writes one row to lab.results (PASS / FAIL / KNOWN / SKIP / INFO).

\echo '=== checks: environment'
SELECT index_deps.resolved_plan_source() <> 'none' AS has_plans,
       to_regprocedure('hypopg_hide_index(oid)') IS NOT NULL
         AND current_setting('server_version_num')::int >= 160000 AS can_drop_impact,
       to_regclass('lab_native.pg_stat_index_queries') IS NOT NULL AS has_native,
       to_regprocedure('aurora_version()') IS NOT NULL AS is_aurora
\gset

-- W12 can use orders_customer_idx or orders_customer_created_idx; target
-- the one the planner picked, the other should take over.
SELECT coalesce((SELECT index_name FROM lab.truth WHERE tag = 'W12' AND index_name LIKE 'orders_customer%' LIMIT 1),
                'orders_customer_idx') AS cust_used \gset
SELECT CASE :'cust_used' WHEN 'orders_customer_idx' THEN 'orders_customer_created_idx'
                         ELSE 'orders_customer_idx' END AS cust_other \gset
INSERT INTO lab.env
SELECT * FROM (VALUES
    ('label', :'label'),
    ('server_version', current_setting('server_version')),
    ('plan source', index_deps.resolved_plan_source()),
    ('pg_index_deps', coalesce((SELECT extversion FROM pg_extension WHERE extname = 'pg_index_deps'), 'plain install')),
    ('hypopg', (SELECT extversion FROM pg_extension WHERE extname = 'hypopg')),
    ('pg_stat_statements', (SELECT extversion FROM pg_extension WHERE extname = 'pg_stat_statements')),
    ('pg_stat_plans', (SELECT extversion FROM pg_extension WHERE extname = 'pg_stat_plans')),
    ('native pg_stat_index_queries (ground truth)', (SELECT extversion FROM pg_extension WHERE extname = 'pg_stat_index_queries')),
    ('shared_preload_libraries', current_setting('shared_preload_libraries', true)),
    ('compute_query_id', current_setting('compute_query_id', true)),
    ('aurora_compute_plan_id', current_setting('aurora_compute_plan_id', true)),
    ('pg_stat_statements.max', current_setting('pg_stat_statements.max', true)),
    ('scale', :'scale'),
    ('lab rows (orders)', (SELECT count(*)::text FROM lab.orders)),
    ('lab indexes', (SELECT count(*)::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                      WHERE n.nspname IN ('lab', 'lab_b') AND c.relkind IN ('i', 'I'))),
    ('run at', now()::text)
) v(k, v)
ON CONFLICT (k) DO UPDATE SET v = excluded.v;
\if :is_aurora
INSERT INTO lab.env VALUES ('aurora_version', aurora_version()) ON CONFLICT (k) DO UPDATE SET v = excluded.v;
\endif

-- Check results go to lab.results; keep the log readable.
\o /dev/null

CREATE FUNCTION lab.chk_bool(p_case text, p_area text, p_title text, p_severity text,
                             p_ok boolean, p_expected text, p_actual text,
                             p_known text DEFAULT NULL, p_detail text DEFAULT NULL)
RETURNS void LANGUAGE sql AS $$
    INSERT INTO lab.results (case_id, area, title, severity, status, expected, actual, detail)
    VALUES (p_case, p_area, p_title, p_severity,
            CASE WHEN coalesce(p_ok, false) THEN 'PASS'
                 WHEN p_known IS NOT NULL THEN 'KNOWN' ELSE 'FAIL' END,
            p_expected, p_actual,
            CASE WHEN coalesce(p_ok, false) THEN p_detail ELSE concat_ws(' | ', p_known, p_detail) END);
$$;

-- Per-tag index sets: ground truth, SQL edition, native.
CREATE TABLE lab.attribution AS
WITH tm AS (SELECT * FROM lab.tag_map()),
truth AS (
    SELECT tag, array_agg(DISTINCT qualname ORDER BY qualname) AS idx
      FROM lab.truth GROUP BY tag
),
tool AS (
    SELECT tm.tag,
           array_agg(DISTINCT format('%I.%I', d.schemaname, d.indexname)
                     ORDER BY format('%I.%I', d.schemaname, d.indexname)) AS idx,
           sum(d.calls)::bigint AS calls,
           bool_or(d.ambiguous) AS ambiguous
      FROM index_deps.index_dependents d
      JOIN tm ON tm.queryid = d.queryid
     WHERE d.schemaname IN ('lab', 'lab_b')
     GROUP BY tm.tag
),
calls AS (SELECT tag, sum(calls)::bigint AS calls FROM tm GROUP BY tag)
SELECT c.tag, c.area, c.title, c.match, c.known_gap,
       coalesce(truth.idx, '{}') AS truth_idx,
       coalesce(tool.idx, '{}')  AS tool_idx,
       NULL::text[]              AS native_idx,
       calls.calls               AS pgss_calls,
       tool.calls                AS tool_calls,
       tool.ambiguous
  FROM lab.cases c
  LEFT JOIN truth USING (tag)
  LEFT JOIN tool USING (tag)
  LEFT JOIN calls USING (tag)
 WHERE c.tag NOT IN ('W39', 'W40');

\if :has_native
-- Native extension: exact executed counts per OID; names as they were when
-- the workload ran.
DO $$
BEGIN
    EXECUTE $q$
    UPDATE lab.attribution a
       SET native_idx = n.idx
      FROM (SELECT tm.tag, array_agg(DISTINCT coalesce(s.qualname, 'oid:' || q.indexrelid)
                                     ORDER BY coalesce(s.qualname, 'oid:' || q.indexrelid)) AS idx
              FROM lab_native.pg_stat_index_queries q
              JOIN lab.tag_map() tm ON tm.queryid = q.queryid
              LEFT JOIN lab.index_snapshot s ON s.oid = q.indexrelid
             WHERE q.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
               AND q.calls_executed > 0
               AND (s.qualname IS NULL OR s.qualname LIKE 'lab.%' OR s.qualname LIKE 'lab_b.%')
             GROUP BY tm.tag) n
     WHERE n.tag = a.tag $q$;
    UPDATE lab.attribution SET native_idx = '{}' WHERE native_idx IS NULL;
END $$;
\endif

\echo '=== checks: attribution (which indexes each query used)'
\if :has_plans
SELECT lab.chk_bool(
         'A-' || tag, 'attribution', tag || ' ' || title,
         CASE WHEN NOT truth_idx <@ tool_idx THEN 'high' ELSE 'low' END,
         CASE WHEN match = 'exact' THEN tool_idx = truth_idx
              ELSE tool_idx <@ truth_idx AND (truth_idx = '{}' OR tool_idx <> '{}') END,
         CASE WHEN match = 'exact' THEN '' ELSE 'subset of ' END || array_to_string(truth_idx, ', '),
         array_to_string(tool_idx, ', '),
         CASE WHEN tag = 'W35' AND (SELECT v FROM lab.env WHERE k = 'pg_stat_statements.track during W90') IS DISTINCT FROM 'all'
              THEN 'nested statements are not tracked with pg_stat_statements.track = top (could not set it to all)'
              ELSE known_gap END,
         CASE WHEN pgss_calls IS NULL AND tag NOT IN ('W35')
              THEN 'no pg_stat_statements entry found for this tag' END)
  FROM lab.attribution
 ORDER BY tag;

SELECT lab.chk_bool('A-W29-flag', 'attribution', 'W29 same-name indexes are flagged ambiguous', 'medium',
                    ambiguous, 'ambiguous = true', coalesce(ambiguous::text, '(no rows)'))
  FROM lab.attribution WHERE tag = 'W29';

-- Calls: every call of a single-plan query is attributed; for W14 only the
-- calls whose plan used the index.
SELECT lab.chk_bool('A-calls-W12', 'attribution', 'W12 calls attributed = pg_stat_statements calls', 'medium',
                    tool_calls = pgss_calls, pgss_calls::text, tool_calls::text)
  FROM lab.attribution WHERE tag = 'W12';
SELECT lab.chk_bool('A-calls-W14', 'attribution', 'W14 skewed query: index credited with only the index-plan calls', 'medium',
                    tool_calls > 0 AND tool_calls < pgss_calls,
                    '0 < calls < ' || pgss_calls, tool_calls::text)
  FROM lab.attribution WHERE tag = 'W14';
\else
SELECT lab.chk_bool('A-none', 'attribution', 'No plan source: no index is attributed to any query', 'high',
                    NOT EXISTS (SELECT 1 FROM lab.attribution WHERE tool_idx <> '{}'),
                    'no rows', (SELECT string_agg(tag, ', ') FROM lab.attribution WHERE tool_idx <> '{}'));
\endif

\if :has_native
SELECT lab.chk_bool(
         'N-' || tag, 'native', tag || ' native extension = EXPLAIN truth',
         'info',
         CASE WHEN match = 'exact' THEN native_idx = truth_idx
              ELSE native_idx <@ truth_idx AND (truth_idx = '{}' OR native_idx <> '{}') END,
         array_to_string(truth_idx, ', '), array_to_string(native_idx, ', '),
         CASE WHEN tag = 'W35' THEN 'native tracks nested statements only when pg_stat_statements assigns them a queryid (track = all)' END)
  FROM lab.attribution
 ORDER BY tag;
\endif

\echo '=== checks: unused indexes (index_no_dependents)'
-- Ideal: an index is used if the truth names its OID (renamed indexes keep
-- theirs), or its name when it was recreated after the workload; a
-- partitioned index is used if any partition's index is.
CREATE TABLE lab.index_expect AS
WITH used AS (
    SELECT DISTINCT indexrelid AS oid FROM lab.truth WHERE indexrelid IS NOT NULL
),
idx AS (
    SELECT c.oid, format('%I.%I', n.nspname, c.relname) AS qualname, c.relkind, c.relispartition,
           x.indisprimary OR x.indisunique
             OR EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conindid = c.oid) AS excluded,
           x.indisvalid
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_index x ON x.indexrelid = c.oid
     WHERE n.nspname IN ('lab', 'lab_b')
)
SELECT i.oid, i.qualname, i.indisvalid,
       EXISTS (SELECT 1 FROM used u
                WHERE u.oid = i.oid
                   OR u.oid IN (SELECT p.relid FROM pg_partition_tree(i.oid) p)
                   OR (i.oid NOT IN (SELECT oid FROM lab.index_snapshot)
                       AND i.qualname IN (SELECT qualname FROM lab.truth))) AS ideal_used
  FROM idx i
 WHERE NOT i.excluded AND NOT i.relispartition;

\if :has_plans
SELECT lab.chk_bool(
         'U-' || e.qualname, 'unused', 'index_no_dependents: ' || e.qualname,
         CASE WHEN e.ideal_used AND nd.indexrelid IS NOT NULL THEN 'critical' ELSE 'low' END,
         e.ideal_used = (nd.indexrelid IS NULL),
         CASE WHEN e.ideal_used THEN 'used' ELSE 'unused' END,
         CASE WHEN nd.indexrelid IS NULL THEN 'used' ELSE 'unused' END,
         g.gap,
         CASE WHEN NOT e.indisvalid THEN 'invalid index (failed CREATE INDEX CONCURRENTLY)'
              WHEN e.qualname = 'lab.reader_only_idx' THEN 'only used on the reader; each instance keeps its own plan statistics'
              WHEN e.qualname = 'lab.dbx_v_idx' THEN 'same name used in database index_lab2 only'
         END)
  FROM lab.index_expect e
  LEFT JOIN index_deps.index_no_dependents nd ON nd.indexrelid = e.oid
  LEFT JOIN lab.known_index_gaps g ON g.qualname = e.qualname
 ORDER BY e.qualname;

SELECT lab.chk_bool('U-partition-children', 'unused', 'Partition indexes are never listed on their own', 'medium',
                    count(*) = 0, '0', count(*)::text)
  FROM index_deps.index_no_dependents nd JOIN pg_class c ON c.oid = nd.indexrelid
 WHERE c.relispartition;
\else
SELECT lab.chk_bool('U-none', 'unused', 'No plan source: index_no_dependents lists nothing', 'critical',
                    count(*) = 0, '0', count(*)::text)
  FROM index_deps.index_no_dependents WHERE schemaname IN ('lab', 'lab_b');
\endif

\if :has_native
DO $$
BEGIN
    EXECUTE $q$
    SELECT lab.chk_bool(
             'NU-' || e.qualname, 'native', 'native pg_index_no_dependents: ' || e.qualname,
             CASE WHEN e.ideal_used AND nd.indexrelid IS NOT NULL THEN 'critical' ELSE 'low' END,
             e.ideal_used = (nd.indexrelid IS NULL),
             CASE WHEN e.ideal_used THEN 'used' ELSE 'unused' END,
             CASE WHEN nd.indexrelid IS NULL THEN 'used' ELSE 'unused' END,
             CASE WHEN e.qualname = 'lab.life_recreated_idx'
                  THEN 'recreated after the workload: the new OID has not run yet (expected for an OID-based tracker)' END)
      FROM lab.index_expect e
      LEFT JOIN lab_native.pg_index_no_dependents nd ON nd.indexrelid = e.oid $q$;
END $$;
\endif

\echo '=== checks: index_query_stats'
\if :has_plans
SELECT lab.chk_bool('Q-W14-pct', 'query_stats', 'W14 pct_calls_using_index between 0 and 100 (plan flips)', 'medium',
                    q.pct_calls_using_index > 0 AND q.pct_calls_using_index < 100,
                    '0 < pct < 100', coalesce(q.pct_calls_using_index::text, '(no row)'))
  FROM (SELECT 1) x
  LEFT JOIN (SELECT s.* FROM index_deps.index_query_stats s JOIN lab.tag_map() tm USING (queryid)
              WHERE tm.tag = 'W14' AND s.indexname = 'orders_status_idx') q ON true;

SELECT lab.chk_bool('Q-W12-stats', 'query_stats', 'W12 row has calls, timing, rows and cache stats', 'medium',
                    q.calls = 20 AND q.index_calls = 20 AND q.mean_exec_ms IS NOT NULL
                      AND q.rows_per_call IS NOT NULL AND q.cache_hit_pct IS NOT NULL,
                    'calls 20, index_calls 20, stats not null',
                    format('calls %s, index_calls %s, mean_ms %s, rows/call %s, hit%% %s',
                           q.calls, q.index_calls, round(q.mean_exec_ms::numeric, 3), q.rows_per_call, q.cache_hit_pct))
  FROM (SELECT 1) x
  LEFT JOIN (SELECT s.* FROM index_deps.index_query_stats s JOIN lab.tag_map() tm USING (queryid)
              WHERE tm.tag = 'W12' AND s.indexname = :'cust_used') q ON true;

SELECT lab.chk_bool('Q-W18-other', 'query_stats', 'W18 join: other_indexes names the other side', 'low',
                    q.other_indexes IS NOT NULL AND cardinality(q.other_indexes) > 0,
                    'non-empty', coalesce(array_to_string(q.other_indexes, ', '), '(null)'))
  FROM (SELECT 1) x
  LEFT JOIN (SELECT s.* FROM index_deps.index_query_stats s JOIN lab.tag_map() tm USING (queryid)
              WHERE tm.tag = 'W18' AND s.indexname LIKE 'orders%' LIMIT 1) q ON true;
\else
SELECT lab.chk_bool('Q-none', 'query_stats', 'No plan source: index_query_stats is empty for the lab', 'medium',
                    count(*) = 0, '0', count(*)::text)
  FROM index_deps.index_query_stats WHERE schemaname IN ('lab', 'lab_b');
\endif

\echo '=== checks: index roles and index_usage'
SELECT lab.chk('R-pk', 'roles', 'customers_pkey: primary key referenced by a foreign key', 'medium',
               'primary key | referenced by foreign key orders_customer_fk on lab.orders',
               (SELECT index_role || ' | ' || array_to_string(index_notes, ', ') FROM index_deps.index_role('lab.customers_pkey')));
SELECT lab.chk('R-unique-constraint', 'roles', 'customers_email_key: unique constraint', 'medium',
               'unique constraint', (SELECT index_role FROM index_deps.index_role('lab.customers_email_key')));
SELECT lab.chk('R-exclusion', 'roles', 'bookings_no_overlap: exclusion constraint', 'medium',
               'exclusion constraint', (SELECT index_role FROM index_deps.index_role('lab.bookings_no_overlap')));
SELECT lab.chk('R-replica-identity', 'roles', 'timeout_id_uq: unique index, replica identity', 'medium',
               'unique index | replica identity',
               (SELECT index_role || ' | ' || array_to_string(index_notes, ', ') FROM index_deps.index_role('lab.timeout_id_uq')));
SELECT lab.chk_bool('R-clustered', 'roles', 'life_pkey is marked clustered', 'low',
                    'clustered (CLUSTER uses it)' = ANY (index_notes), 'clustered note',
                    array_to_string(index_notes, ', '))
  FROM index_deps.index_role('lab.life_pkey');
SELECT lab.chk_bool('R-partition', 'roles', 'Partition index points to its parent', 'low',
                    drop_blocker LIKE 'attached to partitioned index lab.events_customer_idx%',
                    'attached to partitioned index lab.events_customer_idx', drop_blocker)
  FROM index_deps.index_role('lab.events_2026_03_customer_id_idx');
SELECT lab.chk_bool('R-dependents-role', 'roles', 'index_dependents shows the role (W41 unique constraint)', 'medium',
                    bool_and(d.index_role = 'unique constraint'), 'unique constraint',
                    string_agg(DISTINCT d.index_role, ', '),
                    CASE WHEN NOT :'has_plans'::boolean THEN 'no plan source: no dependents' END)
  FROM index_deps.index_dependents d JOIN lab.tag_map() tm USING (queryid)
 WHERE tm.tag = 'W41';

-- One verdict per index.
CREATE FUNCTION lab.verdict(p_qualname text) RETURNS text LANGUAGE sql AS $$
    SELECT verdict FROM index_deps.index_usage WHERE format('%I.%I', schemaname, indexname) = p_qualname
$$;
\if :has_plans
SELECT lab.chk_bool('V-' || q, 'usage', 'index_usage verdict: ' || q, sev,
                    lab.verdict(q) LIKE pat, pat, lab.verdict(q))
  FROM (VALUES
    ('lab.customers_pkey', 'used by %', 'medium'),
    ('lab.customers_email_key', 'used by %', 'medium'),
    ('lab.bookings_no_overlap', 'used by %', 'medium'),
    ('lab.orders_amount_unused_idx', 'no captured query uses it: drop candidate%', 'medium'),
    ('lab.timeout_id_uq', 'no captured query uses it, but enforces uniqueness%', 'high'),
    ('lab.events_kind_unused_idx', 'no captured query uses it: drop candidate%', 'medium'),
    ('lab.events_customer_idx', 'used by %', 'high'),
    ('lab.life_renamed_idx_v2', 'unknown: plans on this table name life_renamed_idx%', 'critical'),
    ('lab_b.amb_v_idx', 'used by % (ambiguous name%', 'low')
  ) v(q, pat, sev);
\else
SELECT lab.chk_bool('V-none', 'usage', 'No plan source: every verdict is unknown', 'high',
                    bool_and(verdict LIKE 'unknown: no plan source%'), 'unknown: no plan source',
                    string_agg(DISTINCT left(verdict, 40), ' / '))
  FROM index_deps.index_usage WHERE schemaname IN ('lab', 'lab_b');
\endif

\echo '=== checks: drop impact'
\if :can_drop_impact
CREATE TABLE lab.di (
    target text, tag text, queryid bigint, calls bigint, cost_with float8, cost_without float8,
    cost_ratio numeric, uses_index_now boolean, uses_index_after boolean, plan_changed boolean,
    shape_without text, note text, query text, drop_blocker text);

CREATE FUNCTION lab.run_di(p_label text, p_index regclass, p_timeout_ms int DEFAULT 2000)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE n bigint;
BEGIN
    INSERT INTO lab.di
    SELECT p_label, tm.tag, d.queryid, d.calls, d.cost_with, d.cost_without, d.cost_ratio,
           d.uses_index_now, d.uses_index_after, d.plan_changed, d.shape_without, d.note, d.query,
           d.drop_blocker
      FROM index_deps.index_drop_impact(p_index, p_timeout_ms => p_timeout_ms, p_max_queries => 100) d
      LEFT JOIN lab.tag_map() tm ON tm.queryid = d.queryid;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END;
$$;

SELECT lab.run_di('order_items_product_idx', 'lab.order_items_product_idx'),
       lab.run_di('orders_amount_unused_idx', 'lab.orders_amount_unused_idx'),
       lab.run_di('orders_pending_created_idx', 'lab.orders_pending_created_idx'),
       lab.run_di('customers_live_created_idx', 'lab.customers_live_created_idx'),
       lab.run_di('cust', ('lab.' || :'cust_used')::regclass),
       lab.run_di('orders_pkey', 'lab.orders_pkey'),
       lab.run_di('customers_geo_gist', 'lab.customers_geo_gist');
-- The twin the planner picked for W10.
SELECT CASE WHEN EXISTS (SELECT 1 FROM lab.truth WHERE tag = 'W10' AND index_name = 'products_category_dup_idx')
            THEN 'products_category_dup_idx' ELSE 'products_category_idx' END AS twin_used,
       CASE WHEN EXISTS (SELECT 1 FROM lab.truth WHERE tag = 'W10' AND index_name = 'products_category_dup_idx')
            THEN 'products_category_idx' ELSE 'products_category_dup_idx' END AS twin_other \gset
SELECT lab.run_di('twin', ('lab.' || :'twin_used')::regclass);

-- The drop-impact row for one tag, or a placeholder whose note says it is missing.
CREATE FUNCTION lab.di_row(p_target text, p_tag text) RETURNS lab.di
LANGUAGE sql AS $$
    SELECT * FROM lab.di d WHERE d.target = p_target AND d.tag = p_tag
    UNION ALL
    SELECT p_target, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
           '(no row for ' || p_tag || ')', NULL, NULL
     WHERE NOT EXISTS (SELECT 1 FROM lab.di d WHERE d.target = p_target AND d.tag = p_tag)
    LIMIT 1
$$;

SELECT lab.chk_bool('D-only-index', 'drop_impact', 'W11 loses its only index: big cost increase reported', 'critical',
                    r.uses_index_now AND NOT r.uses_index_after AND r.cost_ratio > 5,
                    'uses_now t, uses_after f, ratio > 5',
                    format('uses_now %s, uses_after %s, ratio %s, note %s', r.uses_index_now, r.uses_index_after, r.cost_ratio, r.note))
  FROM lab.di_row('order_items_product_idx', 'W11') r;

SELECT lab.chk_bool('D-unused', 'drop_impact', 'Unused index: no query changes plan', 'high',
                    NOT EXISTS (SELECT 1 FROM lab.di WHERE target = 'orders_amount_unused_idx'
                                 AND (plan_changed OR uses_index_now)),
                    'no row with plan_changed or uses_index_now',
                    (SELECT format('%s rows, %s changed', count(*), count(*) FILTER (WHERE plan_changed OR uses_index_now))
                       FROM lab.di WHERE target = 'orders_amount_unused_idx'));

SELECT lab.chk_bool('D-partial-const', 'drop_impact', 'W15 partial index with constant: reported unknown, not unchanged', 'critical',
                    r.plan_changed IS NULL AND r.note LIKE '%cannot be matched to $n parameters%',
                    'plan_changed null, note explains partial predicate',
                    format('plan_changed %s, note %s', r.plan_changed, r.note))
  FROM lab.di_row('orders_pending_created_idx', 'W15') r;

SELECT lab.chk_bool('D-partial-noconst', 'drop_impact', 'W04 partial index without constant + typed literals: evaluated', 'high',
                    r.uses_index_now AND r.note NOT LIKE 'skipped%' AND r.note NOT LIKE '%cannot be matched%',
                    'uses_now t, evaluated',
                    format('uses_now %s, ratio %s, note %s', r.uses_index_now, r.cost_ratio, r.note))
  FROM lab.di_row('customers_live_created_idx', 'W04') r;

SELECT lab.chk_bool('D-duplicate', 'drop_impact', 'W10 duplicate pair: dropping one switches to the twin at the same cost', 'info',
                    r.cost_ratio = 1.00 AND NOT r.uses_index_after AND r.shape_without LIKE '%' || :'twin_other' || '%',
                    'ratio 1.00, plan uses ' || :'twin_other',
                    format('ratio %s, shape_without %s, note %s', r.cost_ratio, r.shape_without, r.note))
  FROM lab.di_row('twin', 'W10') r;

SELECT lab.chk_bool('D-composite', 'drop_impact', 'W12: dropping ' || :'cust_used' || ' lets ' || :'cust_other' || ' take over at a similar cost', 'info',
                    r.uses_index_now AND NOT r.uses_index_after AND r.cost_ratio < 2
                      AND r.shape_without LIKE '%' || :'cust_other' || '%',
                    'uses_now t, ratio < 2, plan uses ' || :'cust_other',
                    format('uses_now %s, ratio %s, shape_without %s, note %s', r.uses_index_now, r.cost_ratio, r.shape_without, r.note))
  FROM lab.di_row('cust', 'W12') r;

SELECT lab.chk_bool('D-prepare', 'drop_impact', 'W34 PREPARE statement is re-planned (not skipped)', 'medium',
                    r.note NOT LIKE 'skipped%',
                    'evaluated', coalesce(r.note, '(no row for W34)'))
  FROM lab.di_row('cust', 'W34') r;

SELECT lab.chk_bool('D-dml', 'drop_impact', 'W33 UPDATE is skipped by default', 'low',
                    r.note LIKE 'skipped: not a read query%',
                    'skipped: not a read query', coalesce(r.note, '(no row for W33)'))
  FROM lab.di_row('orders_pkey', 'W33') r;

SELECT lab.chk_bool('D-leading-comment', 'drop_impact', 'W36 SELECT with a leading comment is re-planned', 'medium',
                    r.note NOT LIKE 'skipped%' AND r.uses_index_now,
                    'evaluated, uses_now t', format('uses_now %s, note %s', r.uses_index_now, r.note),
                    NULL, 'ORMs and tracing tools (e.g. sqlcommenter variants) can prepend comments')
  FROM lab.di_row('orders_pkey', 'W36') r;

SELECT lab.chk_bool('D-view', 'drop_impact', 'W22 query through a view is a candidate for the view''s index', 'high',
                    r.tag IS NOT NULL,
                    'W22 row present', format('ratio %s, note %s', r.cost_ratio, r.note),
                    CASE WHEN NOT :'has_plans'::boolean
                         THEN 'no plan source: the fallback only finds queries whose text names the table' END)
  FROM lab.di_row('orders_pending_created_idx', 'W22') r;

SELECT lab.chk_bool('D-knn', 'drop_impact', 'W07 GiST KNN: generic plan uses the index', 'medium',
                    r.uses_index_now AND r.cost_ratio > 1,
                    'uses_now t, ratio > 1', format('uses_now %s, ratio %s, note %s', r.uses_index_now, r.cost_ratio, r.note))
  FROM lab.di_row('customers_geo_gist', 'W07') r;

-- A hypothetical HypoPG index identical to the target is present in the
-- session: the "without" plan uses it and the drop looks free.
SELECT * FROM hypopg_create_index('CREATE INDEX ON lab.order_items (product_id)');
SELECT lab.run_di('with_hypothetical_twin', 'lab.order_items_product_idx');
SELECT hypopg_reset();
SELECT lab.chk_bool('D-hypothetical', 'drop_impact', 'Hypothetical index in the session: real result or a warning', 'low',
                    r.cost_ratio > 5 OR r.note LIKE '%hypothetical HypoPG index%',
                    'ratio > 5 or a warning', format('ratio %s, shape_without %s, note %s', r.cost_ratio, r.shape_without, r.note))
  FROM lab.di_row('with_hypothetical_twin', 'W11') r;

-- p_timeout_ms is a time budget for the whole call (0.4+): with 1 ms only
-- the first candidates are evaluated, the rest reported as skipped.
SELECT lab.run_di('budget_1ms', 'lab.orders_amount_unused_idx', 1);
SELECT lab.chk_bool('D-timeout-param', 'drop_impact', 'p_timeout_ms budget: later queries skipped once used up', 'medium',
                    count(*) FILTER (WHERE note LIKE 'skipped: time budget used up%') > 0,
                    'some rows skipped: time budget used up',
                    format('%s rows, %s skipped by budget', count(*), count(*) FILTER (WHERE note LIKE 'skipped: time budget used up%')))
  FROM lab.di WHERE target = 'budget_1ms';

SELECT lab.chk_bool('D-blocker-pk', 'drop_impact', 'drop_blocker explains the primary key', 'medium',
                    r.drop_blocker LIKE 'enforces primary key orders_pkey%',
                    'enforces primary key orders_pkey ...', coalesce(r.drop_blocker, '(null)'))
  FROM lab.di_row('orders_pkey', 'W21') r;

-- Cancel the whole call while the index is hidden: time one full call
-- (candidates, EXPLAIN 0.2 s, hide, EXPLAIN 0.2 s), then cancel the next
-- one 0.1 s before it would end, i.e. during the second EXPLAIN.
SELECT clock_timestamp() AS t0 \gset
SELECT count(*) FROM index_deps.index_drop_impact('lab.timeout_a_idx');
SELECT greatest(50, (extract(epoch FROM clock_timestamp() - :'t0'::timestamptz) * 1000)::int - 100) AS cancel_ms \gset
\echo cancelling the next call after :cancel_ms ms
SET statement_timeout = :cancel_ms;
DO $$
BEGIN
    PERFORM * FROM index_deps.index_drop_impact('lab.timeout_a_idx');
EXCEPTION WHEN query_canceled THEN
    NULL;
END $$;
RESET statement_timeout;
SELECT lab.chk_bool('D-cancel-unhide', 'drop_impact', 'Index unhidden after the call is cancelled (statement_timeout)', 'critical',
                    count(*) = 0, '0 hidden', count(*) || ' hidden',
                    NULL, 'a hidden index stays hidden for the rest of the session: real queries on that connection stop using it')
  FROM hypopg_hidden_indexes();
SELECT hypopg_unhide_all_indexes();

-- Read-only transaction, as on an Aurora reader or hot standby.
BEGIN READ ONLY;
DO $$
DECLARE m text;
BEGIN
    BEGIN
        PERFORM * FROM index_deps.index_drop_impact('lab.order_items_product_idx');
        m := 'no error';
    EXCEPTION WHEN OTHERS THEN
        m := 'error: ' || SQLERRM;
    END;
    PERFORM set_config('lab.ro_result', m, false);
END $$;
COMMIT;
SELECT lab.chk_bool('D-read-only', 'drop_impact', 'Works in a read-only transaction (reader / standby)', 'high',
                    current_setting('lab.ro_result') = 'no error', 'no error', current_setting('lab.ro_result'));

-- Error paths: each must fail with a clear message (rolled back afterwards).
CREATE FUNCTION lab.try(p_sql text, p_setup text DEFAULT NULL) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE m text;
BEGIN
    BEGIN
        IF p_setup IS NOT NULL THEN EXECUTE p_setup; END IF;
        EXECUTE p_sql;
        m := 'no error';
        RAISE EXCEPTION 'lab_rollback';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'lab_rollback' THEN m := 'error: ' || SQLERRM; END IF;
    END;
    RETURN m;
END;
$$;

SELECT lab.chk_bool('E-not-index', 'errors', 'drop_impact on a table: clear error', 'low',
                    m LIKE 'error:%is not an index%', 'error: ... is not an index', m)
  FROM lab.try($$SELECT * FROM index_deps.index_drop_impact('lab.orders')$$) m;
SELECT lab.chk_bool('E-missing', 'errors', 'drop_impact on a missing index: clear error', 'low',
                    m LIKE 'error:%does not exist%', 'error: ... does not exist', m)
  FROM lab.try($$SELECT * FROM index_deps.index_drop_impact('lab.no_such_idx')$$) m;
SELECT lab.chk_bool('E-no-hypopg', 'errors', 'drop_impact without HypoPG: clear error', 'low',
                    m LIKE 'error:%HypoPG%', 'error: HypoPG ... is required', m)
  FROM lab.try($$SELECT * FROM index_deps.index_drop_impact('lab.orders_customer_idx')$$, 'DROP EXTENSION hypopg') m;
SELECT lab.chk_bool('E-no-pgss-di', 'errors', 'drop_impact without pg_stat_statements: clear error', 'low',
                    m LIKE 'error:%pg_stat_statements%', 'error: pg_stat_statements is required', m)
  FROM lab.try($$SELECT * FROM index_deps.index_drop_impact('lab.orders_customer_idx')$$, 'DROP EXTENSION pg_stat_statements') m;
SELECT lab.chk_bool('E-no-pgss-qs', 'errors', 'index_query_stats without pg_stat_statements: clear error', 'low',
                    m LIKE 'error:%needs pg_stat_statements%', 'error: index_query_stats needs pg_stat_statements', m)
  FROM lab.try($$SELECT count(*) FROM index_deps.index_query_stats$$, 'DROP EXTENSION pg_stat_statements') m;
SELECT lab.chk_bool('E-bad-source', 'errors', 'plan_source set to a missing table: clear error', 'low',
                    m LIKE 'error:%does not exist%', 'error: relation ... does not exist', m)
  FROM lab.try($$SELECT count(*) FROM index_deps.index_dependents$$,
               $$UPDATE index_deps.config SET value = 'lab.no_such_table' WHERE key = 'plan_source'$$) m;

-- Unprivileged role (no pg_read_all_stats): must not error.
SELECT lab.chk_bool('E-unprivileged', 'errors', 'Role without pg_read_all_stats can query the views and drop_impact', 'high',
                    m = 'no error', 'no error', m)
  FROM lab.try($$SELECT count(*) FROM index_deps.index_dependents, (SELECT count(*) FROM index_deps.index_no_dependents) a,
                        (SELECT count(*) FROM index_deps.index_drop_impact('lab.order_items_product_idx')) b$$,
               $$CREATE ROLE lab_analyst NOLOGIN;
                 GRANT USAGE ON SCHEMA lab TO lab_analyst;
                 GRANT SELECT ON ALL TABLES IN SCHEMA lab TO lab_analyst;
                 SET LOCAL ROLE lab_analyst$$) m;

SELECT lab.chk_bool('D-none-hidden', 'drop_impact', 'No index left hidden at the end', 'critical',
                    count(*) = 0, '0', count(*)::text)
  FROM hypopg_hidden_indexes();
\else
SELECT lab.note('D-skipped', 'drop_impact', 'Drop-impact checks', 'SKIP', 'needs PostgreSQL 16+ and HypoPG 1.4+');
\endif

\o
SELECT status, count(*) FROM lab.results GROUP BY status ORDER BY status;
