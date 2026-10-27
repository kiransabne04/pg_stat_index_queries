# Roadmap

| Version | Items | Gate |
|---|---|---|
| 0.2 | Persistence, partition roll-up, eviction/crash tests, SQL edition with drop-impact | CI green on PG 15–18 (done) |
| 0.3 / SQL edition 0.2 | Partition-aware and no-plan-source fixes to the "no dependents" views; drop-impact handles typed literals, PREPARE and partial indexes; pg_tle upgrades | Tests pass on PG 15–18 (done) |
| 0.4 / SQL edition 0.3 | `pg_index_query_stats` / `index_query_stats`: per (index, query) debugging view with pg_stat_statements stats | Tests pass on PG 15–18 (done) |
| 0.4.1 | Benchmarks on a 4–8 vCPU VM (pgbench -S, TPC-B, 20-index schema); README numbers | **Done 24 Oct 2026**: −3.4% `select_only`, −2.9% `wide`, noise on `tpcb`; above the 1% target |
| 0.5 / SQL edition 0.4 | Index roles and per-index verdicts; drop-impact fixes from the lab; validated on Aurora 17.9 (writer + reader) and RDS 17.11 | Done 24 Oct 2026 |
| 0.6 (this) | Backend-local batching + sampling GUC (T04) | Done 25 Oct 2026: `select_only` −3.4% → −1.8%, `wide` −2.9% → −0.9% |
| 0.6.1 | Benchmark `sample_rate` 0.1; profile the hooks and plan walk (`perf`) | **Done 26 Oct 2026**: profile shows the extension at ~0.7% of CPU on `select_only`; `sample_rate` 0.1 gave no measurable gain (noise-bound). `--runs 10` run (27 Oct 2026, 0.9): `select_only` −3.3%, `wide` −2.9%, real (10/10 runs); < 1% **not** reached |
| SQL edition 0.5 | Column lists instead of `SELECT *` in its functions and views | Done 26 Oct 2026 |
| 0.7 / SQL edition 0.6 | **Table and column statistics behind each index (T08)**: row counts, size, write rate and HOT %, staleness; per key column n_distinct, null fraction, MCVs and skew, histogram, correlation, extended statistics; hints in verdicts and drop impact | **Done 26 Oct 2026** (unreleased): tests pass on PG 15–18; lab 0 FAIL on PG 16–18 |
| 0.8 | **Index column usage per query (T07)**: `cond_columns` / `order_columns` per (index, query), `pg_index_column_usage` | Done 26 Oct 2026: tests pass on PG 15–18; benchmark 0.7 vs 0.8 on one instance shows no added cost (`select_only` −3.4% both, `wide` −4.6% → −2.1%, all within noise) |
| 0.9 | `pg_index_sole_path` (T02): per (index, query) risk `high` / `medium` / `low` | Tests pass on PG 15–18 (26 Oct 2026, unreleased) |
| 0.9.1 | **Periodic saves (T09)**: `save_interval` (default 300 s), background worker; a crash loses minutes, not the whole window. **History kept across `REINDEX CONCURRENTLY` (T10)** | Tests pass on PG 15–18 (27 Oct 2026, unreleased) |
| later | Find the ~3% on tiny read-only statements: `perf stat` (IPC, cache misses), `track = none` vs off to split hook cost from recording | Only if users report it matters |
| later | PGXN release, PGDG packaging request | Outside users exist |

Stop rule: if 8 weeks after the public release there are no outside users, issues or mentions, stop adding features and keep it as private audit tooling.
