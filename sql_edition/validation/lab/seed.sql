-- Index lab: synthetic schema, data and indexes. Included by lab.sql.
-- Everything lives in schemas lab and lab_b of the dedicated database
-- index_lab (created by run.sh). Synthetic data only, deterministic (setseed).

\echo '=== seed: schemas and helper tables'
DROP SCHEMA IF EXISTS lab CASCADE;
DROP SCHEMA IF EXISTS lab_b CASCADE;
CREATE SCHEMA lab;
CREATE SCHEMA lab_b;

-- Result of every check; read by report.sql.
CREATE TABLE lab.results (
    ord      serial PRIMARY KEY,
    case_id  text NOT NULL,
    area     text NOT NULL,
    title    text NOT NULL,
    severity text NOT NULL,          -- critical | high | medium | low | info
    status   text NOT NULL,          -- PASS | FAIL | KNOWN | SKIP | INFO
    expected text,
    actual   text,
    detail   text
);

-- Environment facts for the report.
CREATE TABLE lab.env (k text PRIMARY KEY, v text);

-- Workload cases. match: exact = the tool must name exactly the indexes
-- EXPLAIN shows; subset = every index it names must be in EXPLAIN's set
-- (used where the executed plan can differ from EXPLAIN, e.g. a prepared
-- statement switching to a generic plan). known_gap: documented limitation;
-- a mismatch is reported KNOWN, a match PASS.
CREATE TABLE lab.cases (
    tag       text PRIMARY KEY,
    area      text NOT NULL,
    title     text NOT NULL,
    match     text NOT NULL DEFAULT 'exact',
    known_gap text
);

-- One row per statement to run. kind: sql (run top level), prepare, exec,
-- truth (EXPLAIN only: the statement runs inside a function, see W35),
-- other_db (runs in index_lab2, no truth).
CREATE TABLE lab.workload (
    ord  serial PRIMARY KEY,
    tag  text NOT NULL REFERENCES lab.cases,
    kind text NOT NULL DEFAULT 'sql',
    stmt text NOT NULL
);

-- Ground truth: indexes in the EXPLAIN plan of each workload statement,
-- captured right after the workload ran.
CREATE TABLE lab.truth (
    tag        text NOT NULL,
    indexrelid oid,
    index_name text NOT NULL,
    qualname   text
);

-- Expected-unused exceptions for the per-index check.
CREATE TABLE lab.known_index_gaps (qualname text PRIMARY KEY, gap text NOT NULL);

CREATE FUNCTION lab.chk(p_case text, p_area text, p_title text, p_severity text,
                        p_expected text, p_actual text,
                        p_known text DEFAULT NULL, p_detail text DEFAULT NULL)
RETURNS void LANGUAGE sql AS $$
    INSERT INTO lab.results (case_id, area, title, severity, status, expected, actual, detail)
    VALUES (p_case, p_area, p_title, p_severity,
            CASE WHEN p_expected IS NOT DISTINCT FROM p_actual THEN 'PASS'
                 WHEN p_known IS NOT NULL THEN 'KNOWN'
                 ELSE 'FAIL' END,
            p_expected, p_actual,
            CASE WHEN p_expected IS NOT DISTINCT FROM p_actual THEN p_detail
                 ELSE concat_ws(' | ', p_known, p_detail) END);
$$;

CREATE FUNCTION lab.note(p_case text, p_area text, p_title text, p_status text, p_detail text)
RETURNS void LANGUAGE sql AS $$
    INSERT INTO lab.results (case_id, area, title, severity, status, detail)
    VALUES (p_case, p_area, p_title, 'info', p_status, p_detail);
$$;

-- queryid -> workload tag, from the comment each workload statement carries.
-- Dynamic SQL so nothing depends on pg_stat_statements (a check drops it).
CREATE FUNCTION lab.tag_map()
RETURNS TABLE (queryid bigint, tag text, calls bigint, query text)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN QUERY EXECUTE $q$
        SELECT s.queryid, substring(s.query from '/\* lab:([A-Z0-9]+) \*/'),
               sum(s.calls)::bigint, max(s.query)
          FROM pg_stat_statements s
         WHERE s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
           AND s.query ~ '/\* lab:[A-Z0-9]+ \*/'
           AND s.query !~* '^\s*explain'
         GROUP BY 1, 2 $q$;
