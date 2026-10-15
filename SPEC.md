# pg_stat_index_queries — Spec v0.1

Working name: `pg_stat_index_queries` (follows the `pg_stat_*` convention).
Author: Kiran · Draft: 12 Oct 2026

## 1. Problem

Before dropping or changing an index, a DBA needs to know **which queries depend on it**.

Postgres today:
- `pg_stat_user_indexes.idx_scan` — a counter per index. No query attribution.
- `last_idx_scan` (PG 16+) — *when* the index was last used, not *by what*.
- `pg_stat_statements` — per-query stats, but no index information.
- `pg_qualstats` — predicates used in WHERE clauses, not the index the planner actually chose.
- `pg_stat_plans` (pganalyze) — stores plans per query; you can grep plan text, but there is no index-centric view or count.

Consequences seen in real audits:
- "Unused" indexes dropped on the primary that read replicas depended on.
- Duplicate/overlapping indexes kept forever because nobody can prove which queries use which.
- Index changes during upgrades or migrations without knowing blast radius.

## 2. Goal

A native extension that records, per index, which normalized queries (query IDs) executed a plan using that index, how often, and when — cheap enough to run in production.

**Primary question it answers:**
> "If I drop index X, which queries change plan, and how often do they run?"

## 3. Non-goals (v0.1)

