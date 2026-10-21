# Security

- The native extension reads executor state and writes only to its own shared memory and `pg_stat/pg_stat_index_queries.stat`.
- `pg_stat_index_queries_reset()` is revoked from PUBLIC. Views are readable by PUBLIC but expose only OIDs, query IDs and counts (no query text).
- `index_drop_impact()` runs EXPLAIN only. It hides indexes for the calling session only and always unhides them.
- Report vulnerabilities privately to the maintainer (contact in the repository profile), not in public issues.
