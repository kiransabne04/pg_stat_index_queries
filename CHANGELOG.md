# Changelog

## Unreleased
- **Native 0.6 (T04): lower overhead.** Each session now counts in its own memory and moves the counts to shared memory about once a second (`pg_stat_index_queries.flush_interval`, default 1 s; also on disconnect, and before the session reads the counters itself), instead of taking the shared lock on every statement. The counts stay exact; other sessions see them up to `flush_interval` late. `flush_interval = 0` restores the old behaviour.
- **Native 0.6: `pg_stat_index_queries.sample_rate`** (default 1.0) records only that fraction of statements and scales the counts. `pg_stat_index_queries_sampled()` says whether sampling skipped anything since the last reset; `pg_index_usage` then reports unused indexes as "unknown" and marks counts as estimated.
- Native 0.6: saved-stats file format 2 (adds the sampled flag); 0.5 files are still read. Upgrade: new build, restart, `ALTER EXTENSION ... UPDATE TO '0.6'`. New tests: `sampling` (regression) and `003_flush` (TAP: lag across sessions, flush on disconnect).
- **T03 benchmark (publishable):** AWS c7gd.xlarge, PG 17.11, scale 100, 3 × 300 s per mode: `select_only` −3.4%, `wide` −2.9%, `tpcb` +1.7% (noise). Above the 1% target, so T04 (sampling setting) is next. The README "Overhead" section now shows these numbers instead of the early 2-vCPU result. `bench/aws-ec2.sh` now never waits on SSH input (`-n`, keepalive, detached run).
- `bench/aws-ec2.sh`: up / push / run / status / fetch / down for the publishable benchmark (T03) on a dedicated EC2 instance (default `c7gd.xlarge`, local NVMe). Not run yet: the free-plan account only allows 2-vCPU free-tier instance types.
- **T05: verified on AWS** (24 Oct 2026, ap-southeast-2). Aurora PostgreSQL 17.9.5 in express configuration, with the pg_tle install: 115 PASS, 0 FAIL. RDS for PostgreSQL 17.11: 33 PASS, 0 FAIL. Reports are in `docs/validation/`. Real Aurora plan text was added to the `parse` test. Reader phase also run (express cluster + reader): attribution is per instance, and drop impact works on the reader.
- Found on Aurora: a pg_tle install needs `GRANT pgtle_admin TO CURRENT_USER` (INSTALL.md and the lab runner now do this). The lab supports free-plan accounts: `LAB_AURORA_EXPRESS=1` and IAM-token connections (`PGPASSWORD_CMD`, refreshed before each connection).
- **Native 0.5** (upgrade script 0.4 → 0.5; tests pass on PG 15–18, TAP included): `pg_index_role(regclass)` (role, notes, drop blocker, same as the SQL edition), `pg_index_usage` (one row per index with a verdict; "unknown" when entries were evicted), `index_role` column in `pg_index_dependents`, and `index_role` and `index_notes` in `pg_index_query_stats`. A new upgrade test checks that the upgraded objects are identical to a fresh install (in both editions).
- **Index lab:** new cases for a UNIQUE constraint lookup (W41) and an EXCLUDE constraint (W42), plus role and verdict checks. After the fixes, Docker PG 16–18: 0 FAIL in both modes; the reader rehearsal runs drop impact without error.
- **SQL edition 0.4** (upgrade script 0.3 → 0.4; installers regenerated; regression tests pass on PG 16–18):
  - **Fix:** if `index_drop_impact` was cancelled (statement_timeout, pg_cancel_backend) while the index was hidden, the index stayed hidden for the rest of the session. It is now unhidden on cancel, and the error is re-raised.
  - **Fix:** `index_drop_impact` now works in read-only transactions (Aurora readers, hot standbys); the temp table is gone.
  - **Fix:** roles without superuser got `permission denied for table config` from every view. `index_deps.config` is now readable by PUBLIC.
  - **Fix:** queries whose text starts with a comment were skipped as "not a read query"; leading comments are now stripped.
  - **Change:** `p_timeout_ms` is now a time budget for the whole call (default 30 s). The old per-statement timeout never took effect.
  - `index_drop_impact` warns when the plans use a HypoPG hypothetical index, and has a new column `drop_blocker`.
  - **New:** `index_deps.index_role(regclass)` gives the index's role (primary key, unique constraint, exclusion constraint, unique index, index), notes (referenced by foreign keys, replica identity, clustered, invalid, partial, expression, partition) and what blocks a drop. `index_dependents` and `index_query_stats` show the role.
  - **New:** `index_deps.index_usage`, one row per index with a verdict. **New:** `index_deps.unresolved_plan_indexes`, index names in plans that no longer exist. `index_no_dependents` now leaves out indexes on tables whose plans name a missing index (renamed or dropped), because the renamed index may be one of them.
