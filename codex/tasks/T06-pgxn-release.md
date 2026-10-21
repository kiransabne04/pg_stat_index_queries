# T06 — PGXN release

## Steps
1. Add `META.json` (PGXN spec v1.0.0) listing both extensions, version 0.2.0, license postgresql, prereqs (PostgreSQL 15+; runtime recommends pg_stat_statements, hypopg, pg_stat_plans for the SQL edition).
2. Add `make dist` producing `pg_stat_index_queries-0.2.0.zip` via `git archive`.
3. Validate with `pgxn-utils` or the PGXN validator; document the release steps in `docs/RELEASING.md`.

## Acceptance criteria
`make dist` produces a zip that installs and passes `make installcheck` when unpacked elsewhere.
