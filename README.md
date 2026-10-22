# pg_stat_index_queries

**Which queries use this index?** Postgres tells you how many times an index was scanned (`idx_scan`) and, since PG 16, when it was last used. It never tells you *which queries* depend on it. This repository answers that question, and estimates what happens to those queries if the index is dropped.

```sql
SELECT indexname, queryid, calls_executed, last_seen
  FROM pg_index_dependents
 WHERE indexname = 'orders_customer_id_idx';
```

> **Status: 0.2, experimental.** Tested on PostgreSQL 16. CI is set up for 15–18 but hasn't run yet. Don't rely on it in production until CI is green and you've benchmarked it on your hardware.

## Two extensions in this repo

| | `pg_stat_index_queries` (native, C) | `pg_index_deps` (SQL edition) |
|---|---|---|
| Runs on | Self-hosted Postgres 15–18 | Anywhere, including **Amazon RDS and Aurora** |
| How it knows | Walks every executed plan | Reads captured plan text (`aurora_stat_plans` on Aurora, `pg_stat_plans` self-hosted) |
| Accuracy | Exact; separates "planned" from "executed" | Approximate: calls per plan that names the index |
| Drop-impact check | — | `index_deps.index_drop_impact()` (PG 16+, HypoPG) |
| Install | `shared_preload_libraries` + `CREATE EXTENSION` | `CREATE EXTENSION`, plain `install.sql`, or pg_tle |

The drop-impact check works with either: if the native extension is installed it uses its exact dependents.

## Quick start (self-hosted, native)

```bash
make && sudo make install
```

`postgresql.conf`:

```
shared_preload_libraries = 'pg_stat_index_queries'   # restart required
compute_query_id = on
```

```sql
CREATE EXTENSION pg_stat_index_queries;
-- ... let the workload run (include month-end jobs!) ...
SELECT * FROM pg_index_no_dependents;          -- candidates to drop, with tracked_since
SELECT * FROM pg_index_dependents WHERE indexname = 'my_idx';
```

Install it on **every replica** too: replicas often depend on indexes the primary never uses.

## Quick start (RDS / Aurora, SQL edition)

See [docs/INSTALL.md](docs/INSTALL.md) for step-by-step instructions. In short:

```sql
-- Aurora: set aurora_compute_plan_id = on in the parameter group first.
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS hypopg;          -- for the drop-impact check
\i sql_edition/install.sql                        -- or install_pg_tle.sql
SELECT * FROM index_deps.index_dependents WHERE indexname = 'my_idx';
SELECT * FROM index_deps.index_drop_impact('public.my_idx');
```

`index_drop_impact` hides the index **for your session only** (HypoPG), re-plans each dependent query with `EXPLAIN (GENERIC_PLAN)` and reports cost before and after, and whether the plan changes. It never executes a query and never drops anything.

## Objects

**Native extension**

| Object | What it gives you |
|---|---|
| `pg_stat_index_queries` | Raw counters: dbid, indexrelid, queryid, toplevel, calls_executed, calls_planned, first_seen, last_seen |
| `pg_index_dependents` | Same, with schema, table and index names, current database |
| `pg_index_dependents_rollup` | Partition indexes rolled up to the partitioned (parent) index |
| `pg_index_no_dependents` | User indexes with no executed use since `tracked_since` (excludes PK, unique, constraint indexes). Partitioned tables: one row per parent index, unused only if no partition index was used; size is the whole tree |
| `pg_stat_index_queries_info` | Entries, evictions (`dealloc`), `stats_reset` |
| `pg_stat_index_queries_reset()` | Clear counters (superuser by default) |

**SQL edition (`index_deps` schema)**

| Object | What it gives you |
|---|---|
| `plan_index_usage` | Every index reference found in captured plans |
| `index_dependents` | Per index and query: plans, calls, scan types, `ambiguous` flag |
| `index_no_dependents` | Indexes no captured plan mentions (partition-aware like the native view). Empty when there is no plan source (`none`, e.g. RDS) |
| `index_drop_impact(index)` | Cost and plan change per dependent query if the index were gone |
| `config` | `plan_source`: auto, aurora_stat_plans, pg_stat_plans, none |

## Settings (native)

| Setting | Default | Notes |
|---|---|---|
| `pg_stat_index_queries.max` | 10000 | Tracked (index, query) pairs. Restart to change. Least recently seen evicted when full |
| `pg_stat_index_queries.track` | `top` | `top`, `all` (include statements inside functions), `none` |
| `pg_stat_index_queries.track_catalog` | off | Also track system catalog indexes |
| `pg_stat_index_queries.save` | on | Keep counters across clean restarts (lost on crash) |

## Overhead

Early result, 2-vCPU container, PG 16, pgbench scale 50, `-S -M prepared -c 4`, 3 × 20 s: **107,997 tps without, 107,564 with (−0.4%, within noise)**. Proper numbers on a 4–8 vCPU machine are a roadmap item: run `make bench`.

## Tests

```bash
make installcheck                 # native: 3 regression suites + 2 TAP tests (persistence incl. a real crash, eviction)
make -C sql_edition installcheck  # SQL edition: parsing, live pg_stat_plans, drop-impact (needs pg_stat_plans + HypoPG)
make test-all                     # both
```

Run as a non-root user. See [docs/TESTING.md](docs/TESTING.md).

## Docs

- [docs/INSTALL.md](docs/INSTALL.md): self-hosted, RDS, Aurora
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): how it works inside
- [docs/TESTING.md](docs/TESTING.md): test suites, what is and isn't verified
- [docs/PRD-and-Spec.md](docs/PRD-and-Spec.md): product requirements and full spec
- [docs/DECISIONS.md](docs/DECISIONS.md), [docs/ROADMAP.md](docs/ROADMAP.md)
- [AGENTS.md](AGENTS.md): instructions for coding agents (Codex, Claude Code)

## Limitations

- Native extension: self-hosted only (RDS/Aurora don't allow custom C extensions).
- Bitmap Index Scans always count as executed (Postgres builds their scan state at startup).
- Counters are lost on crash (saved only at clean shutdown).
- SQL edition only sees queries whose plans were captured, and loses ones evicted from pg_stat_statements.
- Drop-impact uses generic-plan cost estimates, not measured latency.

## Related work

- [pg_stat_statements](https://www.postgresql.org/docs/current/pgstatstatements.html): per-query stats, no index information
- [pg_qualstats](https://github.com/powa-team/pg_qualstats): predicates used, not the index the planner chose
- [pg_stat_plans](https://github.com/pganalyze/pg_stat_plans): plans per query; the SQL edition reads it
- [HypoPG](https://github.com/HypoPG/hypopg): hypothetical and hidden indexes; used by `index_drop_impact()`
- [pg_ash](https://github.com/NikolayS/pg_ash), [pgsentinel](https://github.com/pgsentinel/pgsentinel): active session history (what sessions were waiting on); a different, complementary question
- pg_regression_watch (sister project): which query regressed, when and why

## License

PostgreSQL License. See [LICENSE](LICENSE).