- **Index lab** (`sql_edition/validation/lab/`): end-to-end validation on a synthetic workload. It covers 40 cases, 73 indexes and about 100 checks (170 with the native ground-truth checks): attribution against EXPLAIN ground truth (and the native extension where available), unused-index listing, `index_query_stats`, drop impact and error paths. It writes a markdown report with PASS / FAIL / KNOWN, feedback and plan fixtures. It runs on Docker, Aurora (writer + reader phase) and RDS, with simulated RDS mode.
- `sql_edition/validation/lab/aws/lab-aws.sh`: preflight / up / run / status / down for the Aurora + RDS validation (T05), plus a least-privilege IAM policy. `docs/AURORA-VALIDATION.md` rewritten as a run sheet.
- Docker lab runs on PG 16–18 found six SQL edition issues, listed in `docs/TESTING.md` (most serious: an index stays hidden in the session after a cancelled `index_drop_impact`, and drop impact fails in read-only transactions). Not fixed yet.

## 0.4 (2026-10-23): native 0.4, SQL edition pg_index_deps 0.3
- **New (0.4):** `pg_index_query_stats` view: each (index, query) with what a developer needs to debug it: index definition, size, unique/partial, calls through the index, `pct_calls_using_index`, `other_indexes` the query used, and the query's pg_stat_statements statistics (exec and plan times, rows per call, buffers and cache hit %, temp blocks, I/O time, WAL bytes, roles, query text). pg_stat_statements is looked up when queried, not at install time. Upgrade script 0.3 → 0.4.
- **New (SQL edition 0.3):** `index_deps.index_query_stats`, the same over captured plans, plus scan types and plan source. Upgrade script 0.2 → 0.3; installers regenerated.
- Native regression instance now preloads pg_stat_statements (`test/pg.conf`).
- `examples/playground.sql` shows both new views.

## 0.3 (2026-10-23): native 0.3, SQL edition pg_index_deps 0.2
- **Fix (0.3):** `pg_index_no_dependents` listed a partitioned (parent) index as unused even when its partition indexes were used, so it looked safe to drop. Now a parent index counts as used if any index in its partition tree was used, its size is the whole tree, and attached partition indexes aren't listed separately.
- **Fix (SQL edition 0.2):** `index_drop_impact` skipped queries with typed literals (`interval '1 day'` is stored by pg_stat_statements as `interval $4`, a syntax error) and prepared statements (stored as `PREPARE … AS …`, reported as "not a read query"). New `index_deps.explainable_query()` rewrites both before EXPLAIN.
- **Fix (SQL edition 0.2):** `index_drop_impact` reported "plan unchanged" for queries that use a partial index. pg_stat_statements stores `status = 'open'` as `status = $1`, so the generic plan can't match the index predicate and never uses the index, making it look safe to drop. Now, when the generic plan doesn't use the index but recorded plans of the query did, or the index is partial with a constant in its predicate, `plan_changed` is NULL and `note` starts with `unknown:`.
- **Fix (SQL edition 0.2):** `install_pg_tle.sql` can now upgrade an existing pg_tle install (registers update paths and the new default version; then `ALTER EXTENSION pg_index_deps UPDATE`). Generated by `sql_edition/gen_pg_tle.sh`.
- **Fix (SQL edition 0.2):** `index_deps.index_no_dependents` listed every non-unique index when there is no plan source (RDS). It now returns no rows then, and has the same partition handling as the native view.
- Build fix for PostgreSQL 15: `queryjumble.h` is under `utils/` before 16.
- Tests: regression instances run with `--no-locale`, so name ordering no longer depends on the machine's locale (SQL edition `parse` failed under `en_US.utf8`).
- Tests: SQL edition `dependents` forces a stats flush before checking pg_stat_plans call counts (failed intermittently, seen on PG 18).
- Docker: verified on PG 15–18 (arm64); build with `-Werror`, per-version image tags, `.dockerignore`, fast edit/test loop in `docker/README.md`.
- `scripts/ci-local.sh`: run the GitHub Actions jobs locally in Docker, using the steps from `ci.yml`.
- T05 prep: `sql_edition/validation/managed_check.sql` and `docs/AURORA-VALIDATION.md` for validating the SQL edition on Aurora and RDS.
- Benchmark: `bench/run.sh` interleaves off/on runs, verifies the mode, checkpoints before each run, reports spread; `--label`, `--note`, `--out`. Plan in `docs/BENCHMARK.md`.
- `examples/playground.sql`: rerunnable smoke test on synthetic data for both extensions.
- Docs: native macOS (Homebrew) build and test instructions; Homebrew skips TAP tests silently unless forced. `.gitignore` covers `*.dylib`.

## 0.2 (2026-10-21)
- Counters persist across clean restarts (`pg_stat_index_queries.save`, default on); invalid files are ignored and reported.
- New view `pg_index_dependents_rollup` for partitioned tables.
- Upgrade script 0.1 → 0.2.
- TAP tests: persistence (including a real crash) and eviction.
- New SQL edition `pg_index_deps` (`sql_edition/`): dependency views from captured plans (aurora_stat_plans, pg_stat_plans) and `index_drop_impact()` using HypoPG + EXPLAIN (GENERIC_PLAN). Plain and pg_tle installers for RDS/Aurora.

## 0.1 (2026-10-15)
- Executor hooks record which query IDs use each index, planned vs executed.
- Views: `pg_stat_index_queries`, `pg_index_dependents`, `pg_index_no_dependents`, `pg_stat_index_queries_info`.