END;
$$;

-- Indexes named in an EXPLAIN JSON plan.
CREATE FUNCTION lab.plan_indexes(j json)
RETURNS SETOF text LANGUAGE sql IMMUTABLE AS $$
    SELECT DISTINCT v #>> '{}'
      FROM jsonb_path_query(j::jsonb, 'strict $.**."Index Name"') AS v
$$;

-- Markdown table from a query (column order kept: json, not jsonb).
CREATE FUNCTION lab.md(q text)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
    j   json;
    out text;
    r   json;
BEGIN
    EXECUTE 'SELECT json_agg(t) FROM (' || q || ') t' INTO j;
    IF j IS NULL THEN
        RETURN '_(no rows)_' || E'\n';
    END IF;
    SELECT '| ' || string_agg(k, ' | ') || ' |' || E'\n' ||
           '|' || string_agg('---', '|') || '|'
      INTO out FROM json_object_keys(j -> 0) AS k;
    FOR r IN SELECT * FROM json_array_elements(j) LOOP
        out := out || E'\n| ' ||
               (SELECT string_agg(replace(replace(coalesce(e.value, ''), '|', '\|'), E'\n', ' '), ' | ')
                  FROM json_each_text(r) AS e) || ' |';
    END LOOP;
    RETURN out || E'\n';
END;
$$;

\echo '=== seed: tables and data (scale' :scale ')'
SELECT setseed(0.42);

CREATE TABLE lab.customers (
    id         int PRIMARY KEY,
    email      text NOT NULL CONSTRAINT customers_email_key UNIQUE,
    country    text NOT NULL,
    created_at timestamptz NOT NULL,
    deleted_at timestamptz,
    geo        point NOT NULL,
    profile    jsonb NOT NULL
);
INSERT INTO lab.customers
SELECT g,
       'user' || g || '@example.com',
       CASE WHEN g % 2000 = 0 THEN 'ZZ'
            ELSE (ARRAY['US','IN','DE','FR','GB','BR','JP','CA','AU','ES','IT','NL','SE','PL','MX',
                        'KR','SG','ZA','AR','CH','AT','BE','DK','FI','NO','IE','PT','NZ','CL'])[1 + g % 29] END,
       timestamptz '2025-01-01' + (g::float8 / n) * interval '650 days',
       CASE WHEN g % 10 = 0 THEN timestamptz '2025-01-01' + (g::float8 / n) * interval '650 days' + interval '30 days' END,
       point(random() * 1000, random() * 1000),
       jsonb_build_object('tier', CASE WHEN g % 100 = 0 THEN 'gold' WHEN g % 10 = 0 THEN 'silver' ELSE 'basic' END,
                          'newsletter', g % 3 = 0)
  FROM (SELECT (200000 * :scale)::int AS n) s, generate_series(1, s.n) g;

CREATE TABLE lab.products (
    id       int PRIMARY KEY,
    sku      text NOT NULL,
    name     text NOT NULL,
    category int NOT NULL,
    price    numeric(10,2) NOT NULL
);
INSERT INTO lab.products
SELECT g, 'SKU-' || g,
       (ARRAY['alpha','bravo','charlie','delta','echo','foxtrot'])[1 + g % 6] || '-widget-' || g,
       g % 200, round((random() * 200)::numeric, 2)
  FROM generate_series(1, 20000) g;

CREATE TABLE lab.orders (
    id          bigint PRIMARY KEY,
    customer_id int NOT NULL,
    status      text NOT NULL,
    region      int NOT NULL,
    amount      numeric(10,2) NOT NULL,
    created_at  timestamptz NOT NULL
);
INSERT INTO lab.orders
SELECT g,
       1 + (random() * (s.nc - 1))::int,
       CASE WHEN r < 0.005 THEN 'refund' WHEN r < 0.05 THEN 'pending' ELSE 'shipped' END,
       1 + g % 50,
       round((random() * 500)::numeric, 2),
       timestamptz '2025-01-01' + (g::float8 / s.n) * interval '650 days'
  FROM (SELECT (1000000 * :scale)::int AS n, (200000 * :scale)::int AS nc) s,
       generate_series(1, s.n) g,
       LATERAL (SELECT random() + g * 0 AS r) x;
