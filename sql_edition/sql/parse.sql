-- Parsing index references out of plan text (fixture source).
CREATE EXTENSION pg_index_deps;

CREATE TABLE o (id int PRIMARY KEY, c int, s int);
CREATE INDEX o_c_idx ON o (c);
CREATE INDEX o_s_idx ON o (s);
CREATE INDEX o_unused_idx ON o (s, c);
CREATE TABLE "Odd Table" (id int);
CREATE INDEX "Odd Idx" ON "Odd Table" (id);
-- Same index name in another schema, on a table also called o: ambiguous.
CREATE SCHEMA s2;
CREATE TABLE s2.o (c int);
CREATE INDEX o_c_idx ON s2.o (c);

CREATE TABLE fixture_plans (queryid bigint, planid bigint, calls bigint, plan_text text);
INSERT INTO fixture_plans VALUES
 (1, 11, 100, E'Index Scan using o_pkey on o\n  Index Cond: (id = $1)'),
 (2, 21, 40,  E'Aggregate\n  ->  Bitmap Heap Scan on o\n        Recheck Cond: ((c = 5) OR (s = 3))\n        ->  BitmapOr\n              ->  Bitmap Index Scan on o_c_idx\n                    Index Cond: (c = 5)\n              ->  Bitmap Index Scan on o_s_idx\n                    Index Cond: (s = 3)'),
 (3, 31, 7,   E'Index Only Scan Backward using o_pkey on o o1\n  Index Cond: (id < 10)'),
 (4, 41, 3,   E'Index Scan using "Odd Idx" on "Odd Table"\n  Index Cond: (id = 1)'),
 (5, 51, 9,   E'Seq Scan on o\n  Filter: (s = 2)'),
 (1, 12, 5,   E'Seq Scan on o\n  Filter: (id = 1)');

UPDATE index_deps.config SET value = 'public.fixture_plans' WHERE key = 'plan_source';

SELECT queryid, planid, calls, scan_type, index_name, table_name
  FROM index_deps.plan_index_usage
 ORDER BY queryid, planid, index_name;

SELECT schemaname, tablename, indexname, queryid, plans, calls, scan_types, ambiguous
  FROM index_deps.index_dependents
 ORDER BY indexname, schemaname, queryid;

SELECT indexname
  FROM index_deps.index_no_dependents
 WHERE schemaname = 'public'
 ORDER BY indexname;

-- Partitioned table: plans name the partition indexes. The parent index
-- counts as referenced; attached partition indexes aren't listed.
CREATE TABLE pt (id int, k int, v int) PARTITION BY RANGE (id);
CREATE TABLE pt_1 PARTITION OF pt FOR VALUES FROM (0) TO (100);
CREATE TABLE pt_2 PARTITION OF pt FOR VALUES FROM (100) TO (200);
CREATE INDEX pt_k_idx ON pt (k);
CREATE INDEX pt_v_idx ON pt (v);
INSERT INTO fixture_plans VALUES
 (6, 61, 4, E'Append\n  ->  Index Scan using pt_1_k_idx on pt_1\n        Index Cond: (k = 1)\n  ->  Index Scan using pt_2_k_idx on pt_2\n        Index Cond: (k = 1)');
SELECT tablename, indexname
  FROM index_deps.index_no_dependents
 WHERE tablename LIKE 'pt%'
 ORDER BY indexname;

-- 'none' returns nothing and doesn't error
UPDATE index_deps.config SET value = 'none' WHERE key = 'plan_source';
SELECT count(*) AS rows_with_none FROM index_deps.plan_index_usage;
-- With no plan source nothing is known, so no index is reported as unused.
SELECT count(*) AS no_dependents_with_none FROM index_deps.index_no_dependents;
UPDATE index_deps.config SET value = 'auto' WHERE key = 'plan_source';
SELECT index_deps.resolved_plan_source();

