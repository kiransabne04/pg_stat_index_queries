# pg_stat_index_queries overhead — 2026-10-22 07:20 UTC

> NOT PUBLISHABLE: Docker Desktop VM (10 vCPU, 7.7 GB) on an Apple M5 laptop (10 cores, 16 GB), PG 17.11 linux/arm64. Sanity check only.

- Machine: docker-m5-notpublishable, 10 vCPU, 7 GB RAM
- CPU: unknown (aarch64); see note
- Kernel: Linux 6.12.76-linuxkit, arch aarch64
- PostgreSQL: postgres (PostgreSQL) 17.11 (Debian 17.11-1.pgdg13+2)
- pgbench scale 50, 8 clients, 3 × 60s per mode, modes interleaved

| Workload | Mean TPS off | Mean TPS on | Change | Spread off | Spread on |
|---|---|---|---|---|---|
| select_only | 270936 | 253718 | -6.36% | 75.01% | 25.45% |
| tpcb | 6444 | 6047 | -6.16% | 50.46% | 7.11% |
| wide | 63454 | 60283 | -5.00% | 18.52% | 10.40% |

A change smaller than the spread is noise.

Raw runs (workload, mode, run, tps):
```
select_only,off,1,391945.565928
tpcb,off,1,8313.923468
wide,off,1,61027.086986
select_only,on,1,267412.614928
tpcb,on,1,6154.392219
wide,on,1,56703.557388
select_only,on,2,279162.088248
tpcb,on,2,6208.123492
wide,on,2,62975.322933
select_only,off,2,232158.127369
tpcb,off,2,5954.542830
wide,off,2,70543.479554
select_only,off,3,188703.877625
tpcb,off,3,5062.422278
wide,off,3,58792.316276
select_only,on,3,214579.230841
tpcb,on,3,5778.194514
wide,on,3,61171.212483
```
