# Architecture

## Native extension (`pg_stat_index_queries.c`)

```
ExecutorRun / ExecutorFinish / ProcessUtility   -> track nesting level only
ExecutorEnd                                     -> walk PlanState tree, record index OIDs
shmem_request / shmem_startup                   -> shared hash + LWLock tranche; load saved file
on_shmem_exit (postmaster)                      -> save file at clean shutdown
```

### Capture (ExecutorEnd)
1. Skip when: not preloaded, parallel worker, `queryId = 0`, or nesting level excluded by `track`.
2. Walk the executed `PlanState` tree (`planstate_tree_walker`, root visited explicitly). Covers initPlans, subPlans, Append/MergeAppend children, BitmapAnd/Or.
3. For IndexScan / IndexOnlyScan / BitmapIndexScan nodes take `indexid` from the plan node.
4. **Executed vs planned:** IndexScan and IndexOnlyScan call `index_beginscan()` lazily on the first fetch (verified in PG 16 and 18 source), so a non-NULL `iss_ScanDesc` / `ioss_ScanDesc` means the scan ran. BitmapIndexScan builds its scan descriptor at init, so it is always counted as executed (approximation).
5. De-duplicate per statement (up to 64 distinct indexes; more are dropped and the overflow is ignored).
6. Skip catalog indexes (`oid < FirstNormalObjectId`) unless `track_catalog`.

### Nesting
`EXECUTE` and `PREPARE` don't increase nesting (same as pg_stat_statements), so SQL-level prepared statements count as top level. Statements inside DO blocks, functions, CALL, EXPLAIN ANALYZE count as nested.

### Shared memory
- Key: `(dbid, indexrelid, queryid, toplevel)`, zero-padded with `memset` (HASH_BLOBS).
- Entry: `calls_executed`, `calls_planned`, `first_seen`, `last_seen`, spinlock.
- Locking: shared LWLock for lookup + spinlock for counters; exclusive LWLock only to insert or evict.
- Eviction: when full, sort by `last_seen`, remove the oldest 5% (at least 10); `dealloc` counts runs.

### Persistence (0.2)
- File `pg_stat/pg_stat_index_queries.stat`: header (magic + format version), PG major, count, dealloc, stats_reset, then fixed-size records.
- Written by the postmaster at clean shutdown (`on_shmem_exit`, exit code 0 only) to `.tmp`, then `durable_rename`.
- Loaded when shared memory is created; deleted after loading so a crash never reloads stale data.
- Any mismatch or short read: LOG "ignoring invalid … file", discard everything, delete the file.

### SQL objects
- `pg_stat_index_queries()` set-returning function (materialized SRF) and view.
- Helper views join `pg_class` / `pg_index` for names; `pg_index_dependents_rollup` maps child indexes to their partitioned parent with `pg_partition_root()` and reports `calls_executed` as the max per partition (lower bound on statements) and `partition_scans_executed` as the sum.

## SQL edition (`sql_edition/pg_index_deps--0.1.sql`)

```
plan_source()        adapter: aurora_stat_plans | pg_stat_plans | none | test table
plan_index_usage     regex over text plans: Index [Only] Scan [Backward] using IDX on TBL, Bitmap Index Scan on IDX
index_dependents     resolve names -> OIDs (table name from the same line or the Bitmap Heap Scan line);
                     same name in two schemas -> ambiguous = true
index_no_dependents  indexes not referenced by any captured plan
index_drop_impact()  candidates: native extension > captured plans > statements mentioning the table
                     for each: EXPLAIN (GENERIC_PLAN, FORMAT JSON) -> hypopg_hide_index -> EXPLAIN -> unhide
```

Safety of `index_drop_impact`:
- HypoPG's hidden-index list lives in backend memory, not in the transaction, so every error path calls `hypopg_unhide_index` explicitly; tests check `hypopg_hidden_indexes()` is empty afterwards.
- Per-query `statement_timeout` (default 2 s); non-read statements skipped unless `p_include_dml`.
- Only EXPLAIN is run; queries are never executed.
