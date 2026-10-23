# Roadmap

| Version | Items | Gate |
|---|---|---|
| 0.2 | Persistence, partition roll-up, eviction/crash tests, SQL edition with drop-impact | CI green on PG 15–18 (done) |
| 0.3 / SQL edition 0.2 (this) | Partition-aware and no-plan-source fixes to the "no dependents" views; drop-impact handles typed literals, PREPARE and partial indexes; pg_tle upgrades | Tests pass on PG 15–18 (done) |
| 0.3.1 | Benchmarks on a 4–8 vCPU VM (pgbench -S, TPC-B, 20-index schema); README numbers | Overhead < 1% |
| SQL edition 0.3 | Validate on a live Aurora cluster; real `aurora_stat_plans` fixture in tests | Runs on Aurora |
| 0.4 | `pg_index_sole_path` view (queries with no other recorded index on the table) | Someone asks for it |
| 0.4 | Index column usage per query (T07) | After benchmarks |
| 0.4 | Sampling GUC | Only if benchmarks show > 1% |
| later | PGXN release, PGDG packaging request | Outside users exist |

Stop rule: if 8 weeks after the public release there are no outside users, issues or mentions, stop adding features and keep it as private audit tooling.
