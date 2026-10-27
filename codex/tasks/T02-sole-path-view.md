# T02 — Add `pg_index_sole_path` view (version 0.3)

> **Status: done 26 Oct 2026 as native 0.9** (not 0.3; versions 0.3–0.8 went to other work). Extra column `other_indexes`; partition indexes fold into the parent. See `docs/DECISIONS.md`.

## Goal
For each index, list queries for which it is the only index recorded on its table, with a risk level.

## Spec
Columns: schemaname, tablename, indexname, indexrelid, queryid, calls_executed, last_seen, risk.
- `high`: this index is the only index recorded for (queryid, table) and calls_executed > 0.
- `medium`: other indexes on the same table are also recorded for that query.
- `low`: only planned, never executed.

## Steps
1. Add `pg_stat_index_queries--0.2--0.3.sql` and full `--0.3.sql`; bump `default_version` to 0.3; update `DATA` in the Makefile.
2. Add `sql/sole_path.sql` covering all three risk levels and an upgrade check in `sql/upgrade.sql`.
3. Document in README and `docs/ARCHITECTURE.md`; CHANGELOG entry.

## Acceptance criteria
`make installcheck` passes; the new test covers high, medium and low.
