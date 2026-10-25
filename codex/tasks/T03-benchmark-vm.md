# T03 — Publish overhead benchmarks on a 4–8 vCPU machine

**Status (24 Oct 2026): done.** `bench/results/2026-10-24-aws-c7gd.xlarge-pg17.md`; README updated. Result: −3.4% `select_only`, −2.9% `wide`, noise on `tpcb`, so T04 is opened.

## Goal
Replace the early 2-vCPU numbers in README with proper ones.

## Steps

On AWS, `bench/aws-ec2.sh up|push|run|fetch|down` automates these steps (needs a paid-plan account; tried 24 Oct 2026, free plan refused `c7gd.xlarge`).

1. On a fresh 4–8 vCPU VM (state CPU model, RAM, disk, PG version), install the extension.
2. Run `./bench/run.sh` with defaults (scale 100, 3 × 300 s, both workloads, plus `--wide` for the 20-index schema).
3. Commit `bench/results/<date>-<machine>.md` (the script writes it) and update the README "Overhead" section.

## Acceptance criteria
- Results file committed with machine details and raw TPS per run.
- README states mean change per workload; if any is worse than −1%, open T04.
