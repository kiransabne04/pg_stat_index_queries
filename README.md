# pg_stat_index_queries

**Which queries use this index?** Postgres tells you how many times an index was scanned (`pg_stat_user_indexes.idx_scan`) and, since PG 16, when it was last used. It doesn't tell you *which queries* depend on it. This extension does.

```sql
SELECT indexname, queryid, calls_executed, last_seen
  FROM pg_index_dependents
 WHERE indexname = 'orders_customer_id_idx';
```

Use it before you drop, rebuild or replace an index, during upgrades, and when cleaning up overlapping indexes.

> **Status: 0.1, experimental.** Don't run it in production yet.

## How it works

At the end of each statement, the extension walks the executed plan tree and records every index used by Index Scan, Index Only Scan and Bitmap Index Scan nodes. Counters live in shared memory, keyed by `(database, index, queryid, toplevel)`, the same way pg_stat_statements works.

- `calls_planned`: statements whose plan included the index.
- `calls_executed`: statements where the index scan actually ran. An index can be in a plan but never touched, for example under a false one-time filter or an empty outer side of a join.
- Query text isn't stored. Join to `pg_stat_statements` on `(dbid, queryid)`.

## Install

Requires PostgreSQL 15–18 and the server headers (`postgresql-server-dev-NN`).

```bash
make && sudo make install
```

`postgresql.conf`:

```
shared_preload_libraries = 'pg_stat_index_queries'   # restart required
compute_query_id = on        # or 'auto' (the extension enables it)
```

```sql
CREATE EXTENSION pg_stat_index_queries;
```

Install it on **every replica** too. Each server only sees its own queries, and replicas often depend on indexes the primary never uses.

## Views and functions

| Object | What it gives you |
|---|---|
| `pg_stat_index_queries` | Raw counters: dbid, indexrelid, queryid, toplevel, calls_executed, calls_planned, first_seen, last_seen |
| `pg_index_dependents` | Same, with schema, table and index names, for the current database |
| `pg_index_no_dependents` | User indexes with no executed use since `tracked_since` (excludes PK, unique and constraint indexes) |
| `pg_stat_index_queries_info` | Entries tracked, evictions (`dealloc`), `stats_reset` time |
| `pg_stat_index_queries_reset()` | Clear all counters (superuser by default) |

With query text:

```sql
SELECT d.indexname, d.calls_executed, left(s.query, 80) AS query
  FROM pg_index_dependents d
  LEFT JOIN pg_stat_statements s
         ON s.queryid = d.queryid AND s.toplevel = d.toplevel
 WHERE d.indexname = 'orders_customer_id_idx'
 ORDER BY d.calls_executed DESC;
```

> **Before dropping anything** from `pg_index_no_dependents`, check `tracked_since`. Month-end jobs, reports and replicas need to have run while tracking was on.

## Settings

| Setting | Default | Notes |
|---|---|---|
| `pg_stat_index_queries.max` | 10000 | Max tracked (index, query) pairs. Restart to change. Least recently seen entries are evicted when full. |
| `pg_stat_index_queries.track` | `top` | `top`, `all` (include statements inside functions and DO blocks), or `none` |
| `pg_stat_index_queries.track_catalog` | off | Also track indexes on system catalogs |

## Overhead

Early result on a 2-vCPU container, PG 16, pgbench scale 50, `-S -M prepared -c 4`, 3 × 20 s runs:

| | Mean TPS |
|---|---|
| Without | 107,997 |
| With | 107,564 (−0.4%, within run-to-run noise) |

A proper benchmark on real hardware, with a wide schema, is on the roadmap.

## Limitations (0.1)

- Counters are lost on restart; persistence is planned for 0.2.
- Bitmap Index Scans are always counted as executed, because Postgres creates their scan state at startup.
- Parallel workers aren't counted separately; the leader records the statement once.
- Child partition indexes are recorded individually; rolling them up to the parent index is planned.
- Doesn't load on Amazon RDS or Aurora, which only allow approved extensions.

## Tests

```bash
make installcheck   # starts its own temp instance with the library preloaded; run as a non-root user
```

Covers index scans, index-only scans, bitmap scans, planned-but-not-executed, prepared statements, nested statements (`track = top` vs `all`), the helper views, the catalog filter and reset.

## Roadmap

- 0.2: persist across restarts; roll partitions up to the parent index; eviction test
- 0.3: "what would break" view: queries whose only index access path is this index
- Benchmarks with 20+ indexes per table; CI against PG 15–18

## Related work

- [pg_stat_statements](https://www.postgresql.org/docs/current/pgstatstatements.html): per-query stats, no index info
- [pg_qualstats](https://github.com/powa-team/pg_qualstats): predicates used, not the index chosen
- [pg_stat_plans](https://github.com/pganalyze/pg_stat_plans): stores plans per query, no index-centric view
- [HypoPG](https://github.com/HypoPG/hypopg): hypothetical indexes; pairs well with this for "what if I drop it"

## License

PostgreSQL License. See `LICENSE`.
