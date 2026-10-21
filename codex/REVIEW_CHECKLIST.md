# Review checklist (for any change, human or agent)

- [ ] `make` is warning-free; `make test-all` passes; summary pasted in the PR.
- [ ] No test was removed or weakened. Every changed `expected/*.out` line was read and is correct.
- [ ] C: no allocation in long-lived contexts per statement; no `elog(ERROR)` reachable from a user query path; locks released on all paths; version guards for PG 15–18 APIs.
- [ ] Shared memory layout changes bump the persistence format version (`PGSIQ_FILE_HEADER`).
- [ ] SQL: new objects in a new version script + full script; upgrade test added; `default_version` bumped.
- [ ] SQL edition: `make -C sql_edition managed` re-run; generated installers committed.
- [ ] `index_drop_impact` changes: every exit path unhides the index (test with `hypopg_hidden_indexes()`).
- [ ] Docs and CHANGELOG updated.
- [ ] No real/employer data anywhere.
