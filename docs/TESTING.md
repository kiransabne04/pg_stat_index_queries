# Testing

## Suites

| Command | What it covers |
|---|---|
| `make installcheck` | `sql/basic.sql`: index scan, index-only, bitmap, planned-not-executed, prepared statements, nesting (top vs all), helper views, catalog filter, reset · `sql/partitions.sql`: partition roll-up · `sql/query_stats.sql`: `pg_index_query_stats` calls/rows per normalized query, `other_indexes` on a join, partial flag and indexdef, rows kept with NULL stats after pg_stat_statements reset, clear error once pg_stat_statements is dropped · `sql/stats.sql` (shared with the SQL edition, from `scripts/stats_test.sql.in`): table and column statistics on exactly analyzed tables (uniform, few-valued, skewed, few-valued skewed, mostly NULL, expression, multicolumn with and without `CREATE STATISTICS`, partitioned, never analyzed), hints, stale statistics after writes · `sql/columns.sql`: `cond_columns` / `order_columns` per query (leading, multi-column, non-leading, ordered scan without condition, BitmapOr, index-only, expression, KNN, partitioned), `pg_index_column_usage`, planned-not-executed records no columns, the pre-0.8 C symbol still works · `sql/upgrade.sql`: every version up to the current one, upgraded objects identical to a fresh install · `t/001_persistence.pl`: survives clean restart, `save = off`, corrupt file ignored and reported, **real crash** (process killed) doesn't reload stale counters · `t/002_eviction.pl`: `max = 100` with 150 indexes, dealloc counted, newest kept · `t/003_flush.pl`: lag across sessions, flush on disconnect · `t/004_columns.pl`: column sets survive restart; a format 2 (0.6/0.7) file is read and its entries flagged `columns_complete = false` |
| `make -C sql_edition installcheck` | `parse`: fixture plans incl. Backward, Index Only, BitmapOr, quoted names, same-name index in two schemas (ambiguous) · `dependents`: live pg_stat_plans · `query_stats`: `index_query_stats` on a join (scan types, other indexes, stats), clear error once pg_stat_statements is dropped · `drop_impact`: cost/plan change, index never left hidden, broken query skipped cleanly, DML skipped, error on non-index, typed literals (`interval $1`) and `PREPARE` texts rewritten so they can be EXPLAINed, partial index with a constant predicate reported as unknown (not "unchanged"), `IS NULL` partial index estimated normally, both again with no plan source (text-match candidates) · `stats`: same as the native `stats` test, plus the stale-statistics note in `index_drop_impact` · `upgrade`: every version up to the current one, upgraded objects identical to a fresh install |
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
| CI workflow, all 7 jobs (native 15–18, sql-edition 16–18) | Pass locally via `scripts/ci-local.sh` (ubuntu:24.04, linux/amd64, PGDG), and on GitHub Actions (run 39908116705, 23 Oct 2026, commit 9e6c2ac) |
| `aurora_stat_plans` adapter | Verified on Aurora PostgreSQL 17.9.5 (24 Oct 2026): column names match; real plan text is in the `parse` test fixture |
| Aurora PostgreSQL 17.9.5, express configuration (Serverless v2, free-plan account), ap-southeast-2, pg_tle install | Index lab: 115 PASS, 0 FAIL, 4 KNOWN (24 Oct 2026). Report: [validation/2026-10-24-aurora-17.9-express-writer.md](validation/2026-10-24-aurora-17.9-express-writer.md). Reader phase run separately (express cluster + reader): W40 attributed on the reader only; `index_drop_impact` works on the reader ([report](validation/2026-10-24-aurora-17.9-express-reader.md)) |
| RDS for PostgreSQL 17.11, db.t4g.micro, ap-southeast-2, plain install | Index lab: 33 PASS, 0 FAIL, 2 KNOWN (24 Oct 2026): no plan source, drop-impact fallback. Report: [validation/2026-10-24-rds-17.11.md](validation/2026-10-24-rds-17.11.md) |
| Index lab (`sql_edition/validation/lab/`) | Docker PG 16–18, both modes, Aurora 17.9 and RDS 17.11, 24 Oct 2026: 0 FAIL after SQL edition 0.4 (see below) |
| `sql_edition/validation/managed_check.sql` (T05 smoke test) | Dry-run on PG 17 playground: self-hosted path and RDS path (`-v simulate_rds=1`). Aurora/RDS runs pending, see [AURORA-VALIDATION.md](AURORA-VALIDATION.md) |
| `install_pg_tle.sql` | Verified with pg_tle built from source (aws/pg_tle main, Oct 2026), extension files removed from disk. 0.2 (22 Oct, pg_tle 6340fd2, PG 16): fresh install; upgrade of a 0.1 pg_tle install via the new file + `ALTER EXTENSION UPDATE` (config kept); file rerun is harmless |
| Drop-impact fallback with no plan source (RDS-like) | Verified: candidates from query text, index use before/after correct |
| Docker image (test runner + playground) | Built and run on macOS arm64, PG 15–18 |

