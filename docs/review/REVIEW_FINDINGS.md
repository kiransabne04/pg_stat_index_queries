# Review findings: correctness and hardening review, 28–29 Oct 2026

Scope: native extension `pg_stat_index_queries` (C, 0.10) and SQL edition `pg_index_deps` (0.7), PostgreSQL 15–18. Method: the C file and the SQL edition read for failure cases; each suspected case reproduced in a test before it was fixed; an external review of PR #1 (two rounds) checked against the code. Fixed in native 0.10.1 (PR #1, merge `6fc49dc`) and SQL edition 0.8 (PR #2, merge `6af2cb2`).

Severity: **P1** can make a used index look unused (and so get it dropped), fail a user's statement, or run code with the wrong privileges. **P2** wrong or lost data without that consequence. **P3** robustness, documentation.

## Native extension

| # | Sev | Finding | Effect | Fix | Commit | Test |
|---|---|---|---|---|---|---|
| N1 | P1 | With backend-local batching (0.6), a new (index, query) pair stayed in the session's pending table until its next statement or disconnect | An idle pooled connection that ran a rare query hid that use from everyone else, from the periodic snapshot and from a crash: `pg_index_usage` could say "no recorded use" for a used index | A pair not known to be in shared memory is flushed by the statement that recorded it; counts of known pairs stay batched | `a1d006d` | `006_review` 1–3 |
| N2 | P2 | A reset discarded only the caller's pending counts | Other sessions' pre-reset counts arrived after the reset | Pending entries carry the reset epoch; older ones are dropped at flush | `a1d006d` | `006_review` 3 |
| N3 | P1 | A statement with more than 64 distinct indexes dropped the rest silently | Those indexes looked unused for that query (partitioned tables, wide UNIONs) | Per-statement array grows; merged once at the end | `dabd85a` | `review` 2 |
| N4 | P2 | A bitmap index scan that never ran (one-time filter false) counted as executed | Overstated use (safe side) | PG 17+: planned only; PG 15/16 unchanged (documented) | `dabd85a` | `review` 1 |
| N5 | P1 | ALTER TABLE … ALTER COLUMN TYPE rebuilds indexes under new OIDs; their history stayed under the old OID | Recently altered tables' indexes looked unused | History moves to the rebuilt index when it is on the same table and prints the same definition; also SET EXPRESSION (PG 17+) | `d8e70fe`, `d0f7ff8` | `review` 3–4, `006_review` 6, 8 |
| N6 | P1 | The ALTER TABLE capture read index definitions before ALTER TABLE takes its locks; `pg_get_indexdef_string` errors on an index dropped meanwhile, and (found while testing the review's race finding) **waits for the table lock while holding an index lock** | A concurrent DROP INDEX could fail the user's ALTER; reproduced: capture held `g_pkey`, waited for `g` (deadlock risk) | `indexdef_nowait()`: table then index locked without waiting, re-checked; busy or gone means no carry-over, never a wait or error | `d8e70fe`, `d0f7ff8` | `006_review` 7 (failed before the fix) |
| N7 | P2 | The capture ran for every ALTER TABLE (flush, scan of all entries) | Cost on unrelated DDL (e.g. `SET (fillfactor)`) | Only ALTER COLUMN TYPE / SET EXPRESSION; skipped when the statement also adds or drops an index or constraint | `d0f7ff8` | `006_review` 6 |
| N8 | P2 | A reset or eviction between the known-pair check and its use left a pair trusted as known | That pair waited in the pending buffer: N1 again, narrowly | `change_count` re-checked after the decision; publish if it moved | `d0f7ff8` | `002_eviction` (eviction case) |
| N9 | P2 | A flush into an existing entry kept that entry's `first_seen` | `first_seen` was not the earliest sighting when the older one flushed last | Keep the minimum | `6793c5e` | `006_review` 2, `002_eviction` (out-of-order; mutation-checked) |
| N10 | P2 | Counter additions could wrap to negative | Negative counts after overflow | Saturating adds at int64 max | `6793c5e` | `006_review` 5 |
| N11 | P2 | The stats file loader accepted impossible records (invalid OID, toplevel byte not 0/1, negative counts, executed > planned, first_seen > last_seen, repeated keys, trailing bytes) | A damaged file loaded wrong counters | Whole file ignored with a LOG line; records past `max` are checked field by field (not for repeated keys, documented) | `6793c5e`, `d0f7ff8` | `006_review` 4 |
| N12 | P2 | The view function held the shared LWLock while building its result (tuplestore can spill to disk) | A slow reader held up every backend inserting a new pair or flushing on exit | Copy under the lock, build after releasing it | `ffc7541` | existing view tests |
| N13 | P3 | Reset comment said other backends' counts still arrive | Misleading | Corrected | `6f76244` | — |

Conservative behaviour introduced on purpose (documented in ARCHITECTURE and GUIDE): after an ALTER that rebuilds indexes, an index keeps no history when another session holds a conflicting lock at that moment, when its rebuilt definition prints differently (some expression indexes), or when the statement also adds or drops an index or constraint. No recorded use is then not evidence of no use.

## SQL edition

| # | Sev | Finding | Effect | Fix | Commit | Test |
|---|---|---|---|---|---|---|
| S1 | P1 | `index_drop_impact` planned other roles' query text as the caller; planning evaluates IMMUTABLE functions with constant arguments | A low-privileged role could record `… WHERE id = myschema.f()` and have a superuser's check run `f()` as superuser | Plan only queries recorded by a role with the caller's privileges; others skipped with a note, unless `p_trust_other_roles => true`. SET ROLE rejected: verified on PG 17 that code in the query undoes it | `c7473e7` | `security` |
| S2 | P1 | HypoPG and pg_stat_statements were called through the caller's search_path | A same-named function earlier in the path ran instead of `hypopg_hide_index` | Other extensions' objects found through their extension (`ext_function`, `ext_relation`); the function runs with `search_path = pg_catalog, pg_temp` except while explaining the query text | `c7473e7` | `security` |
| S3 | P2 | Query text with `;` (in a comment) was passed to EXECUTE | A second statement could run | Skipped, after removing one trailing `;` | `c7473e7` | `security` |
| S4 | P3 | `plan_source` naming a source that isn't installed gave a syntax error | Confusing error | Clear error | `c7473e7` | — |
| S5 | P1 | Found by the validation lab after S2's fix (lab E-no-hypopg): with HypoPG missing, `format('SELECT %s($1)', NULL)` gives `SELECT ($1)`, so the "HypoPG required" check never fired | Drop impact ran with the index still visible and reported "no change": a false "safe to drop" | Check the lookup before `format()` | this branch | `security` 4 |
| S6 | P1 | Found by the lab (E-unprivileged, PG 16–18): `ext_relation` found `pg_stat_index_queries` in a schema the role can't use | A role without access to the native extension's schema got "permission denied for schema" from drop impact (before S2 the object was simply not found) | Objects the caller may not use count as absent (USAGE on schema, SELECT / EXECUTE) | this branch | `security` 4, lab |
| S7 | P1 | Found by the Aurora run after release (v0.10.1): 0.8's `ext_function` read `pg_proc` to find `aurora_stat_plans`, which Aurora hides from `pg_proc` queries | On Aurora no plan source: empty dependents, verdicts "unknown", drop impact on text matching only. The lab had no check for this, only fewer PASS rows | Resolve the pg_catalog-qualified name (SQL edition 0.9); lab check `ENV-plan-source` | v0.10.2 | `security` 5, lab on Aurora 17.11 |

Behaviour change from S1: a superuser no longer gets the application role's queries planned in one call by default (decision in `docs/DECISIONS.md`, 29 Oct 2026).

## Reviewed and not changed

- Lookups before the ALTER capture's locks (`IndexGetRelation(…, true)`, `get_rel_relispartition`, `get_partition_ancestors`, `get_rel_name`) return nothing for a dropped index and cannot raise.
- Definition text as the identity of a rebuilt index: PostgreSQL rebuilds these indexes by running the old index's `pg_get_indexdef_string`, so equal text on the same table is the rebuilt index; anything else is treated as a different index.
- Capture cost on large hashes (review P2 follow-up): measured linear, ~0.1 ms per 1,000 entries per rebuilding ALTER; left as a follow-up (see PERFORMANCE_REPORT).

## Open

See `FIX_PLAN.md`.