ALTER TABLE lab.orders ADD CONSTRAINT orders_customer_fk FOREIGN KEY (customer_id) REFERENCES lab.customers;

CREATE TABLE lab.order_items (
    order_id   bigint NOT NULL,
    line       int NOT NULL,
    product_id int NOT NULL,
    qty        int NOT NULL,
    PRIMARY KEY (order_id, line)
);
INSERT INTO lab.order_items
SELECT 1 + (g - 1) / 2, 1 + (g - 1) % 2, 1 + (random() * 19999)::int, 1 + (random() * 4)::int
  FROM (SELECT (2000000 * :scale)::int AS n) s, generate_series(1, s.n) g;

CREATE TABLE lab.events (
    id          bigint NOT NULL,
    customer_id int NOT NULL,
    kind        text NOT NULL,
    created_at  timestamptz NOT NULL,
    payload     text
) PARTITION BY RANGE (created_at);
SELECT format('CREATE TABLE lab.events_2026_%s PARTITION OF lab.events FOR VALUES FROM (%L) TO (%L)',
              lpad(m::text, 2, '0'),
              make_date(2026, m, 1), make_date(2026, m, 1) + interval '1 month')
  FROM generate_series(1, 12) m \gexec
INSERT INTO lab.events
SELECT g, 1 + (random() * (s.nc - 1))::int, (ARRAY['view','click','buy'])[1 + g % 3],
       timestamptz '2026-01-01' + random() * interval '364 days', 'p' || g
  FROM (SELECT (600000 * :scale)::int AS n, (200000 * :scale)::int AS nc) s, generate_series(1, s.n) g;

CREATE TABLE lab."Mixed Case Tbl" (id int PRIMARY KEY, "Val" int, w int, u int, l int);
INSERT INTO lab."Mixed Case Tbl" SELECT g, g % 5000, g % 5000, g % 5000, g % 5000 FROM generate_series(1, 50000) g;

CREATE TABLE lab.amb (id int PRIMARY KEY, v int);
CREATE TABLE lab_b.amb (id int PRIMARY KEY, v int);
INSERT INTO lab.amb SELECT g, g % 5000 FROM generate_series(1, 50000) g;
INSERT INTO lab_b.amb SELECT g, g % 5000 FROM generate_series(1, 50000) g;

CREATE TABLE lab.dbx (id int PRIMARY KEY, v int);
INSERT INTO lab.dbx SELECT g, g % 2000 FROM generate_series(1, 20000) g;

CREATE TABLE lab.life (id int PRIMARY KEY, a int, b int, c int);
INSERT INTO lab.life SELECT g, g % 5000, g % 5000, g % 100 FROM generate_series(1, 50000) g;

CREATE TABLE lab.reader_only (id int PRIMARY KEY, v int);
INSERT INTO lab.reader_only SELECT g, g % 2000 FROM generate_series(1, 20000) g;

CREATE TABLE lab.bookings (id int PRIMARY KEY, room int NOT NULL, during tstzrange NOT NULL,
                           CONSTRAINT bookings_no_overlap EXCLUDE USING gist (during WITH &&));
INSERT INTO lab.bookings
SELECT g, g % 50, tstzrange(timestamptz '2026-01-01' + g * interval '2 hours',
                            timestamptz '2026-01-01' + g * interval '2 hours' + interval '1 hour')
  FROM generate_series(1, 20000) g;

CREATE TABLE lab.timeout_t (id int PRIMARY KEY, a int);
INSERT INTO lab.timeout_t SELECT g, g % 2000 FROM generate_series(1, 20000) g;

-- Folded at plan time (immutable, no arguments), so planning any query
-- that calls it takes 0.2 s. Used to make the timeout cases deterministic.
CREATE FUNCTION lab.slow_plan() RETURNS int LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    PERFORM pg_sleep(0.2);
    RETURN 1;
END;
$$;

-- Query inside a function: nested statement (toplevel = false).
CREATE FUNCTION lab.f_customer_refunds(p int) RETURNS bigint LANGUAGE plpgsql STABLE AS $$
DECLARE n bigint;
BEGIN
    SELECT count(*) INTO n FROM lab.orders WHERE customer_id = p AND status = 'refund' /* lab:W35 */;
    RETURN n;
