# Index lab

End-to-end validation of `pg_index_deps` (and of the native extension, where it can be installed) against a synthetic workload. It produces a markdown report with every case marked PASS, FAIL, KNOWN (a documented limitation) or SKIP, together with feedback and next steps. The same script runs on Docker, Aurora and RDS.

```bash
export PGHOST=... PGPORT=5432 PGUSER=... PGPASSWORD=...   # or ~/.pgpass; PGSSLMODE=require on AWS
sql_edition/validation/lab/run.sh docker-pg17                 # full run
sql_edition/validation/lab/run.sh docker-pg17-rds --simulate-rds
sql_edition/validation/lab/run.sh aurora --pg-tle --keep      # keep databases for the reader phase
PGHOST=<reader> sql_edition/validation/lab/run.sh aurora --reader
sql_edition/validation/lab/run.sh aurora --teardown
```

The lab creates the databases `index_lab` and `index_lab2`, and drops both at the end. Output goes to `lab-out/<label>/` (git-ignored):

- `report.md`
- `results.csv`
- `plan_fixture.csv` (captured plan text for every lab statement)
- `lab.log`
- on Aurora, also `aurora_stat_plans_raw.jsonl` and `aurora_fixture.csv`

All of these contain only lab statements.

To create and delete the AWS resources, use `aws/lab-aws.sh`. It has the subcommands `preflight`, `up`, `run`, `status` and `down`. The minimum IAM policy is in `aws/iam-policy.json`. The run sheet is in [docs/AURORA-VALIDATION.md](../../../docs/AURORA-VALIDATION.md).

## What it does

1. **Seed** (`seed.sql`): about 3.8M synthetic rows at `--scale 1`, deterministic (`setseed`). The tables are customers, products, orders, order_items, events (12 monthly partitions), and small tables for naming, lifecycle and timeout cases. There are 73 indexes: btree, expression, partial with and without a constant, GIN jsonb, GIN trigram, BRIN, GiST, hash, INCLUDE, a duplicate pair, a prefix overlap, a partitioned index, mixed-case, spaces, non-ASCII and truncated names, the same name in two schemas, and an invalid index.
2. **Workload** (`workload.sql`): 40 cases. Every statement carries a `/* lab:Wnn */` comment so its pg_stat_statements entry maps back to its case.
   - Scan types: index, index-only, bitmap, BitmapOr, backward, nested-loop inner.
   - Query shapes: CTE, LATERAL, UNION, IN/ANY, view, PREPARE/EXECUTE, DML, leading comment.
   - Other cases: plan flips on skewed data, partition pruning, a nested PL/pgSQL statement, a second database, a reader-only workload, and a query whose planning takes 0.2 s.
3. **Ground truth:** after the workload runs, the lab EXPLAINs each statement in the same session, with the same statistics and literals. Where the native extension is installed (Docker), its executed counts are checked against that ground truth as well.
4. **Lifecycle:** after the plans are captured, one index is renamed and one is dropped and recreated.
5. **Checks** (`checks.sql`):
   - attribution per case: ground truth vs `index_dependents` vs native;
   - `index_no_dependents` per index: a used index listed as unused is critical;
   - `index_query_stats`;
   - drop impact: only index, unused, partial with and without a constant, duplicate, composite fallback, PREPARE, DML, leading comment, view, KNN, a hypothetical index present, `p_timeout_ms`, cancellation while an index is hidden, read-only transaction;
   - error paths: not an index, missing index, no HypoPG, no pg_stat_statements, bad plan source, unprivileged role.
6. **Report** (`report.sql`).

## Reading the report

- **FAIL** means the tool is wrong or broke. The severity says how bad: `critical` means it could get a used index dropped, or it changes a session's real plans.
- **KNOWN** is a documented limitation that behaved as documented. If one turns into PASS, the limitation has gone away.
- Rows from the native extension (`N-`, `NU-`) check the ground-truth method. They are left out of the Findings section.
