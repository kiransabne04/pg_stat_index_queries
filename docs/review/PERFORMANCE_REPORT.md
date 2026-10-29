# Performance report: 28–29 Oct 2026 review

What the review's changes cost, what is measured, and what isn't yet.

## Baseline (before the review)

Native 0.9 on one AWS c7gd.xlarge (4 Graviton3 vCPU, local NVMe), PostgreSQL 17.11, pgbench scale 100, 4 clients, 10 × 120 s per mode, interleaved ([raw](../../bench/results/2026-10-27-aws-c7gd.xlarge-pg17-runs10.md)):

| Workload | Mean change vs no extension | 95% interval |
|---|---|---|
| `select_only` (one PK lookup per transaction) | −3.3% | −4.4% to −2.2% |
| `wide` (20-index table, 3 statements) | −2.9% | −4.1% to −1.7% |
| `tpcb` (read/write) | +0.4% | −2.2% to +3.0% (noise) |

A CPU profile puts the extension's own functions at about 0.7% of samples; where the rest of the `select_only` gap goes is still open (README, Overhead).

## Changes with a cost effect

| Change | Expected effect | Measured |
|---|---|---|
| New (index, query) pairs published by the statement that records them (N1) | One shared-memory insert per **new** pair, as before batching; known pairs stay batched, so steady state is unchanged. Workloads that create many new pairs per second (many query IDs, reporting, partition churn) pay more | Not yet (R4) |
| Known-pair lookup and `change_count` recheck (N1, N8) | One non-blocking shared lookup the first time a pair is seen per flush interval; one atomic read per statement that trusted a known pair | Not yet (R4) |
| No 64-index cap (N3) | No cost up to 64 indexes per statement (inline array); above it, growth and one sort | Not measured separately; affects only very wide plans |
| Readers copy under the lock (N12) | Shorter shared-lock hold for `pg_stat_index_queries` readers; one copy of the hash per call | Not yet (R5) |
| ALTER TABLE capture (N5–N7) | Runs only for ALTER COLUMN TYPE / SET EXPRESSION | See below |

## ALTER COLUMN TYPE capture cost

Local measurement: PG 17.11 (Homebrew), Apple M-series laptop. ALTER COLUMN TYPE on a 1,000-row table with 2 tracked indexes; the shared hash is filled with distinct (index, query) pairs first; 3 runs each.

| Shared entries | ALTER COLUMN TYPE |
|---|---|
| 0 | 1.8 ms |
| 10,000 (default `max`) | 3.1–3.9 ms |
| 50,000 | 6.5–8.0 ms |
| 100,000 | 11.7–13.1 ms |

Linear, about 0.1 ms per 1,000 entries. It includes the capture (scan under the shared lock, sort, catalog lookups) and the re-key (scan under the **exclusive** lock, which briefly blocks backends inserting new pairs). Small next to the table rewrite such an ALTER performs; other ALTER TABLE subcommands don't run it. Laptop numbers: indicative, not publishable.

## Still to measure (before the tag)

1. 0.10.1 vs 0.10 on one EC2 instance, `bench/aws-ec2.sh` with `--runs 10`: `select_only`, `wide`, `tpcb`. Pass condition: within the 95% intervals of the baseline.
2. A high-cardinality mode: many distinct query IDs per second (dynamic SQL), to price N1.
3. 32, 64 and 128 clients, `select_only` plus a concurrent reader of `pg_stat_index_queries`, main vs 0.10, to see N12.

Each needs an EC2 instance and an `aws login` session (expires after about 12 h; keep runs short, see BENCHMARK).
