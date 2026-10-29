# Release checklist: v0.10.1 (native 0.10.1, SQL edition 0.8)

Tick every line before tagging. Record the evidence (command, result, date) next to it.

## Code and tests

- [x] Both review PRs merged to main (#1 `6fc49dc`, #2 `6af2cb2`); CI 7/7 green on main.
- [x] `make COPT=-Werror` warning-free on PG 15–18.
- [x] Native regression 13/13 and TAP pass on PG 15–18 (Docker).
- [x] SQL edition 9/9 on PG 16–18 (Docker); upgraded objects equal a fresh install.
- [x] `make -C sql_edition -B managed` leaves `install.sql` / `install_pg_tle.sql` unchanged.
- [x] Assertion + ASan/UBSan build, `make installcheck`, PG 15, 17, 18: no sanitizer reports (29 Oct).
- [x] `test/stress/stress.sh` with the ALTER COLUMN TYPE noise, PG 15 (`DUR=45`), 17 (120 + 60), 18 (120): NO FINDINGS, no `deadlock detected` (29 Oct, TESTING.md).
- [x] Validation lab, Docker PG 16, 17, 18: 0 FAIL (193 PASS, 5 KNOWN each; 29 Oct, after fixing S5/S6 found by the first run).

## Managed Postgres

- [ ] Aurora PostgreSQL 17: `index_deps.resolved_plan_source()` returns `aurora_stat_plans`; lab run 0 FAIL.
- [x] RDS PostgreSQL 17, `--simulate-rds` in Docker: 0 FAIL (113 PASS, 2 KNOWN; 29 Oct). A real RDS run is optional.
- [ ] pg_tle path: `install_pg_tle.sql` on a 0.7 install, then `ALTER EXTENSION pg_index_deps UPDATE` reaches 0.8.

## Performance

- [ ] 0.10.1 vs 0.10, EC2, `--runs 10`: `select_only`, `wide`, `tpcb` within the baseline's intervals (PERFORMANCE_REPORT, item 1).
- [ ] High-cardinality mode measured and written up (item 2).
- [ ] 32–128 clients measured (item 3), or explicitly deferred in the release notes.
- [ ] All EC2 / RDS / Aurora resources deleted afterwards; account shows no instances, clusters, security groups or key pairs from the run.

## Versions and docs

- [x] `default_version` in `pg_stat_index_queries.control` stays `0.10` (library-only release: no SQL objects changed). The library carries no version string, so 0.10.1 is identified by the tag and README/CHANGELOG.
- [x] `sql_edition/pg_index_deps.control` `default_version = '0.8'`; upgrade script 0.7 → 0.8 present and tested.
- [ ] CHANGELOG: rename "Unreleased" to `0.10.1 (date): native 0.10.1, SQL edition pg_index_deps 0.8`; keep the "Repository made public" line.
- [ ] README status line, INSTALL upgrade notes (native 0.10 → 0.10.1: restart only; SQL 0.7 → 0.8), GUIDE, TESTING (new stress and lab rows), BENCHMARK (new results).
- [ ] `docs/review/` updated with the final evidence.
- [ ] No employer, client or production data anywhere (AGENTS rule 10): `git grep` for hostnames, account IDs, customer names.

## Tag and publish

- [ ] `git tag -a v0.10.1 -m "native 0.10.1, SQL edition 0.8"` on main; `git push origin v0.10.1`; CI green on the tag.
- [ ] `gh release create v0.10.1 --notes-file <notes>` (notes from CHANGELOG; mention the `index_drop_impact` behaviour change: other roles' queries skipped unless `p_trust_other_roles`).
- [ ] Delete merged branches `review-hardening`, `sql-0.8-security` on origin.
