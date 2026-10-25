# pg_stat_index_queries — PRD and Technical Spec

Version 0.2 draft · 19 Oct 2026 · Author: Kiran Sabne
Status: **0.1 built** (compiles on PG 16, 9/9 regression tests pass, ~0.4% pgbench overhead on a 2-vCPU container). This document covers 0.2 → 1.0.

---

## Part A — Product Requirements

### A1. One-line summary

Tells you **which queries use each index**, so you can drop, rebuild or replace an index knowing exactly what depends on it, and estimates what would happen to those queries if the index were gone.

### A2. The problem

- Postgres tells you how many times an index was scanned (`idx_scan`) and, since PG 16, when it was last used (`last_idx_scan`). It never tells you **which queries** used it.
- Teams drop "unused" indexes that a replica, a month-end job or one important endpoint depended on, and find out in production.
- Teams keep duplicate and overlapping indexes forever because nobody can prove which queries use which. That costs write throughput, memory and storage.
- Upgrades and migrations change indexes without knowing the blast radius.

### A3. What exists today (checked 12–19 Oct 2026)

| Tool | What it gives | Gap |
|---|---|---|
| `pg_stat_user_indexes` | Scan count; last scan time (PG 16+) | No query attribution |
| pg_stat_statements | Per-query stats | No index information |
| pg_qualstats | Predicates used in WHERE clauses | Not the index the planner actually chose |
| pg_stat_plans (pganalyze) | Plan text per query and plan | No index-centric view or counts; you'd grep plan text |
| HypoPG | Hypothetical indexes; can hide an index from the planner (`hypopg_hide_index`) | Answers "what if", not "who uses it today" |
| Paid tools (pganalyze etc.) | Sampled plans; may answer indirectly | Not open source; not verified |
| PGXN search | — | No extension found that tracks which queries use which index |
| pgsql-hackers (Apr 2026 thread) | Asked only for last-used recency | Per-query attribution not proposed |

**Gap:** an open-source way to see index → query dependencies, on self-hosted Postgres **and** on RDS/Aurora, plus a "what if I drop it" check.

### A4. Users and jobs

| User | Job |
|---|---|
| You (consultant) | Prove "this index is safe to drop" or "these 3 endpoints depend on it" in an audit |
| DBAs / platform engineers | Clean up unused and overlapping indexes safely |
| Teams upgrading Postgres | Know which queries depend on indexes being rebuilt or changed |
| Developers | See which queries a migration's index change affects |

### A5. Three ways it runs

| Edition | Where | How it knows | Accuracy |
|---|---|---|---|
| **Native extension** (built) | Self-hosted Postgres 15–18 | Walks the executed plan of every statement | Exact; distinguishes planned vs executed |
| **SQL edition: plan-text view** | Aurora (via `aurora_stat_plans`, Aurora PG 14.10 / 15.5+); self-hosted with pg_stat_plans | Reads index names from each captured plan's text | Approximate: counts calls per plan that names the index |
| **Drop-impact check** (SQL) | Anywhere with HypoPG and PG 16+ (RDS, Aurora, self-hosted) | Hides the index with HypoPG, re-plans each dependent query with `EXPLAIN (GENERIC_PLAN)`, compares cost | Estimate of plan changes, not measured latency |

RDS for PostgreSQL (non-Aurora) has no per-plan source, so only the drop-impact check works there, and you need the list of candidate queries from pg_stat_statements text.

### A6. Goals and non-goals

**Goals**
- G1. Native extension 1.0: persistence across restarts, partition roll-up, "sole access path" view, PG 15–18 CI.
- G2. SQL edition for Aurora and pg_stat_plans users.
- G3. `index_drop_impact(index)` using HypoPG + GENERIC_PLAN.
- G4. Overhead < 1% TPS on pgbench select-only and on a 20-index schema, published.

**Non-goals**
- No index recommendations (HypoPG, pg_qualstats, LLMs cover this).
- No plan storage (pg_stat_plans covers it).
- No automatic dropping of anything.
- No per-index timing (needs instrumentation; too expensive).

### A7. Success metrics

