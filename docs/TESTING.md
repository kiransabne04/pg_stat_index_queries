# Testing

## Suites

| Command | What it covers |
|---|---|
| `make installcheck` | `sql/basic.sql`: index scan, index-only, bitmap, planned-not-executed, prepared statements, nesting (top vs all), helper views, catalog filter, reset · `sql/partitions.sql`: partition roll-up · `sql/upgrade.sql`: 0.1 → 0.2 · `t/001_persistence.pl`: survives clean restart, `save = off`, corrupt file ignored and reported, **real crash** (process killed) doesn't reload stale counters · `t/002_eviction.pl`: `max = 100` with 150 indexes, dealloc counted, newest kept |
| `make -C sql_edition installcheck` | `parse`: fixture plans incl. Backward, Index Only, BitmapOr, quoted names, same-name index in two schemas (ambiguous) · `dependents`: live pg_stat_plans · `drop_impact`: cost/plan change, index never left hidden, broken query skipped cleanly, DML skipped, error on non-index |
| `./bench/run.sh` | pgbench overhead with/without the extension |

All suites start their own temporary server, so they don't touch any existing cluster. Run them as a non-root user. The regression instances run with `--no-locale` (`NO_LOCALE = 1` in both Makefiles) so `ORDER BY` on names sorts the same on every machine.

Tests that read pg_stat_plans call counts must run `SELECT pg_stat_force_next_flush();` first: pg_stat_plans uses the cumulative statistics system, which flushes counters lazily.

## Verified so far (22 Oct 2026)

| Item | Status |
|---|---|
| Native build, warning-free, PG 16.15 | Verified |
| All native regression + TAP tests, PG 16 | Pass |
| SQL edition tests with pg_stat_plans 2.1 + HypoPG 1.4, PG 16 | Pass |
| Plain `install.sql` without CREATE EXTENSION | Verified on PG 16 |
| Overhead (pgbench -S, 2 vCPU container) | −0.4%, within noise |
| Native build (`COPT=-Werror`) + regression + TAP, PG 15.19, 16.15, 17.11, 18.6 | Pass (Docker, Debian PGDG images, arm64) |
| SQL edition tests, PG 16, 17, 18 (pg_stat_plans 2.1 + HypoPG 1.4.3) | Pass (Docker, arm64). PG 15 skipped by design |
| GitHub Actions CI workflow | **Not yet run** on GitHub |
| `aurora_stat_plans` adapter | **Not yet run on Aurora**: column names taken from AWS docs |
| `install_pg_tle.sql` | Verified with pg_tle built from source (aws/pg_tle main, Oct 2026), extension files removed from disk |
| Drop-impact fallback with no plan source (RDS-like) | Verified: candidates from query text, index use before/after correct |
| Docker image (test runner + playground) | Built and run on macOS arm64, PG 15–18 |

## Updating expected output

1. Run the suite; look at `results/*.out` and `regression.diffs`.
2. Read every changed line and confirm it's correct.
3. Copy the reviewed file to `expected/`. Never hand-edit expected files.

Version differences: if a PG version produces different but correct output, add an alternative expected file (`expected/basic_1.out`); pg_regress accepts either.
