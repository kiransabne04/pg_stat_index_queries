# T08 — Table and column statistics behind every index decision

**Status: done 26 Oct 2026** (native 0.7, SQL edition 0.6; unreleased).

## Why
Usage alone doesn't say whether an index is needed or what dropping it does. Whether an index is needed, and what dropping it costs, depends on the data underneath it:
- how many rows the table has;
- how many distinct values the indexed columns hold, and how they're distributed;
- how fast the table changes.

Some examples:
- On a table of 200 rows, the planner prefers a sequential scan anyway, so the index is noise.
- On a column with 3 distinct values and no skew, an equality index rarely helps.
- With a skewed column, the same query uses the index for rare values and a sequential scan for common ones (lab case W14).
- An unused index on a heavily updated table costs writes on every insert and update. It also blocks HOT updates when its column changes.
- Stale statistics (`n_mod_since_analyze` large, old `last_analyze`) make both the planner's choice and `index_drop_impact`'s estimate unreliable.

So the views should show, next to each index, the statistics the planner itself uses.

Requested by the user (2026-10-26): "to understand the index need or drop impact we need to understand the underlying tables records counts, unique records and all its histogram & stats needed for index".

## Scope
Read-only, catalog and statistics views only. Pure SQL, so the same definition works in both editions: native (next version) and SQL edition (next version). Never runs ANALYZE, and never reads table data.

## Spec

### 1. `pg_index_table_stats` / `index_deps.index_table_stats`: one row per index, table-level context
| Column | Source |
|---|---|
| schemaname, tablename, indexname, indexrelid | catalogs |
| table_rows_est | `pg_class.reltuples` (−1 = never analyzed → NULL) |
| table_pages, table_bytes, index_bytes, index_to_table_pct | `relpages`, `pg_relation_size` |
| n_live_tup, n_dead_tup, dead_pct | `pg_stat_user_tables` |
| inserts, updates, deletes, hot_update_pct (since stats reset) | `n_tup_ins/upd/del`, `n_tup_hot_upd` |
| seq_scan, seq_tup_read, idx_scan (table), idx_scan (this index), idx_tup_read, idx_tup_fetch, last_idx_scan (PG 16+) | `pg_stat_user_tables` / `pg_stat_user_indexes` |
| last_analyze, last_autoanalyze, n_mod_since_analyze, stats_stale (bool: modified > 10% of rows since the last analyze, or never analyzed) | `pg_stat_user_tables` |
| small_table (bool: < 1,000 rows or < 8 pages) | derived |

### 2. `pg_index_column_stats` / `index_deps.index_column_stats`: one row per index key column
| Column | Source |
|---|---|
| indexname, key position, column name (or expression text) | `pg_index.indkey`, `pg_get_indexdef(oid, n, true)` |
| null_frac, avg_width | `pg_stats` |
| n_distinct (raw) and distinct_est (absolute: negative n_distinct × table rows) | `pg_stats.n_distinct`, `reltuples` |
| equality_selectivity_est (1 / distinct_est, adjusted for nulls) and rows_per_value_est | derived |
| most_common_vals, most_common_freqs (top 5), mcv_total_freq, skewed (bool: top MCV freq ≥ 10% and either > 5 × the average share of a value or ≥ 10 × the rarest MCV freq) | `pg_stats` |
| histogram_buckets (count of `histogram_bounds` − 1), histogram_bounds (first/last), correlation | `pg_stats` |
| expression indexes: statistics from `pg_stats` rows of the index itself (`tablename` = index name) | `pg_stats` |

### 3. Multicolumn context
- Extended statistics on the same columns (`pg_stats_ext`): n_distinct for the column combination, functional dependencies, multicolumn MCV. Report whether they exist; if there are none on a multicolumn index's columns, add a note that the planner assumes independence.

### 4. Use the statistics in verdicts and drop impact
- `index_usage` / `pg_index_usage`: append hints, for example:
  - "tiny table: the planner may prefer a sequential scan anyway";
  - "low distinct count (n): an equality index on this column rarely helps";
  - "skewed: helps rare values only";
  - "stats stale: run ANALYZE before deciding";
  - "write cost: N updates since reset, HOT x%".
- `index_drop_impact`: in `note`, mention stale statistics (the estimate may be wrong) and the table size.

## Caveats to document
- `pg_stats` only shows columns the caller can SELECT. Missing rows mean no privilege or never analyzed, not "no data".
- All values are planner estimates from the last ANALYZE (sampled, `default_statistics_target`), not exact counts. Exact counts (`count(DISTINCT …)`) are out of scope: they read the table.
- Counters in `pg_stat_user_tables` / `_indexes` are per instance and reset with `pg_stat_reset()`, the same caveat as the dependency counters (check every replica).

## Tests
- Regression: a table with known data and ANALYZE: uniform, skewed, low-cardinality and mostly-NULL columns, an expression index, a multicolumn index with and without `CREATE STATISTICS`, and a never-analyzed table. Check distinct_est, selectivity, skewed, stats_stale and small_table within tolerances, since ANALYZE samples. Use `default_statistics_target` and tables small enough that ANALYZE reads every row, so the values are exact.
- Lab: add checks that verdict hints appear for the tiny-table, low-cardinality and skewed cases.

## Not in scope
- Running ANALYZE or reading table data.
- Index bloat measurement with pgstattuple (could be an optional extra when the extension is installed).
