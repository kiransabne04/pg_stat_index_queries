# Working on this repo with Codex

Codex reads `AGENTS.md` at the repo root automatically. Each file in `tasks/` is a self-contained brief: paste it into Codex (CLI: `codex "$(cat codex/tasks/T01-ci-green.md)"`, or the Codex app/IDE), let it work in a branch, then review with `REVIEW_CHECKLIST.md` (or ask Claude Code to).

Suggested split:
- **Codex:** mechanical, well-specified tasks (CI fixes, packaging, adding a view with tests, running benchmarks).
- **Claude Code / you:** design changes, C changes touching shared memory or hooks, reviewing anything Codex did in C.

Order: T01 → T03 → T05 → T02 → T06. T04 only if T03 shows overhead above 1%.

`config.example.toml` shows Codex defaults that suit this repo; copy the parts you want into `~/.codex/config.toml` (check key names against your Codex version).
