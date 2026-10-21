-- 20-index orders table for the wide-schema benchmark (synthetic data).
CREATE TABLE orders (id bigint PRIMARY KEY, tenant_id int, customer_id int, status int,
  created_at timestamptz, updated_at timestamptz, total numeric, currency int, region int,
  channel int, priority int, warehouse int, carrier int, coupon int, rep int, source int,
  segment int, score int, flags int, ref text);
INSERT INTO orders SELECT g, g % 500, g % 50000, g % 7, now() - (g || ' s')::interval, now(),
  g % 1000, g % 5, g % 20, g % 4, g % 3, g % 30, g % 12, g % 100, g % 300, g % 9, g % 6,
  g % 1000, g % 64, md5(g::text) FROM generate_series(1, 1000000) g;
CREATE INDEX ON orders (tenant_id); CREATE INDEX ON orders (customer_id); CREATE INDEX ON orders (status);
CREATE INDEX ON orders (created_at); CREATE INDEX ON orders (updated_at); CREATE INDEX ON orders (currency);
CREATE INDEX ON orders (region); CREATE INDEX ON orders (channel); CREATE INDEX ON orders (priority);
CREATE INDEX ON orders (warehouse); CREATE INDEX ON orders (carrier); CREATE INDEX ON orders (coupon);
CREATE INDEX ON orders (rep); CREATE INDEX ON orders (source); CREATE INDEX ON orders (segment);
CREATE INDEX ON orders (score); CREATE INDEX ON orders (flags); CREATE INDEX ON orders (ref);
CREATE INDEX ON orders (tenant_id, created_at);
VACUUM ANALYZE orders;
