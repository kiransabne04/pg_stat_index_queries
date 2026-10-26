# Architecture

## Native extension (`pg_stat_index_queries.c`)

```
ExecutorRun / ExecutorFinish / ProcessUtility   -> track nesting level only
ExecutorEnd                                     -> walk PlanState tree, add index OIDs to a backend-local pending table
before_shmem_exit (backend)                     -> flush pending counts when the session ends
shmem_request / shmem_startup                   -> shared hash + LWLock tranche; load saved file
on_shmem_exit (postmaster)                      -> save file at clean shutdown
```

### Capture (ExecutorEnd)
1. Skip when: not preloaded, parallel worker, `queryId = 0`, or nesting level excluded by `track`.
2. Walk the executed `PlanState` tree (`planstate_tree_walker`, root visited explicitly). Covers initPlans, subPlans, Append/MergeAppend children, BitmapAnd/Or.
3. For IndexScan / IndexOnlyScan / BitmapIndexScan nodes take `indexid` from the plan node.
4. **Executed vs planned:** IndexScan and IndexOnlyScan call `index_beginscan()` lazily on the first fetch (verified in PG 16 and 18 source), so a non-NULL `iss_ScanDesc` / `ioss_ScanDesc` means the scan ran. BitmapIndexScan builds its scan descriptor at init, so it is always counted as executed (approximation).
4a. **Columns (0.8):** for a scan that ran, the index columns in `indexqual` (and `indexorderby` for IndexScan / IndexOnlyScan) go into two `uint32` bitmasks, `cond_cols` and `order_cols`. Those expressions name index columns as `Var` with `varno = INDEX_VAR` and `varattno` = index column number (PG 15–18). Masks are OR'd per statement, into the pending entry and into the shared entry; columns above 32 (only with a larger `INDEX_MAX_KEYS`) are not recorded. A scan with no index condition (ordered scan, index-only count) records none. The 0.8 SQL function binds the C symbol `pg_stat_index_queries_0_8`; `pg_stat_index_queries` keeps the 8-column result, so a not-yet-updated extension works with the new library.
5. De-duplicate per statement (up to 64 distinct indexes; more are dropped and the overflow is ignored).
6. Skip catalog indexes (`oid < FirstNormalObjectId`) unless `track_catalog`.
7. **Sampling (0.6):** with `sample_rate` < 1 a statement is recorded with that probability (`pg_prng_double`), and its counts are multiplied by `rint(1 / sample_rate)`. A skipped statement sets a shared `sampled` flag (written only when it was not already set), shown by `pg_stat_index_queries_sampled()` and used by `pg_index_usage` to report "unknown" instead of "no recorded use".

### Nesting
`EXECUTE` and `PREPARE` don't increase nesting (same as pg_stat_statements), so SQL-level prepared statements count as top level. Statements inside DO blocks, functions, CALL, EXPLAIN ANALYZE count as nested.

### Backend-local batching (0.6)
- Each backend adds its counts to a local hash (`TopMemoryContext`, same key) instead of the shared hash. Timestamps are the statement start (cached), so there is no clock call per statement.
- Flush to the shared hash: when `flush_interval` (default 1 s) has passed since the last flush, without waiting if the lock is busy (`LWLockConditionalAcquire`; the counts stay pending and are retried at the next statement); immediately when the pending table reaches 512 entries or `flush_interval = 0`; when the backend exits (`before_shmem_exit`); and before the backend reads the counters itself (`pg_stat_index_queries()`, `pg_stat_index_queries_info()`), so a session always sees its own counts.
- Flush updates existing entries under the shared LWLock with the per-entry spinlock, then inserts new entries under the exclusive LWLock.
- Why: in 0.5 every statement took the one shared LWLock and the entry spinlock, so on a busy server all cores kept writing the same cache lines (−3.4% on pgbench `-S`, 4 vCPU). Same model as PostgreSQL's own cumulative statistics (pending stats flushed about once a second).
- Cost: other sessions see a backend's counts up to `flush_interval` late; a backend crash loses its pending counts (a crash already loses all counters); `pg_stat_index_queries_reset()` drops the caller's pending counts, but other backends' pending counts arrive after the reset.

### Shared memory
- Key: `(dbid, indexrelid, queryid, toplevel)`, zero-padded with `memset` (HASH_BLOBS).
- Entry: `calls_executed`, `calls_planned`, `first_seen`, `last_seen`, spinlock.
- Locking: shared LWLock for lookup + spinlock for counters; exclusive LWLock only to insert or evict.
- Eviction: when full, sort by `last_seen`, remove the oldest 5% (at least 10); `dealloc` counts runs.

### Persistence (0.2)
- File `pg_stat/pg_stat_index_queries.stat`: header (magic + format version), PG major, count, dealloc, stats_reset, `sampled` (format 2, 0.6+), then fixed-size records (format 3, 0.8+: with `cond_cols` and `order_cols`). Format 1 (0.2–0.5) and 2 (0.6–0.7) files are still read, so upgrading doesn't lose the counters; their entries get `cols_complete = false`, and `pg_index_column_usage` then says "unknown" instead of reporting a column as unused.
- Written by the postmaster at clean shutdown (`on_shmem_exit`, exit code 0 only) to `.tmp`, then `durable_rename`.
- Loaded when shared memory is created; deleted after loading so a crash never reloads stale data.
- Any mismatch or short read: LOG "ignoring invalid … file", discard everything, delete the file.

