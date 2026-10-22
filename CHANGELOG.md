# Changelog

## Unreleased
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