END;
$$;

CREATE VIEW lab.v_pending AS
    SELECT id, customer_id, amount, created_at FROM lab.orders WHERE status = 'pending';

\echo '=== seed: indexes'
CREATE INDEX customers_email_lower_idx ON lab.customers (lower(email));
CREATE INDEX customers_country_idx ON lab.customers (country);
CREATE INDEX customers_live_created_idx ON lab.customers (created_at) WHERE deleted_at IS NULL;
CREATE INDEX customers_profile_gin ON lab.customers USING gin (profile jsonb_path_ops);
CREATE INDEX customers_created_brin ON lab.customers USING brin (created_at);
CREATE INDEX customers_geo_gist ON lab.customers USING gist (geo);

CREATE INDEX products_sku_hash ON lab.products USING hash (sku);
CREATE INDEX products_name_trgm ON lab.products USING gin (name gin_trgm_ops);
CREATE INDEX products_category_idx ON lab.products (category);
CREATE INDEX products_category_dup_idx ON lab.products (category);

CREATE INDEX orders_customer_idx ON lab.orders (customer_id);
CREATE INDEX orders_customer_created_idx ON lab.orders (customer_id, created_at);
CREATE INDEX orders_status_idx ON lab.orders (status);
CREATE INDEX orders_pending_created_idx ON lab.orders (created_at) WHERE status = 'pending';
CREATE INDEX orders_created_idx ON lab.orders (created_at);
CREATE INDEX orders_region_cover_idx ON lab.orders (region) INCLUDE (amount);
CREATE INDEX orders_amount_unused_idx ON lab.orders (amount);

CREATE INDEX order_items_product_idx ON lab.order_items (product_id);

CREATE INDEX events_customer_idx ON lab.events (customer_id);
CREATE INDEX events_kind_unused_idx ON lab.events (kind);

CREATE INDEX "Mixed Case Idx" ON lab."Mixed Case Tbl" ("Val");
CREATE INDEX "idx with spaces" ON lab."Mixed Case Tbl" (w);
CREATE INDEX "índice_ñ" ON lab."Mixed Case Tbl" (u);
-- 70 characters: Postgres truncates it to 63 bytes (NOTICE).
CREATE INDEX lab_this_index_name_is_deliberately_longer_than_sixty_three_bytes_idx ON lab."Mixed Case Tbl" (l);

CREATE INDEX amb_v_idx ON lab.amb (v);
CREATE INDEX amb_v_idx ON lab_b.amb (v);
CREATE INDEX dbx_v_idx ON lab.dbx (v);
CREATE INDEX life_renamed_idx ON lab.life (a);
CREATE INDEX life_recreated_idx ON lab.life (b);
CREATE INDEX reader_only_idx ON lab.reader_only (v);
CREATE INDEX timeout_a_idx ON lab.timeout_t (a);
-- Unique index (no constraint) used as replica identity; clustered index.
CREATE UNIQUE INDEX timeout_id_uq ON lab.timeout_t (id);
ALTER TABLE lab.timeout_t REPLICA IDENTITY USING INDEX timeout_id_uq;
ALTER TABLE lab.life CLUSTER ON life_pkey;

-- An invalid index, as left behind by a failed CREATE INDEX CONCURRENTLY.
\echo 'expected error next (division by zero) leaves life_invalid_idx invalid:'
\set ON_ERROR_STOP off
CREATE INDEX CONCURRENTLY life_invalid_idx ON lab.life ((100 / (c - 50)));
\set ON_ERROR_STOP on

\echo '=== seed: vacuum analyze'
VACUUM ANALYZE lab.customers, lab.products, lab.orders, lab.order_items, lab.events,
               lab."Mixed Case Tbl", lab.amb, lab_b.amb, lab.dbx, lab.life,
               lab.reader_only, lab.timeout_t, lab.bookings;

SELECT count(*) AS lab_indexes,
       pg_size_pretty(sum(pg_relation_size(c.oid))) AS index_size
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname IN ('lab', 'lab_b') AND c.relkind IN ('i', 'I');
