# Testing

## Suites

| Command | What it covers |
|---|---|
| `make installcheck` | `sql/basic.sql`: index scan, index-only, bitmap, planned-not-executed, prepared statements, nesting (top vs all), helper views, catalog filter, reset · `sql/partitions.sql`: partition roll-up · `sql/upgrade.sql`: 0.1 → 0.2 · `t/001_persistence.pl`: survives clean restart, `save = off`, corrupt file ignored and reported, **real crash** (process killed) doesn't reload stale counters · `t/002_eviction.pl`: `max = 100` with 150 indexes, dealloc counted, newest kept |
| `make -C sql_edition installcheck` | `parse`: fixture plans incl. Backward, Index Only, BitmapOr, quoted names, same-name index in two schemas (ambiguous) · `dependents`: live pg_stat_plans · `drop_impact`: cost/plan change, index never left hidden, broken query skipped cleanly, DML skipped, error on non-index, typed literals (`interval $1`) and `PREPARE` texts rewritten so they can be EXPLAINed, partial index with a constant predicate reported as unknown (not "unchanged"), `IS NULL` partial index estimated normally, both again with no plan source (text-match candidates) · `upgrade`: 0.1 → 0.2 |
| `./bench/run.sh` | pgbench overhead with/without the extension |

All suites start their own temporary server, so they don't touch any existing cluster. Run them as a non-root user. The regression instances run with `--no-locale` (`NO_LOCALE = 1` in both Makefiles) so `ORDER BY` on names sorts the same on every machine.

Tests that read pg_stat_plans call counts must run `SELECT pg_stat_force_next_flush();` first: pg_stat_plans uses the cumulative statistics system, which flushes counters lazily.

## Running CI locally

`scripts/ci-local.sh` runs the jobs of `.github/workflows/ci.yml` in Docker without GitHub or `act`. Each job gets a clean `ubuntu:24.04` container (linux/amd64 by default, like GitHub's runners), a fresh clone of the committed HEAD, and the workflow's own `run:` steps (read from the YAML by `scripts/ci_steps.py`), executed as a non-root user with sudo.

```bash
scripts/ci-local.sh                            # all 7 jobs (native 15-18, sql-edition 16-18)
scripts/ci-local.sh sql-edition 18             # one job
CI_WORKTREE=1 scripts/ci-local.sh native 18    # include uncommitted changes
CI_PLATFORM=linux/arm64 scripts/ci-local.sh    # skip amd64 emulation on Apple Silicon
```

Logs go to `ci-local-logs/`. Under amd64 emulation on Apple Silicon a job takes about 2–4 minutes.

## Native build on macOS (Homebrew)

Docker (`docker/README.md`) is the supported path; this is only for quick C edit/compile cycles. Verified on macOS 26 arm64 with Homebrew `postgresql@17` 17.11 and Apple clang 21: build warning-free with `-Werror`, regression and TAP tests pass. The SQL edition is not set up natively (it needs pg_stat_plans and HypoPG built from source); use Docker for it.

```bash
brew install postgresql@17          # keg-only, doesn't change PATH
PGC=/opt/homebrew/opt/postgresql@17/bin/pg_config
make PG_CONFIG=$PGC COPT=-Werror && make PG_CONFIG=$PGC install
make PG_CONFIG=$PGC installcheck    # regression only, see below
```

Homebrew's PostgreSQL is configured without `--enable-tap-tests` and doesn't ship `src/test/perl`, so plain `make installcheck` **skips the TAP tests silently** (it prints "TAP tests not enabled" and still exits 0). To run them, get the Perl test modules from the source tarball of the same version and IPC::Run from CPAN, unpack them anywhere outside the repo, and pass both in:

```bash
# from https://ftp.postgresql.org/pub/source/v17.11/postgresql-17.11.tar.bz2 (check the .sha256)
#   tar -xjf postgresql-17.11.tar.bz2 postgresql-17.11/src/test/perl
# from https://cpan.metacpan.org/authors/id/T/TO/TODDR/IPC-Run-20260402.0.tar.gz
PERL5LIB=/path/to/IPC-Run-20260402.0/lib \
make installcheck PG_CONFIG=$PGC enable_tap_tests=yes PROVE=prove \
  PROVE_FLAGS="-I /path/to/postgresql-17.11/src/test/perl"
```

Expect `t/001_persistence.pl .. ok`, `t/002_eviction.pl ..... ok` and `Result: PASS`; if those lines are missing, TAP didn't run.

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
| Native build + regression + TAP on macOS arm64, Homebrew PG 17.11 (clang 21, `-Werror`) | Pass |
| CI workflow, all 7 jobs (native 15–18, sql-edition 16–18) | Pass locally via `scripts/ci-local.sh` (ubuntu:24.04, linux/amd64, PGDG). **Not yet run on GitHub** |
| `aurora_stat_plans` adapter | **Not yet run on Aurora**: column names taken from AWS docs |
| `sql_edition/validation/managed_check.sql` (T05 script) | Dry-run on PG 17 playground: self-hosted path and RDS path (`-v simulate_rds=1`). Aurora/RDS runs pending, see [AURORA-VALIDATION.md](AURORA-VALIDATION.md) |
| `install_pg_tle.sql` | Verified with pg_tle built from source (aws/pg_tle main, Oct 2026), extension files removed from disk. 0.2 (22 Oct, pg_tle 6340fd2, PG 16): fresh install; upgrade of a 0.1 pg_tle install via the new file + `ALTER EXTENSION UPDATE` (config kept); file rerun is harmless |
| Drop-impact fallback with no plan source (RDS-like) | Verified: candidates from query text, index use before/after correct |
| Docker image (test runner + playground) | Built and run on macOS arm64, PG 15–18 |

## Updating expected output

1. Run the suite; look at `results/*.out` and `regression.diffs`.
2. Read every changed line and confirm it's correct.
3. Copy the reviewed file to `expected/`. Never hand-edit expected files.

Version differences: if a PG version produces different but correct output, add an alternative expected file (`expected/basic_1.out`); pg_regress accepts either.
