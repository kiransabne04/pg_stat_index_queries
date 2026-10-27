# User guide

What this repository gives you, how to use it for the questions it answers, and where its answers stop being reliable. For install steps see [INSTALL.md](INSTALL.md); for internals see [ARCHITECTURE.md](ARCHITECTURE.md).

## The problem it solves

PostgreSQL tells you how many times an index was scanned (`idx_scan`) and, since PG 16, when it was last used (`last_idx_scan`). It never tells you **which queries** used it. The usual tools don't either:

| Tool | Gives you | Missing |
|---|---|---|
| `pg_stat_user_indexes` | Scan count, last scan time | Which queries |
| pg_stat_statements | Per-query statistics | Which indexes |
| pg_qualstats | Predicates in WHERE clauses | The index the planner actually chose |
| pg_stat_plans | Plan text per query | A per-index view; you'd grep plan text |
| HypoPG | Hypothetical and hidden indexes | Who uses an index today |

So teams:

- drop an "unused" index that a replica, a month-end job or one important endpoint needed, and find out in production;
- keep duplicate and overlapping indexes forever because nobody can prove who uses them, paying for it in write throughput, memory and storage;
- change indexes in migrations and upgrades without knowing what depends on them.

This repository answers "which queries use this index", and builds on it:

- **Role:** why an index can't be dropped even when unused (primary key, unique, foreign-key target, replica identity, ...).
- **Statistics:** whether the index fits the data (table size, distinct values, skew, NULLs, stale statistics).
- **Column usage:** which index columns queries actually search on.
- **Sole path:** for which queries the index is the only one they used on that table.
- **Drop impact:** the estimated cost and plan change for each dependent query if the index were gone.

## Two extensions

| | `pg_stat_index_queries` (native, C) | `pg_index_deps` (SQL edition) |
|---|---|---|
| Runs on | Self-hosted PostgreSQL 15–18 | Anywhere, including Amazon RDS and Aurora; drop impact needs PG 16+ and HypoPG |
| How it knows | Executor hooks walk every executed plan | Reads index names from captured plan text (`aurora_stat_plans` on Aurora, `pg_stat_plans` self-hosted) |
| Accuracy | Exact; separates planned from executed | Approximate: calls per captured plan that names the index |
| Object names | `pg_index_*` in the extension's schema | `index_deps.*` |

`index_deps.index_drop_impact()` uses the native extension's exact dependents when both are installed.

### How the native extension records

1. At the end of each statement (ExecutorEnd) it walks the plan tree and, for every Index Scan, Index Only Scan and Bitmap Index Scan, records (database, index, queryid, toplevel). An index counts as **planned** when it is in the plan and **executed** when its scan started.
2. Since 0.8 it also records which index columns the scan searched on (`indexqual`) and ordered by through the index operator (`indexorderby`, e.g. KNN).
3. Each session counts in its own memory and moves the counts to shared memory about once a second (`flush_interval`) and when it disconnects.
4. A clean shutdown saves the counters to `pg_stat/pg_stat_index_queries.stat`; they are reloaded at start. A crash loses them.
5. When the table of (index, query) pairs is full, the least recently seen pair is evicted and `dealloc` goes up.

## Install, in short

Native, self-hosted:

```
# postgresql.conf, then restart
shared_preload_libraries = 'pg_stat_index_queries,pg_stat_statements'
compute_query_id = on
```

```sql
CREATE EXTENSION pg_stat_index_queries;
CREATE EXTENSION pg_stat_statements;   -- optional: query text and timing
```

Install it on **every replica** as well: each instance records only its own queries.

SQL edition (RDS, Aurora, anywhere):

```sql
-- Aurora: set aurora_compute_plan_id = on in the parameter group first.
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS hypopg;          -- for the drop-impact check
\i sql_edition/install.sql                        -- or install_pg_tle.sql
```

## Use cases

