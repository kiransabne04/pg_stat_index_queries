# T09 — Save counters periodically, so a crash loses minutes, not everything

**Status: done 27 Oct 2026** (native 0.9.1: library only, no SQL change).

## Why
Counters are written only at clean shutdown (guide, "Where the answers stop being reliable" #2). A crash, an OOM kill or a failover loses the whole tracking window. A long window is what makes "no recorded use" believable, so one crash months in resets the answer to "can I drop this?".

## Scope
Native extension only. No new SQL objects, so `default_version` stays 0.9; the file format stays 3.

## Spec
1. New GUC `pg_stat_index_queries.save_interval` (seconds, default 300, 0..86400, `PGC_SIGHUP`). 0 = save only at clean shutdown (the 0.9 behaviour).
2. A background worker `pg_stat_index_queries saver` (shared memory only, no database connection) is registered when the library is preloaded. Every `save_interval` it writes the counters to the stats file with the same writer as shutdown: `.tmp`, then `durable_rename`. It skips the write when nothing has changed since its last save.
3. Startup: the file is loaded as before. With `save_interval > 0` it is kept after loading (it is the last snapshot); with 0 it is removed after loading, as in 0.9.
4. After a crash, the postmaster re-creates shared memory and loads the last snapshot. Counts since that snapshot (at most `save_interval`, plus `flush_interval`) are lost; `tracked_since` is unchanged.
5. `pg_stat_index_queries_reset()` removes the file, and a save that copied its counters before the reset must not rename them into place afterwards (reset counter checked under the lock before the rename).
6. `save = off`: the worker writes nothing and removes the file.
7. Locking: the worker copies entries under the shared lock (per-entry spinlock), writes the file without the lock, and renames under the shared lock. Backends' non-forced flushes never wait.
8. Never errors a user's query; write failures are LOG messages.

## Acceptance
- TAP `005_periodic_save`: counts survive a real crash (process killed with SIGKILL) once the worker has saved; `save_interval = 0` keeps the 0.9 crash behaviour (no counters after a crash); a reset followed by a crash does not bring back pre-reset counts; `save = off` removes the file.
- `001_persistence` crash check runs with `save_interval = 0` (unchanged assertion).
- Tests pass on PG 15–18. Build warning-free.
- Docs: GUIDE (settings, limit #2), README settings, ARCHITECTURE persistence, DECISIONS, CHANGELOG, ROADMAP.
