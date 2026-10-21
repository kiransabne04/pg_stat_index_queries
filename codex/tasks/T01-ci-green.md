# T01 — Make CI green on PostgreSQL 15, 16, 17, 18

## Goal
`.github/workflows/ci.yml` passes for every matrix entry.

## Context
- Read `AGENTS.md`, `docs/TESTING.md`.
- Only PG 16 has been verified locally. PG 15/17/18 have never run.
- Known API differences: `ExecutorRun_hook_type` (no `execute_once` in 18), `PlannedStmt.queryId` is `int64` in 18 and `uint64` before.

## Steps
1. Push a branch and let CI run (or run locally with `make PG_CONFIG=/usr/lib/postgresql/NN/bin/pg_config`).
2. For each failure: fix code behind `#if PG_VERSION_NUM` guards, or, if the output differs but is correct for that version, add an alternative expected file (`expected/<test>_1.out`). Explain each in the commit message.
3. SQL edition job: needs pg_stat_plans built from source (16+) and HypoPG from PGDG.

## Acceptance criteria
- All matrix jobs green.
- No test removed or weakened.
- `docs/TESTING.md` "Verified so far" table updated with the versions that pass.

## Don't
- Don't drop a PG version from the matrix to get green.
