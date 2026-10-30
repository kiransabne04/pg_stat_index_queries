# Aurora / RDS validation run sheet (T05)

The goal is to prove that `pg_index_deps` works on Amazon Aurora PostgreSQL, where the plan source is `aurora_stat_plans`, and on Amazon RDS for PostgreSQL, where there is no plan source and drop impact uses the fallback. The run also captures real Aurora plan text for the tests. Task brief: `codex/tasks/T05-aurora-validation.md`.

The test itself is the index lab ([sql_edition/validation/lab/](../sql_edition/validation/lab/README.md)): a synthetic workload of 40 cases with about 100 checks. It produces a report with every case marked PASS, FAIL or KNOWN, plus feedback. `aws/lab-aws.sh` creates the AWS resources, runs the lab and deletes everything. The older single-file check `sql_edition/validation/managed_check.sql` still works as a 2-minute smoke test.

## Status

| Target | Status |
|---|---|
| Docker PG 16, 17, 18: self-hosted path (pg_stat_plans) and simulated RDS path | Lab run 24 Oct 2026; results in [TESTING.md](TESTING.md#index-lab-docker-24-oct-2026) |
| Aurora PostgreSQL 17.9.5, express configuration (writer only) | Run 24 Oct 2026: 115 PASS, 0 FAIL, 4 KNOWN, pg_tle install. [Report](validation/2026-10-24-aurora-17.9-express-writer.md) |
| Aurora reader phase (express cluster + `db.serverless` reader) | Run 24 Oct 2026 (second run, writer again 115 PASS / 0 FAIL): W40 attributed on the reader only, `index_drop_impact` runs on the reader without error. [Reader report](validation/2026-10-24-aurora-17.9-express-reader.md). On the free plan the reader only fits when no other DB instance exists (RDS deleted first) |
| Aurora PostgreSQL 17.11 (db.t4g.medium writer), SQL edition 0.9 | Run 29 Oct 2026: 123 PASS, 0 FAIL, 4 KNOWN, pg_tle install, plan source `aurora_stat_plans` ([report](validation/2026-10-29-aurora-17.11-writer.md)). The first 29 Oct run, with 0.8, found no plan source: Aurora hides `aurora_stat_plans` (OID 9888) from `pg_proc` queries; fixed in 0.9 |
| RDS for PostgreSQL 17.11, SQL edition 0.9 | Run 29 Oct 2026: 41 PASS, 0 FAIL, 2 KNOWN, plain install ([report](validation/2026-10-29-rds-17.11.md)) |
| RDS for PostgreSQL 17.11 (db.t4g.micro) | Run 24 Oct 2026: 33 PASS, 0 FAIL, 2 KNOWN, plain install. [Report](validation/2026-10-24-rds-17.11.md) |

What the run taught us:

- **Free-plan accounts** (the new AWS experience) can create Aurora only with express configuration (`LAB_AURORA_EXPRESS=1`). AWS then picks the engine version (17.9 here), uses Serverless v2 (0–4 capacity units), turns off VPC networking (the cluster is reached over the internet), signs in as `postgres` with IAM tokens instead of a password, and counts every DB instance against a small quota: the reader could be added only once the RDS instance was gone. A custom cluster parameter group can be attached after creation; it takes effect after a reboot.
- **pg_tle install** needs `GRANT pgtle_admin TO CURRENT_USER;` first. The master user is `rds_superuser` but not `pgtle_admin`.
- **IAM tokens** last 15 minutes for new connections. `run.sh` takes `PGPASSWORD_CMD` and fetches a fresh token before every connection; the lab's reconnect to the second database happens before the seed.
- **Aurora hides its built-in functions from `pg_proc`** (29 Oct 2026, Aurora 17.11): `aurora_stat_plans(boolean)` resolves by name and runs, but `SELECT … FROM pg_proc` returns no row for it by OID (9888) or by name, and no `aurora*` rows at all, even for the master user. Find such functions with `to_regprocedure('pg_catalog.name(args)')`, never by reading `pg_proc`.
- Columns of `aurora_stat_plans(true)` match the adapter; `pg_stat_statements.track = all` can be set per session by the master user.

## 0. What you need

- An AWS account used only for this; no production data in it.
- An AWS Budgets alarm, e.g. a small monthly amount with an email alert.
- An IAM user or SSO role with the policy in `sql_edition/validation/lab/aws/iam-policy.json`. Prefer SSO / short-lived credentials (`aws configure sso`) over access keys. Never use root keys.
- The AWS CLI v2 (`brew install awscli`), psql 16+ and python3 locally.
- A region with a default VPC. `preflight` checks this.

What gets created, all tagged `project=pgsiq-lab`:

- a security group that allows your current IP /32 on port 5432;
- one cluster parameter group and one DB parameter group, each with `pg_stat_statements,pg_tle` preloaded; the Aurora one also sets `aurora_compute_plan_id = on`;
- an Aurora PostgreSQL 17 cluster with a `db.t4g.medium` writer and reader;
- an RDS PostgreSQL 17 `db.t4g.micro` instance with 20 GB gp3 storage.

Master passwords are managed by RDS in Secrets Manager. The script reads them into its own environment only and never writes them to disk.

Cost: the instances bill per hour while they exist. A full session (up, run, down) takes about 1–2 hours and should cost a few dollars. Run `down` straight afterwards, and check `status` and the budget the next day.

## 1. Run

```bash
cd ~/Documents/projects/pg_stat_index_queries
export AWS_PROFILE=<profile> AWS_REGION=<region>
L=sql_edition/validation/lab/aws/lab-aws.sh

$L preflight     # identity, region, default VPC, engine versions, your IP; changes nothing
$L up            # 15-25 min: SG, parameter groups, cluster + writer + reader, RDS; reboot to apply parameters
$L run           # ~10 min: Aurora writer (pg_tle install), Aurora reader phase, RDS (plain install)
$L down          # delete everything above; no snapshots kept
$L status        # should print nothing after down
```

`run` writes everything to `lab-out/aurora-<version>-<stamp>/` and `lab-out/rds-<version>-<stamp>/`:

- `report.md`, `results.csv`, `plan_fixture.csv` and `lab.log`;
- `reader-report.md` for the reader phase;
- on Aurora, `aurora_stat_plans_raw.jsonl` and `aurora_fixture.csv`.

## 2. What to look at

- **Report → Summary / Findings.** Compare them with the Docker run in [TESTING.md](TESTING.md#index-lab-docker-24-oct-2026). Every difference is either a gap specific to Aurora/RDS, or a planner difference. To tell them apart, compare the `truth` and `sql_edition` columns in "Which indexes each query used".
- **Environment.** `plan source` must be `aurora_stat_plans` on Aurora and `none` on RDS, and `aurora_compute_plan_id` must be `on`.
- **Column-name mismatch.** If `index_deps.plan_source()` errors on Aurora, the writer run stops early. `aurora_stat_plans_raw.jsonl` has every column, so the adapter can be fixed without another cluster run.
- **Reader report.** W40 should be attributed on the reader, while the writer report lists `lab.reader_only_idx` as unused (each instance keeps its own statistics). The drop-impact result on the reader is shown there too.
- **pg_tle.** The writer run installs through pg_tle. If that fails, `lab.log` shows it before any check runs.

## 3. Bring results back into the repo

1. Look through `aurora_fixture.csv` and `plan_fixture.csv`. They contain only `/* lab:... */` statements on the synthetic schema, but check anyway: no hostnames, no account IDs.
2. Add Aurora plan rows (exactly as printed) as a fixture table to `sql_edition/sql/parse.sql`. Regenerate `expected/parse.out` by running the suite in Docker (PG 16–18) and read every line.
3. If the adapter needed changes, add an entry to `docs/DECISIONS.md`, run `make -C sql_edition managed` and rerun the SQL edition tests.
4. In `docs/TESTING.md`, add rows for Aurora and RDS with engine versions, instance class, region and date, plus the Summary table from each report.
5. In `docs/INSTALL.md`, remove the "not yet run against a live cluster" note. Add a CHANGELOG entry.

## If something fails

Keep the whole `lab-out/<run>/` folder. Everything needed to debug offline is in there.