- No index recommendations (hypopg, pg_qualstats, LLMs cover this).
- No plan storage (pg_stat_plans covers it).
- No timing per index node (needs instrumentation; too expensive).
- No cross-node aggregation (each server reports its own; aggregate externally).
- No managed-cloud support (RDS/Aurora won't allow loading it).

## 4. Supported versions

PostgreSQL 15, 16, 17, 18 (PGXS build). Requires `compute_query_id = on` or `auto` (with pg_stat_statements loaded, queryId is computed).
Version-specific code isolated behind `#if PG_VERSION_NUM` blocks.

## 5. Design

### 5.1 Loading
- `shared_preload_libraries = 'pg_stat_index_queries'` (needs shared memory).
- Hooks: `shmem_request_hook` (PG15+), `shmem_startup_hook`, `ExecutorStart_hook`, `ExecutorRun_hook`, `ExecutorFinish_hook`, `ExecutorEnd_hook` (the Run/Finish hooks only track nesting level, like pg_stat_statements).

### 5.2 Capture
At `ExecutorEnd`:
1. Skip if disabled, if `queryDesc->plannedstmt->queryId == 0`, or if `IsParallelWorker()` (the leader counts once per statement).
2. Skip nested statements unless `track = all`.
3. Walk the executed `PlanState` tree with `planstate_tree_walker` (covers child plans, initPlans, subPlans).
4. For each node of type IndexScan, IndexOnlyScan, BitmapIndexScan: take the index OID from the plan node (`indexid`).
5. Record "executed" vs "planned only":
   - Index/IndexOnly scans begin the scan lazily on first fetch, so a non-NULL scan descriptor in the state node means it actually ran. **Verify this in the executor source for each supported version before relying on it.**
   - Bitmap index scans: treat as executed if the parent BitmapHeapScan was initialized; mark as approximate in docs.
6. De-duplicate index OIDs within one statement (one index used twice in a plan counts once per statement).
7. Update the shared hash for each (dbid, indexrelid, queryid, toplevel).

Prepared statements, PL/pgSQL statements and cursors go through the executor and are captured. Partitioned tables: child-index OIDs are recorded; the helper view maps them to the parent index via `pg_inherits`.

### 5.3 Shared memory

Hash table (`ShmemInitHash`), key:

| Field | Type |
|---|---|
| dbid | Oid |
| indexrelid | Oid |
| queryid | int64 |
| toplevel | bool |

Entry:

| Field | Type | Notes |
|---|---|---|
| calls_executed | int64 | statements that actually scanned it |
| calls_planned | int64 | statements whose plan included it |
| first_seen | TimestampTz | |
| last_seen | TimestampTz | |
| mutex | slock_t | per-entry spinlock for counters |

Concurrency (pg_stat_statements pattern): look up under a shared LWLock; update counters under the entry spinlock; take the LWLock exclusive only to insert. When full, evict the ~5% of entries with oldest `last_seen`, and count evictions in a stats row (`dealloc`).

Size: GUC `pg_stat_index_queries.max` (default 10,000 entries).

### 5.4 Persistence
v0.1: in-memory only, lost on restart (documented).
v0.2: dump to `pg_stat/pg_stat_index_queries.stat` on shutdown and reload on start, like pg_stat_statements (`.save` GUC).

### 5.5 Query text
Not stored. Join to `pg_stat_statements` on (dbid, queryid) when it is installed. Avoids a second text store and its memory cost.

## 6. SQL interface

```sql
-- core view
pg_stat_index_queries(
  dbid oid, indexrelid oid, queryid bigint, toplevel bool,
  calls_executed bigint, calls_planned bigint,
  first_seen timestamptz, last_seen timestamptz)

pg_stat_index_queries_reset() returns void
pg_stat_index_queries_info  -- dealloc count, stats_reset time

-- helper views (current database)
pg_index_dependents        -- index name, table, queryid, calls, last_seen, query text (if pgss)
pg_index_no_dependents     -- indexes with no recorded queries since reset,
                           -- excluding unique/PK/constraint indexes, with tracking-window length
pg_index_overlap_users     -- for indexes whose leading columns overlap, the queries using each
```

The `pg_index_no_dependents` view must show "tracked since <reset time>" so nobody drops an index after 10 minutes of data.

## 7. GUCs

| GUC | Default | Purpose |
|---|---|---|
| pg_stat_index_queries.enabled | on | master switch (superuser, reloadable) |
| pg_stat_index_queries.track | top | top / all (nested statements) |
| pg_stat_index_queries.max | 10000 | hash size (restart) |
| pg_stat_index_queries.save | on | persist across restart (v0.2) |

## 8. Overhead budget

- Target: < 1% TPS loss on `pgbench -S` (select-only), and < 2% on a schema with 20+ indexes per table.
- Cost per statement: one tree walk (cheap, plans are small) + one hash lookup per distinct index used.
- If over budget: sample (record 1 in N statements per queryid) behind a GUC.

## 9. Testing

pg_regress cases:
1. Simple index scan recorded with correct queryid.
2. Index-only scan.
3. Bitmap index scan (BitmapAnd/Or with two indexes).
4. Plan that includes an index scan never executed (e.g. LIMIT 0 / empty outer side) → planned but not executed.
5. Prepared statement executed 5 times → calls = 5.
6. PL/pgSQL function with track=top vs all.
7. Parallel index scan → counted once.
8. Partitioned table → child indexes mapped to parent in helper view.
9. Unused index appears in `pg_index_no_dependents`; PK/unique excluded.
10. Reset clears counters; info view shows reset time.
11. Hash full → eviction, dealloc increments, no crash.
12. Hot standby: extension works read-only on a replica.

Also: run under `--enable-cassert` builds, and fuzz with sqlsmith for crash safety.

## 10. Benchmark (publishable)

- pgbench scale 100, `-S` and default TPC-B-like, 3 runs × 5 min each, with and without the extension.
- Custom multi-tenant schema (orders, 20 indexes) with a mixed read workload.
- Report TPS, p50/p99 latency, shared memory used.
- Publish scripts + raw results in the repo.

## 11. Packaging and release

- PGXS `Makefile`, `.control` file, upgrade scripts (`--0.1--0.2.sql`).
- GitHub Actions: build + regress matrix for PG 15–18 on Ubuntu.
- Publish to PGXN; open a request for PGDG apt/yum packaging after 0.2.
- License: PostgreSQL License.
- README: what it answers, install, the safety warning on tracking windows, overhead numbers, limitations.

## 12. Milestones (~4 hrs/week weekdays + weekends)

| Week | Deliverable |
|---|---|
| 0 | Gap check: search PGXN + GitHub; ask once in Postgres Slack / pgsql-general whether something like this exists |
| 1 | Hooks + plan walker logging index OIDs with elog(DEBUG) |
| 2 | Shared hash, core view, reset |
| 3 | Helper views, parallel/partition handling, regress tests |
| 4 | Benchmark, README, v0.1 tag, PGXN, blog post on databasedeveloper.dev |

## 13. Content tie-ins

- Blog: "Before you drop that unused index" (problem page on databasedeveloper.dev).
- LinkedIn: replica-only index dependency story (lab reproduction).
- Collector: the consulting collector checks for the extension and uses it when present.

## 14. Before you start

- Check your employment contract's IP / outside-work clause covers publishing open source.
- Don't use employer code, schemas or data in tests or benchmarks.

---

# Other native extension ideas — gap check (12 Oct 2026)

Each idea was checked against PGXN, GitHub, PostgreSQL 18 and 19 core features, and pgsql-hackers patches.

| Rank | Extension | What already exists | Gap left | Verdict |
|---|---|---|---|---|
| 1 | **pg_stat_index_queries** (index → queries) | Per-index scan counts; `last_idx_scan` (PG 16). A hackers thread in Apr 2026 asked only for per-index recency. No PGXN extension found. | Which queries use each index: confirmed | **Build first** |
| 2 | **Lock-wait history** | PG 19 adds `pg_stat_lock`: counters per lock type only, no blocker, no events. `log_lock_waits` writes blockers to logs. pg_lock_tracer uses eBPF (outside the DB, needs root). pganalyze/postgres.ai poll externally. | In-database wait episodes with the root blocker and its query: confirmed | **Build (flagship)** |
| 3 | **Per-queryid guardrails** | pg_plan_filter blocks by plan cost (global/role). pg_hint_plan's hint table is keyed by query_id but only changes planner settings. CF #5595 (work_mem hook) is still "needs review". | Per-queryid `statement_timeout`, `work_mem`, or block, during an incident, without a deploy: confirmed | **Build (third)** |
| 4 | **Per-tenant workload stats** | `citus_stat_tenants`: needs Citus distributed tables, top 100 tenants, last 2 periods only, CPU + counts. | Plain Postgres has nothing: confirmed. Main design problem is tagging the tenant (`SET LOCAL app.tenant_id` or a SQL comment), which needs app changes | **Build later** |
| 5 | **Peak memory per query** | pgEdge `querymem` (Aug 2026): plan-time estimate, proof of concept. CF #5595: estimated work_mem in EXPLAIN. PG 17 EXPLAIN (MEMORY): planner memory only. | Measured memory per queryid: confirmed, but the allocator doesn't track peaks, so results are approximate | **Research spike only** |
| 6 | **pgvector HNSW inspector** | No inspection functions in pgvector. Issues #244, #785, #993 show users struggling with recall and graph repair. | Graph health and sampled-recall functions: confirmed, but tied to pgvector's on-disk format and a niche audience | **Optional; propose upstream first** |
| 7 | **Vacuum run history** | PG 18: total vacuum/analyze time per table. PG 19: `pg_stat_autovacuum_scores`. "Vacuum statistics" patch series (Jun 2026) under review for extended counters. Per-run details already go to the log via `log_autovacuum_min_duration`. | Narrow: structured per-run storage only, and no extension hook at vacuum end | **Skip** |

Still skip: plan-shape tracking (pg_stat_plans 2.0), wait sampling (pg_wait_sampling), columnar/analytics (pg_duckdb, pg_mooncake, Citus columnar), bloat estimation (pgstattuple).

**Final order:** pg_stat_index_queries → lock-wait history → per-queryid guardrails → per-tenant stats.

### Sources
- PG 19 new system views (pg_stat_lock, pg_stat_autovacuum_scores): https://clickhouse.com/blog/postgres-19-new-system-views
- pg_stat_lock commit: https://forger.sitiv.fr/open-dsi/postgres/commit/4019f725f5d4
- Index last-used proposal thread (Apr 2026): https://www.postgresql.org/message-id/CAA5RZ0vZ2d57-4SMd_fVyvCp05XL6eY%2BaWNEB2KVuAzbGp1_Hg%40mail.gmail.com
- pg_lock_tracer: https://jnidzwetzki.github.io/2023/01/11/trace-postgresql-locks-with-pg-lock-tracer.html
- pg_plan_filter: https://github.com/pgexperts/pg_plan_filter
- pg_hint_plan hint table: https://pg-hint-plan.readthedocs.io/en/master/hint_table.html
- CF #5595 work_mem patch: https://commitfest.postgresql.org/patch/5595
- citus_stat_tenants: https://www.citusdata.com/blog/2023/05/12/tenant-monitoring-in-citus-and-postgres-with-citus-stat-tenants/
- pgEdge querymem: https://www.pgedge.com/blog/lets-build-a-postgres-extension-for-estimating-memory-usage
- pgvector issue #244: https://github.com/pgvector/pgvector/issues/244
- pgvector issue #993: https://github.com/pgvector/pgvector/issues/993
- PG 18 vacuum timing columns: https://www.dbi-services.com/blog/postgresql-18-per-relation-statistics-for-autovacuum-and-autoanalyze/
- Vacuum statistics patch (Jun 2026): https://postgrespro.com/list/id/a611e91e-073d-49fe-aeb1-45d1a505b78f@yandex.ru
