# pg_stat_index_queries

**Which queries use this index?** Postgres tells you how many times an index was scanned (`idx_scan`) and, since PG 16, when it was last used. It never tells you *which queries* depend on it. This repository answers that question, and estimates what happens to those queries if the index is dropped.

```sql
SELECT indexname, queryid, calls_executed, last_seen
  FROM pg_index_dependents
 WHERE indexname = 'orders_customer_id_idx';
```

> **Status: 0.6 (SQL edition 0.4), experimental.** Tests pass on PostgreSQL 15–18 (Docker and GitHub Actions). Overhead is benchmarked below. The SQL edition is verified on Aurora PostgreSQL 17.9 and RDS 17.11 (24 Oct 2026). The validation lab (`sql_edition/validation/lab/`) passes on PG 16–18 in Docker, Aurora and RDS; see [docs/TESTING.md](docs/TESTING.md#index-lab-docker-24-oct-2026). Don't rely on it in production until you've benchmarked it on your hardware.

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
SELECT indexname, index_role, queries, verdict FROM pg_index_usage ORDER BY verdict;  -- one verdict per index
SELECT queryid, calls_executed, last_seen FROM pg_index_dependents WHERE indexname = 'my_idx';
-- debugging: each (index, query) with timing, rows, buffers and query text
SELECT indexname, other_indexes, calls, mean_exec_ms, rows_per_call, cache_hit_pct, query
  FROM pg_index_query_stats WHERE tablename = 'orders' ORDER BY total_exec_ms DESC;
```

Install it on **every replica** too: replicas often depend on indexes the primary never uses.

## Quick start (RDS / Aurora, SQL edition)

See [docs/INSTALL.md](docs/INSTALL.md) for step-by-step instructions. In short:

```sql
-- Aurora: set aurora_compute_plan_id = on in the parameter group first.
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS hypopg;          -- for the drop-impact check
\i sql_edition/install.sql                        -- or install_pg_tle.sql
SELECT indexname, index_role, queries, verdict FROM index_deps.index_usage;
SELECT queryid, calls, scan_types, index_role FROM index_deps.index_dependents WHERE indexname = 'my_idx';
SELECT queryid, calls, mean_exec_ms, rows_per_call, query FROM index_deps.index_query_stats WHERE indexname = 'my_idx';
SELECT queryid, cost_ratio, plan_changed, note, drop_blocker FROM index_deps.index_drop_impact('public.my_idx');
```

`index_drop_impact` hides the index **for your session only** (HypoPG), re-plans each dependent query with `EXPLAIN (GENERIC_PLAN)` and reports cost before and after, and whether the plan changes. It never executes a query and never drops anything.

## Objects

**Native extension**

| Object | What it gives you |
|---|---|
| `pg_stat_index_queries` | Raw counters: dbid, indexrelid, queryid, toplevel, calls_executed, calls_planned, first_seen, last_seen |
| `pg_index_dependents` | Same, with schema, table and index names, current database, and `index_role` |
| `pg_index_usage` | One row per index (partitions folded into the parent): `index_role`, `index_notes`, `drop_blocker`, queries and calls since `tracked_since`, and a `verdict` (used / drop candidate / no use but needed, e.g. enforces a primary key / invalid / unknown after evictions) |
| `pg_index_role(index)` | What an index is for besides speed: `index_role` (primary key, unique constraint, exclusion constraint, unique index, index), `index_notes` (referenced by foreign keys, replica identity, clustered, invalid, partial, expression, partition) and `drop_blocker` (why DROP INDEX fails or changes behaviour) |
| `pg_index_dependents_rollup` | Partition indexes rolled up to the partitioned (parent) index |
| `pg_index_query_stats` | For debugging: each (index, query) with the index definition, size, unique/partial flags, `index_role` and `index_notes`, calls through the index and `pct_calls_using_index`, `other_indexes` the query used, and the query's pg_stat_statements stats (calls, total/mean/min/max exec ms, plans and plan ms, rows and rows per call, shared buffers hit/read/dirtied/written, `cache_hit_pct`, temp blocks, I/O ms, WAL bytes, roles, query text). Stats summed over roles; NULL when pg_stat_statements no longer has the query. Needs pg_stat_statements when queried, not to install |
| `pg_index_no_dependents` | User indexes with no executed use since `tracked_since` (excludes PK, unique, constraint indexes). Partitioned tables: one row per parent index, unused only if no partition index was used; size is the whole tree |
| `pg_stat_index_queries_info` | Entries, evictions (`dealloc`), `stats_reset` |
| `pg_stat_index_queries_reset()` | Clear counters (superuser by default) |

**SQL edition (`index_deps` schema)**

| Object | What it gives you |
|---|---|
| `plan_index_usage` | Every index reference found in captured plans |
| `index_dependents` | Per index and query: plans, calls, scan types, `ambiguous` flag, `index_role` |
| `index_usage` | One row per index: role, notes, `drop_blocker`, queries and calls from captured plans, and a `verdict` (like the native `pg_index_usage`; `unknown` when there is no plan source or when plans on the table name an index that no longer exists) |
| `index_role(index)` | Same as the native `pg_index_role` |
| `unresolved_plan_indexes` | Index names in captured plans that no longer exist (renamed or dropped) |
| `index_query_stats` | Same as the native `pg_index_query_stats`, with `index_plans`, `index_calls`, `scan_types`, `ambiguous` and `source` from the captured plans (stats also summed over top-level and nested) |
| `index_no_dependents` | Indexes no captured plan mentions (partition-aware like the native view). Leaves out tables whose plans name a missing (renamed?) index. Empty when there is no plan source (`none`, e.g. RDS) |
| `index_drop_impact(index)` | Cost and plan change per dependent query if the index were gone, plus `drop_blocker`. Works in read-only transactions (Aurora readers); `p_timeout_ms` is a time budget for the whole call |
| `config` | `plan_source`: auto, aurora_stat_plans, pg_stat_plans, none |

## Settings (native)

| Setting | Default | Notes |
|---|---|---|
| `pg_stat_index_queries.max` | 10000 | Tracked (index, query) pairs. Restart to change. Least recently seen evicted when full |
| `pg_stat_index_queries.track` | `top` | `top`, `all` (include statements inside functions), `none` |
| `pg_stat_index_queries.track_catalog` | off | Also track system catalog indexes |
| `pg_stat_index_queries.save` | on | Keep counters across clean restarts (lost on crash) |
| `pg_stat_index_queries.flush_interval` | 1s | Each session counts in its own memory and moves the counts to shared memory this often (and when it disconnects). Other sessions see them up to this late; a session always sees its own. `0` = after every statement (0.5 behaviour, slower) |
| `pg_stat_index_queries.sample_rate` | 1.0 | Fraction of statements recorded; counts are scaled up. Below 1, counts are estimates and `pg_index_usage` reports unused indexes as "unknown" (a rarely used index can be missed) |

## Overhead

Measured on AWS `c7gd.xlarge`: 4 Graviton3 vCPU, non-burstable, data on local NVMe. PostgreSQL 17.11, pgbench scale 100, 4 clients, 3 × 300 s per mode, with modes interleaved. Raw results: [0.6](bench/results/2026-10-25-aws-c7gd.xlarge-pg17-v06.md), [0.6 with `flush_interval=0`](bench/results/2026-10-25-aws-c7gd.xlarge-pg17-v06-flush0.md), [0.5](bench/results/2026-10-24-aws-c7gd.xlarge-pg17.md).

| Workload | 0.5 | 0.6 (default, batching) | 0.6, `flush_interval=0` |
|---|---|---|---|
| `select_only` (`-S`, one PK lookup per transaction: worst case) | −3.4% | **−1.8%** (within noise: spread 3.6% / 1.7%) | −3.0% |
| `wide` (20-index table, 3 statements per transaction) | −2.9% | **−0.9%** | not run |
| `tpcb` (pgbench default, read/write) | +1.7% (noise) | +2.1% (noise) | not run |

The cost is per statement, so it shows on tiny read-only statements. Batching (0.6) removes the shared-memory write from every statement. That roughly halves the overhead on `select_only`, and brings `wide` under 1%. The same machine with `flush_interval=0` (the 0.5 path) still costs 3%, so the gain comes from batching. What remains on `select_only` (about 1–2%) is the executor hooks and the plan walk. To go lower still, `sample_rate` skips the walk for most statements, with the trade-offs listed in Settings. `bench/aws-ec2.sh` reruns all of this.

## Tests

```bash
make installcheck                 # native: 6 regression suites + 3 TAP tests (persistence incl. a real crash, eviction, flush across sessions)
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
- `pg_index_query_stats` / `index_query_stats`: timing and buffers are per statement, not per index; a query using three indexes shows the same numbers on all three rows. `pct_calls_using_index` compares counters that are reset separately, so it can exceed 100 after a reset of one but not the other.
- Drop-impact uses generic-plan cost estimates, not measured latency. When the generic plan can't use the index although real plans did (typically a partial index whose predicate has a constant), the row says `unknown:` with `plan_changed` NULL: check that query with EXPLAIN and real values.

## Related work

- [pg_stat_statements](https://www.postgresql.org/docs/current/pgstatstatements.html): per-query stats, no index information
- [pg_qualstats](https://github.com/powa-team/pg_qualstats): predicates used, not the index the planner chose
- [pg_stat_plans](https://github.com/pganalyze/pg_stat_plans): plans per query; the SQL edition reads it
- [HypoPG](https://github.com/HypoPG/hypopg): hypothetical and hidden indexes; used by `index_drop_impact()`
- [pg_ash](https://github.com/NikolayS/pg_ash), [pgsentinel](https://github.com/pgsentinel/pgsentinel): active session history (what sessions were waiting on); a different, complementary question
- pg_regression_watch (sister project): which query regressed, when and why

## License

PostgreSQL License. See [LICENSE](LICENSE).
