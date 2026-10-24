# T07 — Record which index columns each query uses (native 0.6)

## Goal
For every (database, index, queryid, toplevel) entry, record which key columns of the index the query actually used, so users can see e.g. "index (a, b, c) is only ever searched on a" and spot redundant trailing columns or indexes that a shorter one could replace.

Native extension only. The SQL edition would have to parse `Index Cond:` text; out of scope here.

## Context
- Read `AGENTS.md`, `docs/ARCHITECTURE.md` (plan walk), `docs/DECISIONS.md`. Add a DECISIONS entry: this goes beyond the PRD's "which queries use this index".
- Plan walker: `pgsiq_walker()` in `pg_stat_index_queries.c` handles `IndexScan`, `IndexOnlyScan`, `BitmapIndexScan`.
- In those plan nodes, `indexqual` (and `indexorderby` for IndexScan/IndexOnlyScan) reference index columns as `Var` with `varno = INDEX_VAR` and `varattno` = index column number (1-based). Check this holds in PG 15–18 headers (`nodes/plannodes.h`).
- `INDEX_MAX_KEYS` is 32 by default, so a `uint32` bitmask fits. If a build has a larger `INDEX_MAX_KEYS`, ignore columns above 32 and document it.

## Spec
- New per-entry fields, OR'd across executions:
  - `cond_cols uint32`: index columns appearing in `indexqual`.
  - `order_cols uint32`: index columns appearing in `indexorderby` (ordering operators, e.g. KNN).
- A scan with no quals (full index scan for ORDER BY or index-only count) records 0 for both; that is meaningful ("used for order/coverage, not search"), keep it.
- SQL surface (0.6):
  - `pg_stat_index_queries()` gains `cond_columns int2[]` and `order_columns int2[]` (index column numbers).
  - `pg_index_dependents` gains `cond_columns text[]` (column names or expression text via `pg_get_indexdef(indexrelid, n, true)`).
  - New view `pg_index_column_usage`: per index, each key column with the number of queries / executed calls that searched on it. Columns never searched on show 0.
- The C function's result shape changes. Follow the pg_stat_statements pattern: new symbol `pg_stat_index_queries_0_6`, old symbol keeps returning the old columns so a 0.5 SQL definition with the new library still works until `ALTER EXTENSION UPDATE`.
- Saved stats file: bump `PGSIQ_FILE_HEADER` format version; an old file is ignored and reported (same path as any invalid file), never misread.
- Collecting must never error a query (AGENTS rule 5). Walk the qual list with `pull_varattnos`-style logic or a small expression walker; no allocations that outlive the statement.

## Steps
1. C: fields in `pgsiqEntry`, collect masks in `pgsiq_walker` into `pgsiqSeenIndex`, merge in `pgsiq_store`, save/load, new SRF symbol. `#if PG_VERSION_NUM` only where signatures differ.
2. SQL: `pg_stat_index_queries--0.5--0.6.sql` and full `--0.6.sql`; `default_version` 0.6; Makefile `DATA`.
3. Tests:
   - `sql/columns.sql`: index (a, b, c); queries on a only, a+b, b only (PG 18 skip scan if chosen; otherwise accept the plan PG makes and assert on what it recorded), ORDER BY a with no WHERE (masks 0), bitmap scan, index-only scan, expression index, KNN or `indexorderby` case if a core opclass allows it (otherwise note why not).
   - `sql/upgrade.sql`: 0.5 → 0.6, old data still readable.
   - TAP: old-format stats file is ignored and reported on restart.
4. Docs: README (views), `docs/ARCHITECTURE.md`, CHANGELOG.
5. `./bench/run.sh` before/after; overhead must stay within noise of the T03 numbers.

## Acceptance criteria
- `make` warning-free, `make installcheck` passes on PG 15–18.
- `columns` test shows correct column sets for each case above.
- Upgrade and old-stats-file cases covered.
- Bench numbers in the PR description.

## Not in scope
- Columns returned by index-only scans (`indextlist`): coverage, not search. Possible follow-up.
- SQL edition parsing of `Index Cond:`.
- Note: T02 also says "version 0.3", but 0.3 and 0.4 have shipped. 0.5 shipped index roles; whichever of T02/T07 lands first takes 0.6.