| Metric | Target |
|---|---|
| Overhead | < 1% TPS, published with scripts |
| Correctness | All regression tests pass on PG 15–18 in CI |
| Adoption | PGXN listing; ≥ 3 outside users or issues within 8 weeks of 1.0 |
| Business use | Used in every audit's index section; ≥ 1 published case ("dropped 14 indexes safely, write latency −X%") |

### A8. Prerequisites ("pre")

| # | Item |
|---|---|
| P1 | Employment contract: outside-work and IP clauses checked before publishing |
| P2 | Only synthetic schemas and data in tests, benchmarks and posts |
| P3 | GitHub home decided (personal vs DatabaseDeveloper org); name checked on PGXN |
| P4 | Benchmark hardware: a 4–8 vCPU machine for the published overhead numbers (a cloud VM for a few hours is fine) |
| P5 | Aurora test cluster for the SQL edition (smallest instance, stopped when idle) |
| P6 | HypoPG installed locally (and confirmed available on RDS/Aurora versions you test) |

### A9. After release ("post")

1. PGXN release; request PGDG packaging after 1.0.
2. Blog: "Before you drop that unused index" (problem page on databasedeveloper.dev) + benchmark write-up.
3. LinkedIn: the replica-only dependency story (lab reproduction).
4. Post on pgsql-general / Postgres Slack announcing it; ask for feedback.
5. Add to your audit collector: use the extension when installed, the SQL edition on Aurora.
6. About page: one line, "Author of pg_stat_index_queries: shows which queries depend on each index."
7. Maintenance: support each new PG major within 2 months of release.

### A10. Risks

| Risk | Mitigation |
|---|---|
| Overhead higher on wide schemas or very short queries | Benchmark early; add sampling GUC if > 1% |
| Executor internals change between versions (e.g. ExecutorRun signature in PG 18) | Version guards; CI matrix |
| Bitmap scans always counted "executed" | Documented; investigate a better signal in 0.3 |
| Plan-text parsing ambiguity (same index name in two schemas) | Resolve using the table name in the plan line; mark ambiguous |
| HypoPG `hide_index` or GENERIC_PLAN behaviour differs by version | Feature-detect; clear errors |
| Small audience (self-hosted only for native edition) | SQL edition + drop-impact cover managed Postgres |

---

## Part B — Technical Specification

### B1. Native extension (0.1 as built)