-- Real plan text from Aurora PostgreSQL 17.9 (aurora_stat_plans, index lab
-- run 24 Oct 2026, synthetic schema), exactly as Aurora printed it.
CREATE TABLE aurora_fixture (queryid bigint, planid bigint, calls bigint, tag text, plan_text text);
INSERT INTO aurora_fixture VALUES
 (901, 1, 20, 'W01', $aur$Index Scan using customers_pkey on customers  (cost=0.42..8.44 rows=1 width=22)
  Index Cond: (id = 7920)$aur$),
 (902, 2, 10, 'W07', $aur$Limit  (cost=0.28..0.85 rows=5 width=12)
  ->  Index Scan using customers_geo_gist on customers  (cost=0.28..22824.28 rows=200000 width=12)
        Order By: (geo <-> '(97,53)'::point)$aur$),
 (903, 3, 10, 'W11', $aur$Aggregate  (cost=376.50..376.51 rows=1 width=8)
  ->  Bitmap Heap Scan on order_items  (cost=5.19..376.25 rows=99 width=4)
        Recheck Cond: (product_id = 102)
        ->  Bitmap Index Scan on order_items_product_idx  (cost=0.00..5.17 rows=99 width=0)
              Index Cond: (product_id = 102)$aur$),
 (904, 4, 10, 'W17', $aur$Aggregate  (cost=706.43..706.44 rows=1 width=32)
  ->  Index Only Scan using orders_region_cover_idx on orders  (cost=0.42..656.67 rows=19900 width=6)
        Index Cond: (region = 1)$aur$),
 (905, 5, 5, 'W19', $aur$Aggregate  (cost=7702.21..7702.22 rows=1 width=8)
  ->  Bitmap Heap Scan on orders  (cost=64.90..7689.70 rows=5006 width=0)
        Recheck Cond: ((customer_id = 504) OR (status = 'refund'::text))
        ->  BitmapOr  (cost=64.90..64.90 rows=5006 width=0)
              ->  Bitmap Index Scan on orders_customer_created_idx  (cost=0.00..4.47 rows=6 width=0)
                    Index Cond: (customer_id = 504)
              ->  Bitmap Index Scan on orders_status_idx  (cost=0.00..57.92 rows=5000 width=0)
                    Index Cond: (status = 'refund'::text)$aur$),
 (906, 6, 10, 'W23', $aur$Aggregate  (cost=8.31..8.32 rows=1 width=8)
  ->  Index Scan using events_2026_03_customer_id_idx on events_2026_03 events  (cost=0.29..8.31 rows=1 width=0)
        Index Cond: (customer_id = 602)
        Filter: ((created_at >= '2026-03-01 00:00:00+00'::timestamp with time zone) AND (created_at < '2026-04-01 00:00:00+00'::timestamp with time zone))$aur$),
 (907, 7, 10, 'W24', $aur$Aggregate  (cost=51.78..51.79 rows=1 width=8)
  ->  Append  (cost=0.29..51.75 rows=12 width=0)
        ->  Index Only Scan using events_2026_01_customer_id_idx on events_2026_01 events_1  (cost=0.29..4.31 rows=1 width=0)
              Index Cond: (customer_id = 702)
        ->  Index Only Scan using events_2026_02_customer_id_idx on events_2026_02 events_2  (cost=0.29..4.31 rows=1 width=0)
              Index Cond: (customer_id = 702)
        ->  Index Only Scan using events_2026_03_customer_id_idx on events_2026_03 events_3  (cost=0.29..4.31 rows=1 width=0)
              Index Cond: (customer_id = 702)
        ->  Index Only Scan using events_2026_04_customer_id_idx on events_2026_04 events_4  (cost=0.29..4.31 rows=1 width=0)
              Index Cond: (customer_id = 702)
        ->  Index Only Scan using events_2026_05_customer_id_idx on events_2026_05 events_5  (cost=0.29..4.31 rows=1 width=0)
              Index Cond: (customer_id = 702)
        ->  Index Only Scan using events_2026_06_customer_id_idx on events_2026_06 events_6  (cost=0.29..4.31 rows=1 width=0)
              Index Cond: (customer_id = 702)
        ->  Index Only Scan using events_2026_07_customer_id_idx on events_2026_07 events_7  (cost=0.29..4.31 rows=1 width=0)
              Index Cond: (customer_id = 702)
        ->  Index Only Scan using events_2026_08_customer_id_idx on events_2026_08 events_8  (cost=0.29..4.31 rows=1 width=0)
              Index Cond: (customer_id = 702)
        ->  Index Only Scan using events_2026_09_customer_id_idx on events_2026_09 events_9  (cost=0.29..4.31 rows=1 width=0)
              Index Cond: (customer_id = 702)
        ->  Index Only Scan using events_2026_10_customer_id_idx on events_2026_10 events_10  (cost=0.29..4.31 rows=1 width=0)
              Index Cond: (customer_id = 702)
        ->  Index Only Scan using events_2026_11_customer_id_idx on events_2026_11 events_11  (cost=0.29..4.31 rows=1 width=0)
              Index Cond: (customer_id = 702)
        ->  Index Only Scan using events_2026_12_customer_id_idx on events_2026_12 events_12  (cost=0.29..4.31 rows=1 width=0)
              Index Cond: (customer_id = 702)$aur$),
 (908, 8, 5, 'W25', $aur$Aggregate  (cost=4.49..4.50 rows=1 width=8)
  ->  Index Only Scan using "Mixed Case Idx" on "Mixed Case Tbl"  (cost=0.29..4.46 rows=10 width=0)
        Index Cond: ("Val" = 1)$aur$),
 (909, 9, 5, 'W26', $aur$Aggregate  (cost=4.49..4.50 rows=1 width=8)
  ->  Index Only Scan using "idx with spaces" on "Mixed Case Tbl"  (cost=0.29..4.46 rows=10 width=0)
        Index Cond: (w = 1)$aur$),
 (910, 10, 5, 'W27', $aur$Aggregate  (cost=4.49..4.50 rows=1 width=8)
  ->  Index Only Scan using "índice_ñ" on "Mixed Case Tbl"  (cost=0.29..4.46 rows=10 width=0)
        Index Cond: (u = 1)$aur$),
 (911, 11, 5, 'W28', $aur$Aggregate  (cost=4.49..4.50 rows=1 width=8)
  ->  Index Only Scan using lab_this_index_name_is_deliberately_longer_than_sixty_three_byt on "Mixed Case Tbl"  (cost=0.29..4.46 rows=10 width=0)
        Index Cond: (l = 1)$aur$),
 (912, 12, 10, 'W41', $aur$Index Scan using customers_email_key on customers  (cost=0.42..8.44 rows=1 width=4)
  Index Cond: (email = 'user53@example.com'::text)$aur$),
 (913, 13, 5, 'W42', $aur$Aggregate  (cost=4.31..4.32 rows=1 width=8)
  ->  Index Only Scan using bookings_no_overlap on bookings  (cost=0.28..4.31 rows=2 width=0)
        Index Cond: (during && '["2026-02-02 00:00:00+00","2026-02-02 03:00:00+00")'::tstzrange)$aur$);
UPDATE index_deps.config SET value = 'public.aurora_fixture' WHERE key = 'plan_source';
SELECT f.tag, u.scan_type, u.index_name, u.table_name
  FROM index_deps.plan_index_usage u JOIN aurora_fixture f USING (queryid)
 ORDER BY f.tag, u.index_name, u.scan_type;
UPDATE index_deps.config SET value = 'auto' WHERE key = 'plan_source';
