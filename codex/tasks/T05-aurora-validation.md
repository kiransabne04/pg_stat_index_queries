# T05 — Validate the SQL edition on a live Aurora cluster

**Status (24 Oct 2026): done** for the Aurora writer (17.9.5, express configuration) and RDS 17.11. See `docs/AURORA-VALIDATION.md`. Open: the Aurora reader phase, which needs a paid-plan account (an extra instance).

## Goal
Prove `index_deps` works on Aurora PostgreSQL and lock in a real fixture.

## Steps

Use the index lab: `sql_edition/validation/lab/aws/lab-aws.sh preflight | up | run | down` (run sheet: `docs/AURORA-VALIDATION.md`). The steps below are what it automates.

1. Smallest Aurora PostgreSQL 16 or 17 cluster in a test account (set a budget alarm; stop it when done). Parameter group: `aurora_compute_plan_id = on`, pg_stat_statements preloaded.
2. Install `sql_edition/install.sql`; create a synthetic table and run a few indexed queries.
3. Check `index_deps.resolved_plan_source()` = `aurora_stat_plans` and that `plan_source()` works. If column names differ from the adapter, fix `plan_source()` and note it in DECISIONS.md.
4. Save `SELECT queryid, planid, calls, explain_plan FROM aurora_stat_plans(true)` rows for your synthetic queries as a fixture table in `sql_edition/sql/parse.sql` (keep the plan text exactly as Aurora prints it).
5. Run `index_drop_impact` on one index; record the output in `docs/TESTING.md`.
6. Repeat the drop-impact check on RDS for PostgreSQL 16+ (no plan source; fallback path).

## Acceptance criteria
- `docs/TESTING.md` shows Aurora and RDS as verified, with versions and dates.
- Fixture from real Aurora output added to tests.
