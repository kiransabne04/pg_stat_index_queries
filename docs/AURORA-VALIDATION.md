# Aurora / RDS validation checklist (T05)

Goal: prove `pg_index_deps` works on Amazon Aurora PostgreSQL (plan source `aurora_stat_plans`) and Amazon RDS for PostgreSQL (no plan source; drop-impact fallback), and capture a real `aurora_stat_plans` fixture for the tests. Task brief: `codex/tasks/T05-aurora-validation.md`.

Everything runs from `sql_edition/validation/managed_check.sql`. It creates schema `index_deps_check` with synthetic data, runs SELECTs, only EXPLAINs in the drop-impact part, and drops the schema at the end. It doesn't reset any statistics. It has been dry-run against the Docker playground (PG 17, self-hosted path, and the RDS path with `-v simulate_rds=1`); it has **not** run on AWS yet.

## 0. Before you start

- [ ] Use a sandbox/test account, not a production one. No real data goes near this.
- [ ] Set an AWS Budgets alarm for the account (e.g. a small fixed amount, email alert).
- [ ] Pick a region; note it.
- [ ] Have a client with a recent `psql` (the script uses `\if`, `\gdesc`, `\gexec`; tested with psql 17) and network access to the cluster (security group allows your IP on 5432, or use a bastion / SSM port forward).
- [ ] Check out this repo at the commit you're validating; note `git rev-parse --short HEAD`.

## 1. Aurora PostgreSQL cluster

- [ ] Engine: Aurora PostgreSQL **16.x or 17.x** (drop-impact needs 16+). Note the exact engine version.
- [ ] Smallest instance class that the version supports (a burstable class such as db.t4g.medium is fine for a functional check). One writer, no readers.
- [ ] **DB cluster parameter group** (custom, family aurora-postgresql16/17):
  - `shared_preload_libraries` includes `pg_stat_statements` (add `pg_tle` too if you will test the pg_tle install)
  - `aurora_compute_plan_id = on`
  - `compute_query_id` left at default (`auto`/`on`)
- [ ] Reboot the writer after changing `shared_preload_libraries`.
- [ ] Connect as the master user. Run:
  ```sql
  SHOW shared_preload_libraries;
  SHOW aurora_compute_plan_id;
  SELECT aurora_version();
  CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
  CREATE EXTENSION IF NOT EXISTS hypopg;  -- if this fails: note it; drop-impact can't run there
  ```

## 2. Install the SQL edition

Pick one (both if you have time; plain first):

- [ ] Plain: `psql "$URL" -X -v ON_ERROR_STOP=1 -f sql_edition/install.sql`
- [ ] pg_tle: `CREATE EXTENSION pg_tle;` then `\i sql_edition/install_pg_tle.sql` and `CREATE EXTENSION pg_index_deps;`
- [ ] `SELECT index_deps.resolved_plan_source();` returns `aurora_stat_plans`.

## 3. Run the check

```bash
cd /some/empty/dir     # the script writes fixture files to the current directory
psql "$URL" -X -f /path/to/repo/sql_edition/validation/managed_check.sql 2>&1 | tee managed_check-aurora.out
```

What to look at in the output (section numbers match the script):

| Section | Pass if |
|---|---|
| 1 | `is_aurora=t aurora_stat_plans=t hypopg=t pg_stat_statements=t pg16+=t`; `aurora_compute_plan_id = on` |
| 2 | `resolved_plan_source = aurora_stat_plans` |
| 3 | `\gdesc` lists `queryid`, `planid`, `calls`, `explain_plan`, `dbid` (the adapter uses these). **If a name differs, the script stops at section 6 with a column error**: fix `index_deps.plan_source()` and record it in `docs/DECISIONS.md` |
| 6 | One row per workload query with Aurora's plan text. If empty: plans weren't captured (check `aurora_compute_plan_id`, `aurora_stat_plans.*` settings in section 1, rerun) |
| 7 | Parser finds `t_a_idx` (bitmap), `t_pkey` (index, index_only), `T Mixed Case Idx` (index_only). Missing rows mean Aurora prints plans differently: keep the output, it's exactly what the fixture is for |
| 8 | `index_no_dependents` shows only `t_b_unused_idx` |
| 9 | Files `aurora_stat_plans_raw.jsonl` and `aurora_fixture.csv` written |
| 10 | `t_a_idx`: `uses_index_now = t`, `uses_index_after = f`, `cost_ratio > 1`, note `candidates from captured plans` |
| 11 | `t_b_unused_idx`: all `cost_ratio = 1.00`, `uses_index_now = f` |
| 12 | `still_hidden = 0` |

Then:

- [ ] Look at `aurora_fixture.csv` before committing anything: it must contain only `index_deps_check` queries (synthetic). No other workload, no hostnames, no account IDs.
- [ ] **Delete the cluster** (and its final snapshot if you don't need it). Check the budget alarm a day later.

## 4. RDS for PostgreSQL

- [ ] RDS PostgreSQL **16.x or 17.x**, smallest instance class, parameter group with `pg_stat_statements` in `shared_preload_libraries`; reboot.
- [ ] `CREATE EXTENSION pg_stat_statements; CREATE EXTENSION hypopg;`
- [ ] Install as in step 2. `SELECT index_deps.resolved_plan_source();` returns `none`.
- [ ] Run the script, tee to `managed_check-rds.out`.
- [ ] Pass if: section 8 `index_dependents` is empty; section 10 shows the `WHERE a = $1` query with `uses_index_now = t`, `uses_index_after = f`, note `candidates from query text mentions table`; section 12 `still_hidden = 0`.
- [ ] Known issue: section 8 `index_no_dependents` lists **every** non-unique index on RDS, because with no plan source nothing has a recorded dependent. Don't treat that list as "safe to drop". (Tracked for a fix.)
- [ ] Delete the instance.

## 5. Bring results back into the repo

- [ ] Add the Aurora fixture to `sql_edition/sql/parse.sql` as a fixture table with the rows from `aurora_fixture.csv`, plan text exactly as Aurora printed it; regenerate and review `expected/parse.out` (run the suite, read every line).
- [ ] If the adapter needed changes: `make -C sql_edition managed`, rerun all SQL edition tests in Docker (PG 16–18).
- [ ] `docs/TESTING.md` "Verified so far": Aurora and RDS rows with engine versions, instance class, region and date; paste the section 10 rows (synthetic queries only).
- [ ] `docs/INSTALL.md`: remove the "not yet run against a live cluster" note.
- [ ] CHANGELOG entry.

## What to send back if something fails

The full `managed_check-*.out`, plus `aurora_stat_plans_raw.jsonl` (all columns, so a column-name mismatch can be fixed without another cluster run).
