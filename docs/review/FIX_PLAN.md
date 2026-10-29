# Fix plan: 28–29 Oct 2026 review

Status of every finding in `REVIEW_FINDINGS.md`, and what is still to do before native 0.10.1 / SQL edition 0.8 are tagged.

## Done (merged to main)

| Findings | Change | Where |
|---|---|---|
| N9, N10, N11 | Counters: earliest first_seen, saturating adds, stricter stats-file loading | `6793c5e` |
| N1, N2 | Publish new pairs at once; reset epoch | `a1d006d` |
| N3, N4 | Plan walk: no 64-index cap; bitmap planned-only (PG 17+) | `dabd85a` |
| N5, N6 | ALTER COLUMN TYPE history; non-blocking definition reads | `d8e70fe` |
| N12 | Readers copy under the lock | `ffc7541` |
| N6, N7, N8, N11 | Review round 1: capture scope, `indexdef_nowait`, known-pair recheck, loader note | `d0f7ff8` |
| N13, review round 2 | Out-of-order first_seen test, SET EXPRESSION test, docs, CHANGELOG | `6f76244` |
| S1–S4 | SQL edition 0.8 security fixes | `c7473e7`, `df403d6` |
| S5, S6 | Lab findings in 0.8: HypoPG check after `format()`, inaccessible extension objects | branch `review-deliverables` (unreleased 0.8 scripts fixed in place) |

Each change has a regression or TAP test; native regression 13/13 and TAP pass on PG 15–18, SQL edition 9/9 on PG 16–18, CI 7/7 on main.

## Before tagging

| # | Item | Needs | Why |
|---|---|---|---|
| R1 | ~~Sanitizer + stress rerun on the merged code (assert + ASan/UBSan, PG 15/17/18), with ALTER COLUMN TYPE added to the noise loop~~ **Done 29 Oct**: NO FINDINGS on all three (TESTING.md) | Docker | N5–N8 add new concurrent paths; the last stress round predates them |
| R2 | ~~Validation lab, Docker PG 16–18~~ **Done 29 Oct**: first run found S5 and S6; after the fix 193 PASS / 0 FAIL / 5 KNOWN on PG 16, 17, 18, and RDS mode (PG 17) 113 / 0 / 2 | Docker | `index_drop_impact` changed (S1–S3); the lab's drop-impact and error-path checks must still pass |
| R3 | Aurora: `resolved_plan_source()` still returns `aurora_stat_plans` | AWS (lab-aws.sh) | `ext_function(NULL, 'aurora_stat_plans', …)` accepts pg_catalog or any extension member; where Aurora puts the function was not checked |
| R4 | Benchmark 0.10.1 against 0.10, same instance, `--runs 10`: `select_only`, `wide`, plus a workload with many new (index, query) pairs per second | EC2 + `aws login` | N1 adds a shared-memory write for every new pair and N8 a recheck; steady-state cost should not change, high-cardinality workloads may |
| R5 | Concurrency load, 32–128 clients, main vs 0.10 | EC2 | Reviewer request; N12 should help readers under contention |
| R6 | Tag `v0.10.1` (native 0.10.1, SQL edition 0.8), GitHub Release | Maintainer | See `RELEASE_CHECKLIST.md` |

## Follow-ups (not blocking)

| # | Item | Trigger |
|---|---|---|
| F1 | Table-scoped lookup for the ALTER capture instead of scanning every entry (~0.1 ms per 1,000 entries, part of it under the exclusive lock in `reindex_rekey`) | A profile on a real DDL-heavy workload showing it matters |
| F2 | Counter for skipped history transfers (busy lock, definition differs, statement adds/drops constraints) | Users asking why a rebuilt index shows no history |
| F3 | Deterministic test of the known-pair race window itself | Injection points available in the test build |
| F4 | Duplicate-key check for stats-file records past `max` | Only if files from other sources are ever loaded |