- **Loading:** `shared_preload_libraries`; refuses to track if not preloaded; calls `EnableQueryId()` so `compute_query_id = auto` works.
- **Hooks:** `ExecutorRun`, `ExecutorFinish`, `ProcessUtility` (nesting level only; `EXECUTE`/`PREPARE` don't count as nesting, as in pg_stat_statements), `ExecutorEnd` (capture), `shmem_request`, `shmem_startup`.
- **Capture:** at ExecutorEnd, skip parallel workers and queryid 0; walk the PlanState tree; collect index OIDs from IndexScan, IndexOnlyScan and BitmapIndexScan nodes; skip catalog indexes unless `track_catalog`; de-duplicate per statement (max 64).
- **Executed vs planned:** IndexScan/IndexOnlyScan begin their scan lazily on first fetch (verified in PG 16 and 18 source), so a non-NULL scan descriptor means it ran. BitmapIndexScan is always counted executed (approximation).
- **Storage:** shared hash keyed by (dbid, indexrelid, queryid, toplevel); entry has calls_executed, calls_planned, first_seen, last_seen and a spinlock. LWLock shared for lookups, exclusive for inserts. When full, evict the 5% least recently seen; count evictions.
- **SQL objects:** `pg_stat_index_queries` (raw), `pg_index_dependents`, `pg_index_no_dependents` (excludes PK/unique/constraint indexes, shows `tracked_since`), `pg_stat_index_queries_info`, `pg_stat_index_queries_reset()`.
- **GUCs:** `.max` (10000, restart), `.track` (top/all/none), `.track_catalog` (off).

### B2. 0.2 changes

**Persistence**
- On shutdown (`on_shmem_exit` in the postmaster, as pg_stat_statements does), write entries to `pg_stat/pg_stat_index_queries.stat` with a header (magic number, format version, PG major).
- On startup, load the file if the header matches; otherwise discard with a LOG message. Delete the file after loading so a crash doesn't reload stale data.
- GUC `.save` (on). Crash = counters lost since last clean shutdown (documented).

**Partition roll-up**
- New view `pg_index_dependents_rollup`: maps each child-partition index to its partitioned parent index via `pg_inherits` (recursively) and sums calls per (parent index, queryid).

**Eviction test**
- Second regression config with `.max = 100`; generate 150 distinct queries; assert `dealloc > 0` and no crash.

### B3. 0.3 changes

**Sole access path view** (`pg_index_sole_path`)
- For each (queryid, table), count distinct indexes recorded. If exactly one and it's index X, the query has no other recorded index path on that table: dropping X is high risk for that query.
- Columns: index, table, queryid, calls_executed, last_seen, risk (`high` sole path / `medium` other index also used / `low` only planned, never executed).

**Sampling GUC** (only if benchmarks need it): `.sample_rate` 0.0–1.0, applied per statement; counts scaled and marked as sampled.

### B4. SQL edition (Aurora and pg_stat_plans users)

Packaged as plain SQL (installable as a normal extension self-hosted, or with pg_tle / a plain script on Aurora).

```sql
-- Source rows: (queryid, planid, calls, plan_text)
--   Aurora:  aurora_stat_plans(true)         -- needs aurora_compute_plan_id = on
--   Self-hosted: pg_stat_plans               -- pganalyze extension
CREATE VIEW siq.plan_index_usage AS
SELECT p.queryid, p.planid, p.calls,
       m[2] AS index_name, m[3] AS table_name,
       CASE WHEN m[1] LIKE 'Bitmap%' THEN 'bitmap'
            WHEN m[1] LIKE 'Index Only%' THEN 'index_only'
            ELSE 'index' END AS scan_type
  FROM siq.plan_source() p,
       LATERAL regexp_matches(
         p.plan_text,
         '(Index Only Scan|Index Scan|Bitmap Index Scan)(?: Backward)? (?:using|on) ([^ ]+)(?: on ([^ ]+))?',
         'g') AS m;
```

- `siq.plan_source()` picks the available source at runtime (`to_regprocedure('aurora_stat_plans(boolean)')`, then `to_regclass('pg_stat_plans')`).
- Resolve `index_name` to an OID using the table name on the same plan line (Bitmap Index Scan lines show only the index name: resolve via the parent Bitmap Heap Scan line, or mark ambiguous if the name exists in several schemas).
- Views mirror the native ones: `siq.index_dependents`, `siq.index_no_dependents` (with the caveat that only queries with captured plans are seen).
- **Caveats shown in output:** counts are calls per plan that names the index, not confirmed executions; Aurora plans may be `estimate` rather than `actual`; queries evicted from pg_stat_statements are missing.

### B5. Drop-impact check (SQL, PG 16+ with HypoPG)

```sql
SELECT queryid, calls, cost_with, cost_without, cost_ratio, plan_changed, uses_index_after, note
  FROM siq.index_drop_impact('public.orders_customer_id_idx'::regclass);
-- queryid | calls | cost_with | cost_without | ratio | plan_changed | uses_index_after | note
```

Algorithm:
1. Candidate queries: from native or SQL edition dependents; if neither is installed, from pg_stat_statements rows whose query text references the index's table.
2. For each query text (normalized with `$1…`): `EXPLAIN (GENERIC_PLAN, FORMAT JSON)` → baseline cost and whether the index appears.
3. `hypopg_hide_index(oid)` (session-local, doesn't affect others) → EXPLAIN again → new cost and plan.
4. `hypopg_unhide_all_indexes()` in a `finally` block.
5. Report cost ratio and plan change; sort by `calls × (cost_without − cost_with)`.

Safety: read-only; runs in the caller's session; statement_timeout per EXPLAIN (default 2 s); skips non-SELECT statements unless `include_dml => true` (EXPLAIN only, never executes).
Limits: generic-plan costs, not measured latency; queries whose text was truncated or that use temp tables are skipped and listed.

### B6. Repository layout

```
pg_stat_index_queries/
  pg_stat_index_queries.c        # native extension
  pg_stat_index_queries--0.1.sql
  pg_stat_index_queries--0.1--0.2.sql
  sql/ expected/ test/            # regression tests, configs (normal + small-max)
  sql_edition/                    # siq schema: plan_source, views, drop_impact
    siq--1.0.sql
    install_pg_tle.sql            # for RDS/Aurora
    tests/                        # pgTAP or plain SQL tests
  bench/                          # pgbench scripts, wide-schema benchmark, results
  docs/
  .github/workflows/ci.yml        # PG 15–18 native; PG 16–18 SQL edition with HypoPG
```

### B7. Testing

**Native:** the existing 9 cases, plus persistence (restart keeps counters; mismatched header discards), partition roll-up, eviction under small `.max`, `track = all` inside functions, standby (works read-only on a replica), crash safety under `--enable-cassert` builds, sqlsmith fuzzing for crashes.

**SQL edition:** fixtures with captured plan text for each scan type (including Backward, Index Only, Bitmap Or/And, partitioned, schema-qualified names); a run on a real Aurora test cluster.

**Drop-impact:** an index that is the only path for a query (cost jumps, plan changes); an index with an alternative (small change); unhide always runs even when an EXPLAIN errors.

### B8. Benchmarks (published)

| Workload | Runs | Measure |
|---|---|---|
| pgbench `-S -M prepared`, scale 100 | 3 × 5 min, with/without | TPS, p50/p99 |
| pgbench default (TPC-B-like) | same | same |
| Wide schema: orders table with 20 indexes, mixed reads | same | same + shared memory used |

Machine: 4–8 vCPU, stated in results; scripts and raw output in `bench/`.

### B9. What must work (acceptance criteria)

| Area | Must work |
|---|---|
| Correctness | Every regression test passes on PG 15–18 |
| Persistence | Counters survive a clean restart; stale or mismatched files are discarded safely |
| Overhead | < 1% TPS on all three benchmark workloads |
| Safety | Never errors a user query; on any internal failure it logs and skips tracking for that statement |
| SQL edition | Same top-10 dependents as the native extension on a shared test workload (self-hosted with pg_stat_plans) |
| Drop-impact | Never leaves an index hidden; never executes a query |

### B10. Milestones (~2 h/week of the 4 h budget)

| Weeks | Deliverable |
|---|---|
| 1 | Push to private GitHub; CI confirms PG 15/17/18 |
| 2–3 | 0.2: persistence, partition roll-up, eviction test |
| 4 | Benchmarks on a 4–8 vCPU VM; README numbers |
| 5–6 | SQL edition (pg_stat_plans source first, then Aurora) |
| 7–8 | Drop-impact check; Aurora test run |
| 9 | Public release 0.2 + SQL edition 1.0; blog post; PGXN |
| later | 0.3 sole-path view; PGDG packaging request |

---

## Part C — Open questions

1. Support PG 15–18, or 16+ only? (16+ halves the test matrix and is required for drop-impact anyway.)
2. Is persistence needed before the first public release, or can 0.1 go out marked "experimental, counters reset on restart"?
3. Personal GitHub or a DatabaseDeveloper org?
4. Ship the SQL edition and drop-impact inside this repo, or as a separate project (simpler to install on Aurora)?
5. Do you want pgTAP for the SQL-edition tests, or plain SQL scripts?
6. Has the employment-contract check happened?

## Sources

- aurora_stat_plans: https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora_stat_plans.html
- pg_stat_plans: https://github.com/pganalyze/pg_stat_plans
- pgsql-hackers index last-used thread (Apr 2026): https://www.postgresql.org/message-id/CAA5RZ0vZ2d57-4SMd_fVyvCp05XL6eY%2BaWNEB2KVuAzbGp1_Hg%40mail.gmail.com
- HypoPG: https://github.com/HypoPG/hypopg
