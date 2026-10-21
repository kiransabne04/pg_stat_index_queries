# Decisions

| Date | Decision | Why |
|---|---|---|
| 2026-10-15 | Store no query text; join pg_stat_statements on queryid | Avoids a second text store and its memory cost |
| 2026-10-15 | Skip catalog indexes by default | Catalog lookups would drown out user indexes |
| 2026-10-15 | `EXECUTE`/`PREPARE` don't count as nesting | Same as pg_stat_statements; prepared statements are the user's top-level statements |
| 2026-10-21 | Persist at clean shutdown only; delete file after load | Same model as pg_stat_statements; a crash must never reload stale counters |
| 2026-10-21 | Partition roll-up reports max per partition as calls, sum as partition scans | One statement can scan many partitions; summing would overcount statements |
| 2026-10-21 | SQL edition is a separate extension (`pg_index_deps`) in the same repo | Must install on RDS/Aurora without C; shares docs and tests with the native extension |
| 2026-10-21 | Drop-impact uses HypoPG hide + EXPLAIN (GENERIC_PLAN) | Works on managed Postgres; never executes queries or drops anything |
| 2026-10-21 | Same index name in two schemas is flagged `ambiguous`, not guessed | EXPLAIN text has no schema; a wrong guess is worse than a flag |
