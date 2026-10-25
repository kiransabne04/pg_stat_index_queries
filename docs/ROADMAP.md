# Roadmap

| Version | Items | Gate |
|---|---|---|
| 0.2 | Persistence, partition roll-up, eviction/crash tests, SQL edition with drop-impact | CI green on PG 15–18 (done) |
| 0.3 / SQL edition 0.2 | Partition-aware and no-plan-source fixes to the "no dependents" views; drop-impact handles typed literals, PREPARE and partial indexes; pg_tle upgrades | Tests pass on PG 15–18 (done) |
| 0.4 / SQL edition 0.3 (this) | `pg_index_query_stats` / `index_query_stats`: per (index, query) debugging view with pg_stat_statements stats | Tests pass on PG 15–18 (done) |
| 0.4.1 | Benchmarks on a 4–8 vCPU VM (pgbench -S, TPC-B, 20-index schema); README numbers | **Done 24 Oct 2026**: −3.4% `select_only`, −2.9% `wide`, noise on `tpcb`; above the 1% target |
| SQL edition 0.4 | Validate on a live Aurora cluster; real `aurora_stat_plans` fixture in tests | Runs on Aurora |
| 0.5 | `pg_index_sole_path` view (queries with no other recorded index on the table) | Someone asks for it |
| 0.5 | Index column usage per query (T07) | After benchmarks |
| 0.6 | Backend-local batching + sampling GUC (T04) | Done 25 Oct 2026; benchmark rerun pending |
| later | PGXN release, PGDG packaging request | Outside users exist |

Stop rule: if 8 weeks after the public release there are no outside users, issues or mentions, stop adding features and keep it as private audit tooling.