### SQL objects
- `pg_stat_index_queries()` set-returning function (materialized SRF) and view.
- Helper views join `pg_class` / `pg_index` for names; `pg_index_dependents_rollup` maps child indexes to their partitioned parent with `pg_partition_root()` and reports `calls_executed` as the max per partition (lower bound on statements) and `partition_scans_executed` as the sum. `pg_index_no_dependents` (0.3) uses the same mapping: a partitioned index is used if any index in its tree is, and attached partition indexes aren't listed on their own.
- `pg_index_query_stats` (0.4) is a view over a PL/pgSQL function that joins `pg_index_dependents` to pg_stat_statements on (queryid, toplevel), summing over roles. It finds pg_stat_statements through `pg_extension` when called, so there is no install-time dependency and dropping pg_stat_statements isn't blocked; without it the view raises an error with a hint. `blk_read_time`/`blk_write_time` were renamed `shared_blk_*_time` in PG 17, so those two are read through `to_jsonb(row)` and one query text works on 15–18. The SQL edition's `index_deps.index_query_stats` (0.3) does the same over `index_deps.index_dependents`, joined on queryid only.

### Table and column statistics (0.7; SQL edition 0.6)
- `pg_index_table_stats`, `pg_index_column_stats` and `pg_index_hints()` (in the SQL edition: `index_deps.index_table_stats`, `index_column_stats`, `index_hints()`) put the planner's own statistics next to each index: `pg_class`, `pg_stat_user_tables` / `_indexes`, `pg_stats` and `pg_statistic_ext`. They never run ANALYZE and never read table data.
- Both editions are generated from one source, `scripts/stats_objects.sql.in`: `scripts/gen_stats_objects.py native|sql` fills in the name prefix and prints the objects, which are pasted into each version script (version scripts must be self-contained). The regression test is shared the same way (`scripts/stats_test.sql.in`).
- Partitioned tables are summed over their leaf partitions (`pg_partition_tree`). Expression key columns take the statistics ANALYZE stores under the index's name. `last_idx_scan` (PG 16+) is read through `to_jsonb(row)` so one definition works on 15–18.
- `stats_stale` uses autovacuum's analyze rule (more than 50 rows + 10% changed since the last analyze, per partition), or never analyzed.
- `skewed`: the top value covers at least 10% of rows and either 5× the average share of a value or 10× the share of the rarest common value. The second clause catches few-valued columns (e.g. 95 / 4.5 / 0.5% over 3 values), where 5× the average share is above 100%.
- Hints feed `pg_index_usage.hints` / `index_usage.hints`, and `index_drop_impact`'s `note` mentions stale or missing statistics.

## SQL edition (`sql_edition/pg_index_deps--0.1.sql`)

```
plan_source()        adapter: aurora_stat_plans | pg_stat_plans | none | test table
plan_index_usage     regex over text plans: Index [Only] Scan [Backward] using IDX on TBL, Bitmap Index Scan on IDX
index_dependents     resolve names -> OIDs (table name from the same line or the Bitmap Heap Scan line);
                     same name in two schemas -> ambiguous = true
index_no_dependents  indexes not referenced by any captured plan (partition-aware; empty when plan_source = none)
index_drop_impact()  candidates: native extension > captured plans > statements mentioning the table
                     for each: EXPLAIN (GENERIC_PLAN, FORMAT JSON) -> hypopg_hide_index -> EXPLAIN -> unhide
```

Query text comes from pg_stat_statements, which isn't always valid SQL: typed literals are normalized to `interval $4` and prepared statements are stored as `PREPARE name(types) AS …`. `index_deps.explainable_query()` rewrites both (`$4::interval`; inner query with `$n::declared_type`) before EXPLAIN; the `query` column still shows the original text.

Safety of `index_drop_impact`:
- HypoPG's hidden-index list lives in backend memory, not in the transaction, so every error path calls `hypopg_unhide_index` explicitly; tests check `hypopg_hidden_indexes()` is empty afterwards.
- Per-query `statement_timeout` (default 2 s); non-read statements skipped unless `p_include_dml`.
- Only EXPLAIN is run; queries are never executed.
- A generic plan can differ from the plans that actually ran. When it doesn't use the index but recorded plans of that query did, or the index is partial with a constant in its predicate (`WHERE status = 'open'` can't be proven from `status = $1`, since pg_stat_statements replaced the constant), `plan_changed` is NULL and `note` starts with `unknown:`. Reporting "unchanged" there would make the index look safe to drop. Predicates without constants (`WHERE deleted_at IS NULL`) still plan normally. With no plan source, a constant-predicate partial index is reported unknown for every candidate the generic plan doesn't use it for, including ones that never needed it: noisy but never falsely "unchanged".
