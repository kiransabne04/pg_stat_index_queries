\set c random(1, 50000)
\set t random(0, 499)
\set i random(1, 1000000)
SELECT id, total FROM orders WHERE customer_id = :c;
SELECT count(*) FROM orders WHERE tenant_id = :t AND created_at > now() - interval '1 hour';
SELECT * FROM orders WHERE id = :i;
