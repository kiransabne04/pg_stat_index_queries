# Security

## Reporting a vulnerability

Use GitHub's private reporting: the **Security** tab of this repository, then **Report a vulnerability**. Don't open a public issue. You'll get a reply within 5 business days.

Supported: the latest release (currently 0.10 / SQL edition 0.7).

## What the code does and doesn't do

- The native extension reads executor state and writes only to its own shared memory and to two files: `pg_stat/pg_stat_index_queries.stat` (clean shutdown) and `pg_stat_tmp/pg_stat_index_queries.snap` (periodic snapshot). It starts one background worker (`pg_stat_index_queries saver`) that only writes the snapshot.
- It stores no query text: only OIDs, query IDs, counts, timestamps and column numbers. Query text comes from pg_stat_statements, under its own permissions.
- `pg_stat_index_queries_reset()` is revoked from PUBLIC. The views are readable by PUBLIC; revoke them if index usage is sensitive in your environment.
- Nothing in either extension writes to user tables, drops indexes or executes user queries. `index_drop_impact()` runs EXPLAIN only; it hides an index for the calling session only and always unhides it, including on errors and cancellation.
