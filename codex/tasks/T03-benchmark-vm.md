# T03 — Publish overhead benchmarks on a 4–8 vCPU machine

## Goal
Replace the early 2-vCPU numbers in README with proper ones.

## Steps
1. On a fresh 4–8 vCPU VM (state CPU model, RAM, disk, PG version), install the extension.
2. Run `./bench/run.sh` with defaults (scale 100, 3 × 300 s, both workloads, plus `--wide` for the 20-index schema).
3. Commit `bench/results/<date>-<machine>.md` (the script writes it) and update the README "Overhead" section.

## Acceptance criteria
- Results file committed with machine details and raw TPS per run.
- README states mean change per workload; if any is worse than −1%, open T04.
