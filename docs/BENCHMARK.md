# Benchmark plan

Question: how much throughput does `pg_stat_index_queries` cost? Roadmap gate for 0.2.1: **overhead < 1%** on every workload. If any workload is worse than −1% (beyond noise), open T04 (sampling GUC).

## What the extension adds per statement

ExecutorRun/Finish/End hooks (nesting depth tracking), a walk of the plan state tree at ExecutorEnd, and one shared-hash update per index in the plan (`LW_SHARED` lock plus a per-entry spinlock; `LW_EXCLUSIVE` only to insert a new entry). So the cost is per statement and grows with the number of index nodes in the plan. The workloads below cover both ends.

| Workload | pgbench args | Why |
|---|---|---|
| `select_only` | `-S -M prepared` | Worst case: tiny statements (one PK lookup), so fixed per-statement overhead is the biggest share |
| `tpcb` | `-M prepared` | Realistic mixed read/write; overhead diluted by WAL and locking |
| `wide` (`--wide`) | `-f bench/wide_workload.sql` | 20-index table, three statements per transaction; more index nodes and more distinct entries |

## Method (`bench/run.sh`)

- Throwaway cluster in a temp directory; `shared_buffers = 1GB`, `compute_query_id = on`.
- `off` = library not in `shared_preload_libraries`; `on` = preloaded. The server is restarted for every mode switch and the setting is checked after start, so a run can't be mislabelled.
- Modes are **interleaved** (run 1: off, on; run 2: on, off; …). Running all `off` first and all `on` second would charge drift (cache warm-up, TPC-B table growth, autovacuum) to one mode.
- `CHECKPOINT` before every pgbench run.
- Report: mean TPS per mode, change, and **spread** per mode = (max − min) / mean over the runs. A change smaller than the spread is noise.

## Publishable run (T03)

Only numbers from this setup go into README:

1. Dedicated Linux VM, 4–8 vCPU, non-burstable instance type (no AWS t-family, no shared-core types), local or provisioned-IOPS SSD. Nothing else running.
2. Record CPU model, vCPU, RAM, disk type, kernel, PG version (the script writes most of it; add the rest with `--note`).
3. PG 17 or 18 from PGDG; extension built with `make` and installed.
4. Run with defaults: `./bench/run.sh --wide --label <provider>-<instance-type>` (scale 100, 3 × 300 s per mode per workload, clients = vCPU). About 1.5 hours.
5. If any spread is above 2%, the machine is too noisy: rerun with `--runs 5` or on another instance.
6. Commit `bench/results/<date>-<label>.md`; put the mean change per workload in README "Overhead".

On AWS, `bench/aws-ec2.sh` does steps 1–6. Default `c7gd.xlarge`: 4 Graviton3 vCPU, non-burstable, local NVMe for the data directory. Run `up`, `push`, `run`, then `fetch` and `down` after about 1.5 hours. It needs a paid-plan account: free-plan accounts can launch only free-tier types (2 vCPU, burstable or flex).

## Not publishable

Laptops, Docker Desktop (a VM on the host), emulated architectures, and burstable cloud instances. These runs are fine as a sanity check before the real one. Always pass `--note "NOT PUBLISHABLE: <why>"` and a label that says so; don't quote their numbers in README.

## Gaps (not measured yet)

- Eviction pressure: a workload with more distinct (index, query) pairs than `pg_stat_index_queries.max`, so the exclusive-lock dealloc path runs.
- High client counts (≥ 4 × vCPU) for lock contention on the shared hash.

## Runs so far

| Date | Setup | Result |
|---|---|---|
| 2026-10-25/26 | Native 0.6 (7385741), c7gd.xlarge, new instance: `select_only` with `--on-conf pg_stat_index_queries.sample_rate=0.1` (`…-v06-sample0.1.md`), and a `perf` profile of pgbench `-S` with defaults (`bench/profile.sh`, `…-v06-profile.txt`). The planned `sample_rate=0.01` run didn't start (SSH dropped) | `sample_rate=0.1`: −3.25% (spread 2.3% / 2.1%; `off` baseline 99.6k TPS vs 93–96k on the earlier instances, so instances alone differ by up to 6%). **Profile: the extension's own code is ~0.7% of all CPU samples** (ExecutorEnd incl. walk and local counting ~0.5%, Run/Finish hooks ~0.2%); kernel 40%, postgres 44%. So the true per-statement cost is under 1%. TPS comparisons at this level are noise-bound with 3 × 300 s; resolving < 1% needs many more runs (e.g. `--runs 10`) on one instance |
| 2026-10-25 | **Publishable.** Same machine type and method, native **0.6** (8159b59): defaults (batching, `flush_interval` 1 s) (`bench/results/2026-10-25-aws-c7gd.xlarge-pg17-v06.md`), plus `select_only` with `--on-conf pg_stat_index_queries.flush_interval=0` (`…-v06-flush0.md`) | Batching: `select_only` −1.84% (spread off 3.6%: the `off` runs drifted 94.9k → 91.5k, so this is within noise), `wide` −0.94% (spread 0.1% / 1.8%), `tpcb` +2.1% (noise). With `flush_interval=0`: `select_only` −2.96% (spreads 0.4% / 1.1%: clean). Batching roughly halves the per-statement cost and puts `wide` under 1%. `select_only` is not yet shown to be under 1%. Next lever: `sample_rate` (skips the plan walk); a run at 0.1 would measure it |
| 2026-10-24 | **Publishable.** AWS c7gd.xlarge (4 × Neoverse-V1, 7 GB, local NVMe), PG 17.11 PGDG, scale 100, 4 clients, 3 × 300 s, `bench/aws-ec2.sh` (`bench/results/2026-10-24-aws-c7gd.xlarge-pg17.md`) | `select_only` **−3.39%** (spread 2.1% / 1.0%; every `on` run below every `off` run: real), `wide` **−2.90%** (spread 1.9% / 3.5%; again every `on` run lower: real), `tpcb` +1.71% (spread 4.3% / 3.2%: noise, write path dominates). Fails the < 1% gate, so T04 (sampling) is opened. `tpcb` spread is above the 2% rule; a `--runs 5` rerun would tighten it but can't change the decision |
| 2026-10-22 | Docker Desktop on Apple M5 laptop, PG 17.11 arm64, scale 50, 8 clients, 3 × 60 s (`bench/results/2026-10-22-docker-m5-notpublishable.md`) | **Not publishable.** Means −5% to −6.4%, but spread 18–75% per mode: `select_only` with the extension off fell 392k → 232k → 189k TPS over the run (thermal/VM throttling), and in run 3 the `on` runs beat the `off` runs. The changes are far inside the noise; says nothing about overhead. Harness works end to end |