Examples use the native names; the SQL edition has the same objects under `index_deps.` (see the README's object tables).

### 1. Can I drop this index?

Start with one verdict per index:

```sql
SELECT indexname, index_role, drop_blocker, queries, calls_executed, last_seen,
       tracked_since, verdict, hints
  FROM pg_index_usage
 WHERE tablename = 'orders'
 ORDER BY verdict;
```

The `verdict` says one of:

- `used by N queries`;
- `no recorded use since ...: drop candidate`;
- `no recorded use since ..., but <blocker>` (it enforces a primary key, is referenced by a foreign key, ...);
- `invalid` (for example a failed `CREATE INDEX CONCURRENTLY`);
- `unknown` (entries were evicted, or sampling skipped statements).

Always read `tracked_since`. A few days of tracking prove nothing about a monthly report. Cover a full business cycle, including month-end, on every instance.

### 2. Which queries depend on this index?

```sql
SELECT d.queryid, d.calls_executed, d.last_seen, d.cond_columns, s.query
  FROM pg_index_dependents d
  LEFT JOIN pg_stat_statements s ON s.queryid = d.queryid AND s.toplevel = d.toplevel
 WHERE d.indexname = 'orders_customer_id_idx';
```

### 3. Which queries have no other index to fall back on? (0.9)

```sql
SELECT indexname, queryid, calls_executed, other_indexes, risk
  FROM pg_index_sole_path
 WHERE indexname = 'orders_customer_id_idx'
 ORDER BY risk, calls_executed DESC;
```

| risk | Meaning |
|---|---|
| `high` | The only index on that table the query executed with: dropping it changes that query's plan |
| `medium` | The query also executed with the indexes in `other_indexes` on that table; it may fall back to one of them |
| `low` | Planned, never executed |

### 4. How much worse would those queries get? (SQL edition, PG 16+, HypoPG)

```sql
SELECT queryid, calls, cost_with, cost_without, cost_ratio, plan_changed, note, drop_blocker
  FROM index_deps.index_drop_impact('public.orders_customer_id_idx');
```

It hides the index **for your session only** (HypoPG), re-plans each dependent query with `EXPLAIN (GENERIC_PLAN)` and compares the costs. It never executes a query and never drops anything. It works in read-only transactions, including Aurora readers. `p_timeout_ms` limits the whole call.

### 5. Is this composite index wider than it needs to be? (0.8)

```sql
SELECT indexname, key_position, column_expr, queries, queries_searched, queries_ordered, note
  FROM pg_index_column_usage
 WHERE indexname = 'orders_cust_status_created_idx';
```

Example: on an index on (customer_id, status, created_at) that no query searches on by `created_at`, the note says the column is not searched on by any recorded query: unless it is needed for ORDER BY or index-only scans, an index without it may do.

### 6. Does the index fit the data? (0.7)

```sql
SELECT pg_index_hints('orders_status_idx');

SELECT indexname, table_rows_est, index_to_table_pct, hot_update_pct, stats_stale, small_table
  FROM pg_index_table_stats
 WHERE tablename = 'orders';

SELECT indexname, key_position, column_expr, n_distinct, distinct_est, null_frac,
       top_value_freq, skewed, correlation
  FROM pg_index_column_stats
 WHERE tablename = 'orders';
```

The hints flag:

- a tiny table (a sequential scan wins anyway);
- statistics that are stale, or a table never analyzed;
- few distinct values;
- a skewed leading column (the index helps only the rare values);
- a mostly NULL column (a partial index would be smaller);
- a multicolumn index without `CREATE STATISTICS`;
- write cost without reads.

These views read catalogs and statistics only: they never run ANALYZE or read table data.

### 7. Why is this query slow, and which indexes does it use?

```sql
SELECT indexname, other_indexes, calls, mean_exec_ms, rows_per_call, cache_hit_pct, query
  FROM pg_index_query_stats
 WHERE tablename = 'orders'
 ORDER BY total_exec_ms DESC;
```

### 8. Duplicate or overlapping indexes

Compare `pg_index_dependents` for two indexes on the same table. Index A is the candidate to drop when:

- every query that uses A also uses B; and
- `pg_index_sole_path` never lists A as `high`.

Confirm with `index_drop_impact` before dropping it.

### 9. Before a migration or an upgrade

Save `pg_index_dependents`, joined to pg_stat_statements for the query text, before you change indexes. After the change, call `pg_stat_index_queries_reset()`, let the workload run, and compare.

### 10. Partitioned tables

The per-index views (`pg_index_usage`, `pg_index_no_dependents`, `pg_index_column_usage`, `pg_index_sole_path`) fold partition indexes into the partitioned (parent) index, because that is what you drop. `pg_index_dependents_rollup` adds `partitions_used` and `partition_scans_executed`.

### 11. Is the tracker itself trustworthy right now?

```sql
SELECT entries, dealloc, stats_reset FROM pg_stat_index_queries_info;
SELECT pg_stat_index_queries_sampled();
```

If `dealloc > 0`, raise `pg_stat_index_queries.max` (restart needed) and reset. Until then, "no recorded use" means "unknown".

## Settings (native)

| Setting | Default | Notes |
|---|---|---|
| `pg_stat_index_queries.max` | 10000 | Tracked (index, query) pairs. Restart to change |
| `pg_stat_index_queries.track` | `top` | `all` also records statements inside functions; `none` stops recording |
| `pg_stat_index_queries.track_catalog` | off | Also record system catalog indexes |
| `pg_stat_index_queries.save` | on | Keep counters across restarts |
| `pg_stat_index_queries.save_interval` | 300s | Also save every this often, when the counters changed. A crash then loses at most this much. `0` = only at clean shutdown |
| `pg_stat_index_queries.flush_interval` | 1s | `0` moves counts to shared memory after every statement (slower) |
| `pg_stat_index_queries.sample_rate` | 1.0 | Below 1, counts are scaled estimates and unused indexes are reported as "unknown" |

## Edge cases it handles

- **Planned vs executed.** A scan in a plan branch that never ran (an init plan, a prepared statement whose condition is false) counts as `calls_planned` with `calls_executed = 0`. "Unused" decisions use executed calls only, and `pg_index_sole_path` shows planned-only rows as `low`.
- **Nested statements** (inside functions, DO, CALL, EXPLAIN ANALYZE, CREATE TABLE AS) are recorded with `toplevel = false`, and only with `track = all`. EXECUTE and PREPARE count as top level, as in pg_stat_statements.
- **Constraint indexes.** Primary keys, unique and exclusion constraints, foreign-key targets, replica identity and clustered indexes get a `drop_blocker` and are never drop candidates.
- **Invalid indexes** are reported as invalid, not unused.
- **Partitions.** Partition indexes fold into the parent; attached partition indexes are never listed on their own, since they can't be dropped separately.
- **Upgrades.**
  - Counters saved by an older version are read after the upgrade.
  - Counts from before 0.8 have `columns_complete = false`, so column usage says "unknown" instead of "not searched".
  - A new library works with not-yet-updated SQL objects until `ALTER EXTENSION ... UPDATE`.
- **Statistics.** Columns the caller can't SELECT show `has_stats = false`. Expression indexes use the statistics ANALYZE keeps for the index.
- **Drop impact (SQL edition).**
  - The index is unhidden on every path, including errors and cancellation.
  - Data-changing statements are skipped.
  - Queries that fail to plan are skipped cleanly.
  - Typed literals and `PREPARE` texts are rewritten so they can be EXPLAINed.
  - A hypothetical HypoPG index with the same definition gives a warning, because it would make the drop look free.
- **The same index name in two schemas** (SQL edition): both indexes are credited and the row is flagged `ambiguous`.

## Where the answers stop being reliable

1. **No query id, nothing recorded.** With `compute_query_id = off` and no pg_stat_statements loaded, every statement has query id 0 and is skipped. If the views stay empty, check this first.
2. **A crash loses recent counts.** Counters are saved every `save_interval` (default 5 minutes) and at clean shutdown, and reloaded after a crash, so a crash loses at most the last few minutes. `tracked_since` stays the same, so an index used only in those minutes can look unused. With `save_interval = 0`, a crash loses everything and `tracked_since` restarts.
3. **Evictions.** When `max` is too small, old pairs are dropped, and "unused" becomes "unknown". Watch `dealloc`.
4. **A short tracking window.** A query that runs monthly makes its index look unused until it has run. Only time fixes this.
5. **Replicas record separately.** No use on the primary says nothing about a replica. Check every instance.
6. **Recorded use is not every possible plan.** `high` means no other index was *used* by that query on that table. After a drop, the planner may choose an index it never chose before, or a sequential scan. Use `index_drop_impact` to estimate which.
7. **Drop impact is a cost estimate, not a latency.**
   - It uses generic plans.
   - A partial index whose predicate compares with a constant can return `unknown:` with `plan_changed` NULL. In that case, check the query with EXPLAIN and real values.
   - Stale statistics make the estimate unreliable; the `note` warns about it.
8. **The SQL edition sees only captured plans.**
   - Queries evicted from pg_stat_statements or the plan source are invisible.
   - A renamed index loses its history, and its verdict is "unknown".
   - Plain RDS has no plan source. There is no dependents list there; `index_drop_impact` finds candidate queries by matching pg_stat_statements text.
9. **A recreated index is a new index.** DROP/CREATE or `REINDEX CONCURRENTLY` gives it a new OID, and its history starts at zero.
10. **Column usage doesn't cover two cases.**
    - A plain ordered scan (ORDER BY on the index columns) and index-only coverage don't name columns. A column "not searched on" can still be needed for them.
    - Only key columns 1–32 are recorded.
11. **More than 64 distinct indexes in one statement:** the extra indexes are not recorded for that statement.
12. **Parallel queries** are recorded once, by the leader.
13. **Query statistics are per statement, not per index.** A query that uses three indexes shows the same timing on all three rows. `pct_calls_using_index` compares counters that are reset separately, so it can exceed 100.
14. **Sampling** (`sample_rate < 1`) makes counts estimates, and a rare query can be missed entirely.
15. **The native extension can't run on RDS or Aurora** (no custom C extensions). Use the SQL edition there.
16. **Bitmap Index Scans always count as executed**, because PostgreSQL builds their scan state at executor start.
17. **Stale-statistics hints right after a bulk load.**
    - A session's insert/update counts reach PostgreSQL's shared statistics up to a second late.
    - So a load followed at once by ANALYZE in the same session can still show the loaded rows in `n_mod_since_analyze`, and `stats_stale = true`. `pg_stat_user_tables` shows the same.
    - Fix: run ANALYZE again, or wait a moment before you read the hints.

## Overhead

The cost is per statement, so it shows most on tiny read-only statements. The runs below were on AWS `c7gd.xlarge`, PG 17.11, pgbench scale 100, 3 × 300 s per mode:

- **TPS, best run on 0.6:** `select_only` −1.8% and `wide` −0.9%. Runs on other instances measured up to −3.4% / −4.6%, because instances alone differ by up to 6%.
- **CPU profile:** the extension's own code is about 0.7% of all CPU samples.
- **0.8:** recording index columns adds no measurable cost over 0.7 on the same instance.

Details and raw results: README "Overhead" and [BENCHMARK.md](BENCHMARK.md).

## What has been verified

| Where | Result |
|---|---|
| Native extension, PG 15–18 (Docker, CI) | Regression and TAP tests pass, including persistence after a real crash, eviction, flush across sessions and column sets across restarts |
| SQL edition, PG 16–18 | Regression tests pass (parsing, live pg_stat_plans, drop impact, statistics, upgrades) |
| Index lab, Docker PG 16–18 | 193 PASS, 0 FAIL, 5 KNOWN (documented limits above: same name in two schemas, renamed index, recreated index) |
| Aurora PostgreSQL 17.9 (24 Oct 2026) | Index lab 115 PASS, 0 FAIL; reader instance tested |
| RDS for PostgreSQL 17.11 (24 Oct 2026) | Index lab 33 PASS, 0 FAIL |

Details: [TESTING.md](TESTING.md).