## Index lab (Docker, 24 Oct 2026)

Command: `sql_edition/validation/lab/run.sh`, run against the Docker playground image.
- Image: arm64, pg_stat_plans 2.1, HypoPG 1.4.3, with the native extension as ground truth.
- Scale 1: about 3.8M rows and 76 indexes. Each run takes about 12 s.
- "rds" means `--simulate-rds` (plan_source = none).
- Counts include the native ground-truth rows.

**26 Oct 2026** (SQL edition 0.6, native 0.7, with the T08 statistics checks S-*):

| Run | PASS | FAIL | KNOWN |
|---|---|---|---|
| PG 16.15 / 17.11 / 18.6 | 193 | 0 | 5 |
| PG 16.15 / 17.11 / 18.6, rds | 111 | 0 | 3 |

The first run failed S-skewed and S-skewed-hint: `orders.status` (95 / 4.5 / 0.5%) was not flagged as skewed. Fixed before release (see CHANGELOG, T08).

**After the fixes** (SQL edition 0.4, native 0.5):

| Run | PASS | FAIL | KNOWN |
|---|---|---|---|
| PG 16.15 / 17.11 / 18.6 | 186 | 0 | 5 |
| PG 16.15 / 17.11 / 18.6, rds | 104 | 0 | 3 |

- **Reader rehearsal** (`--reader` with `default_transaction_read_only=on`): W40 is attributed on that instance, and `index_drop_impact` runs without error.
- **KNOWN rows**, all limitations that behave as documented:
  - The same index name in two schemas: both indexes are credited, and the row is flagged `ambiguous`.
  - An index renamed after its plan was captured gets no queries attributed. It is no longer listed as unused, and its verdict is "unknown". The same holds for the table's other unused index (life_invalid_idx).
  - Native: an index recreated after the workload has a new OID, so it has no recorded use yet.
  - rds only: a query that goes through a view isn't a drop-impact candidate, and there are no dependents to show a role for.

**Before the fixes** (SQL edition 0.3, first lab run): 6 FAIL per run. All are fixed in SQL edition 0.4, and each now has a regression test.

| Case | Severity | Finding (fixed) |
|---|---|---|
| D-cancel-unhide | critical | If `index_drop_impact` was cancelled while the index was hidden, the index stayed hidden for the rest of the session |
| D-read-only | high | Failed in read-only transactions (temp table), so it could not run on Aurora readers |
| E-unprivileged | high | Roles without superuser got `permission denied for table config` |
| D-leading-comment | medium | PG 16/17: a query starting with a comment was skipped as "not a read query" |
| D-timeout-param | medium | `p_timeout_ms` had no effect |
| D-hypothetical | low | A hypothetical HypoPG twin index made the drop look free, with no warning |

## Updating expected output

1. Run the suite; look at `results/*.out` and `regression.diffs`.
2. Read every changed line and confirm it's correct.
3. Copy the reviewed file to `expected/`. Never hand-edit expected files.

Version differences: if a PG version produces different but correct output, add an alternative expected file (`expected/basic_1.out`); pg_regress accepts either.
