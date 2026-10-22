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

## Not publishable

Laptops, Docker Desktop (a VM on the host), emulated architectures, and burstable cloud instances. These runs are fine as a sanity check before the real one. Always pass `--note "NOT PUBLISHABLE: <why>"` and a label that says so; don't quote their numbers in README.

## Gaps (not measured yet)

- Eviction pressure: a workload with more distinct (index, query) pairs than `pg_stat_index_queries.max`, so the exclusive-lock dealloc path runs.
- High client counts (≥ 4 × vCPU) for lock contention on the shared hash.
