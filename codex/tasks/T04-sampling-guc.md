# T04 — Sampling setting (only if T03 shows > 1% overhead)

## Goal
`pg_stat_index_queries.sample_rate` (real, 0.0–1.0, default 1.0, PGC_SUSET). When < 1, record a statement with that probability and scale counters.

## Notes
- Decide per statement at ExecutorEnd with `pg_prng_double(&pg_global_prng_state)`.
- Store counts unscaled plus a `sampled` flag per entry, or scale at read time; document which.
- Add the column `sampled boolean` to the view in a new version script.

## Acceptance criteria
Tests for sample_rate 0 (nothing recorded) and 1 (exact); benchmark shows the overhead reduction.
