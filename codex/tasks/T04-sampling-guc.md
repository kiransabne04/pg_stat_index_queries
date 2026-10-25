# T04 — Sampling setting (only if T03 shows > 1% overhead)

**Status (25 Oct 2026): implemented in native 0.6, together with backend-local batching (the main fix, see DECISIONS).** Was triggered: T03 measured −3.4% (`select_only`) and −2.9% (`wide`). Target version: native 0.6, shared with T07: whichever lands first takes 0.6. Rerun `bench/aws-ec2.sh` with `sample_rate` 1.0 / 0.1 / 0.01 for the acceptance numbers.

## Goal
`pg_stat_index_queries.sample_rate` (real, 0.0–1.0, default 1.0, PGC_SUSET). When < 1, record a statement with that probability and scale counters.

## Notes
- Decide per statement at ExecutorEnd with `pg_prng_double(&pg_global_prng_state)`.
- Store counts unscaled plus a `sampled` flag per entry, or scale at read time; document which.
- Add the column `sampled boolean` to the view in a new version script.

## Acceptance criteria
Tests for sample_rate 0 (nothing recorded) and 1 (exact); benchmark shows the overhead reduction.
