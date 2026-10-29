# Installing

## 1. Self-hosted Postgres 15–18 (native extension)

Debian/Ubuntu (PGDG packages):

```bash
sudo apt-get install postgresql-server-dev-17 build-essential
make PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
sudo make install PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
```

`postgresql.conf` (restart required):

```
shared_preload_libraries = 'pg_stat_index_queries'   # add to any existing list
compute_query_id = on                                 # or auto
#pg_stat_index_queries.max = 10000
#pg_stat_index_queries.track = top
#pg_stat_index_queries.save = on
#pg_stat_index_queries.save_interval = 300s
```

```sql
CREATE EXTENSION pg_stat_index_queries;
```

Do the same on each replica: each server only sees the queries it runs.

**Upgrading 0.1 → 0.2:** install the new build, restart, then `ALTER EXTENSION pg_stat_index_queries UPDATE TO '0.2';`.

**Upgrading 0.2 → 0.3:** install the new build, then `ALTER EXTENSION pg_stat_index_queries UPDATE TO '0.3';`. Only the `pg_index_no_dependents` view changes, so no restart is needed.

**Upgrading 0.3 → 0.4:** `ALTER EXTENSION pg_stat_index_queries UPDATE TO '0.4';` (adds `pg_index_query_stats`; SQL only, no restart). The view needs pg_stat_statements when you query it.

**Upgrading 0.5 → 0.6:** install the new build, **restart** (the library changed: backend-local batching and sampling), then `ALTER EXTENSION pg_stat_index_queries UPDATE TO '0.6';`. Saved counters from 0.5 are kept across the restart. New settings `flush_interval` and `sample_rate`; see README.

**Upgrading 0.7 → 0.8:** install the new build, **restart** (the library changed: entries now record index columns), then `ALTER EXTENSION pg_stat_index_queries UPDATE TO '0.8';`. Saved counters from 0.7 are kept across the restart, marked `columns_complete = false`; `pg_stat_index_queries_reset()` starts a complete column record. The update drops and recreates `pg_stat_index_queries`, `pg_index_dependents`, `pg_index_dependents_rollup`, `pg_index_no_dependents` and `pg_index_usage` (the function's result type changes), so your own views on them must be dropped first. New view `pg_index_column_usage`.

**Upgrading 0.8 → 0.9:** no restart (SQL only): `ALTER EXTENSION pg_stat_index_queries UPDATE TO '0.9';`. Adds the view `pg_index_sole_path`; nothing is dropped.

**Upgrading 0.10 → 0.10.1:** install the new build and **restart**. No `ALTER EXTENSION`: no SQL objects changed, and the extension version stays `0.10`. Saved counters are kept.

**Upgrading 0.9 → 0.10:** install the new build, **restart** (the library changed), then `ALTER EXTENSION pg_stat_index_queries UPDATE TO '0.10';` (replaces `pg_index_role`; nothing is dropped). Saved counters are kept.
- New setting `save_interval` (default 300 s): counters are also saved every 5 minutes to `pg_stat_tmp/`, so a crash loses at most that much. `save_interval = 0` keeps the old behaviour.
- One extra process, `pg_stat_index_queries saver`, shows up in `ps` (not in `pg_stat_activity`: it has no database connection). It takes one `max_worker_processes` slot (default 8, shared with parallel query and logical replication); raise `max_worker_processes` by one if you rely on every slot.
- Cursor queries (`DECLARE` / `FETCH` / `CLOSE`) are now recorded, and plain EXPLAIN isn't.
- Indexes that serve a foreign key's checks now get a `drop_blocker`, so `pg_index_usage` no longer calls them drop candidates.

**SQL edition 0.6 → 0.7:** `ALTER EXTENSION pg_index_deps UPDATE TO '0.7';` (or rerun `install_pg_tle.sql`, then `ALTER EXTENSION pg_index_deps UPDATE`). Same foreign-key change in `index_deps.index_role`.

**SQL edition 0.7 → 0.8:** `ALTER EXTENSION pg_index_deps UPDATE TO '0.8';` (or rerun `install_pg_tle.sql`, then `ALTER EXTENSION pg_index_deps UPDATE`). Security fixes in `index_drop_impact`: queries recorded only by roles without your privileges are now skipped (`note` says which role; pass `p_trust_other_roles => true` to plan them anyway, or run the check connected as that role), and HypoPG / pg_stat_statements are found through their extension, not your search_path. The function is dropped and recreated with a new last parameter; your own objects that depend on it must be dropped first.

**Upgrading 0.6 → 0.7:** `ALTER EXTENSION pg_stat_index_queries UPDATE TO '0.7';` (adds `pg_index_table_stats`, `pg_index_column_stats` and `pg_index_hints()`; `pg_index_usage` gains a last column `hints`). SQL only, no restart.

**Upgrading 0.4 → 0.5:** `ALTER EXTENSION pg_stat_index_queries UPDATE TO '0.5';` (adds `pg_index_role()` and `pg_index_usage`; `pg_index_dependents` gains `index_role`; `pg_index_query_stats` gains `index_role` and `index_notes` after `is_partial`, so `SELECT *` column positions change). SQL only, no restart.

## 2. Self-hosted, SQL edition (optional)

Needs pg_stat_plans (PG 16+) for plan capture and HypoPG for the drop-impact check.

```bash
sudo apt-get install postgresql-17-hypopg
git clone https://github.com/pganalyze/pg_stat_plans && make -C pg_stat_plans && sudo make -C pg_stat_plans install
make -C sql_edition install
```

```
shared_preload_libraries = 'pg_stat_statements,pg_stat_plans,pg_stat_index_queries'
```

```sql
CREATE EXTENSION pg_stat_statements;
CREATE EXTENSION pg_stat_plans;
CREATE EXTENSION hypopg;
CREATE EXTENSION pg_index_deps;
```

## 3. Amazon Aurora PostgreSQL (SQL edition)

Requires Aurora PostgreSQL 14.10, 15.5 or later for `aurora_stat_plans`; the drop-impact check needs 16+.

1. **Cluster parameter group:** `shared_preload_libraries` includes `pg_stat_statements`; set `aurora_compute_plan_id = on`. Reboot if `shared_preload_libraries` changed.
2. Connect as the master user (or a role with `rds_superuser` for the extensions):
   ```sql
   CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
   CREATE EXTENSION IF NOT EXISTS hypopg;
   ```
3. Install the SQL edition, either plain:
   ```bash
   psql "$AURORA_URL" -f sql_edition/install.sql
   ```
   or through pg_tle (lets you `CREATE EXTENSION` / `ALTER EXTENSION UPDATE` later):
   ```sql
   CREATE EXTENSION IF NOT EXISTS pg_tle;   -- pg_tle must be in shared_preload_libraries
   GRANT pgtle_admin TO CURRENT_USER;       -- the master user lacks it by default (seen on Aurora 17.9)
   \i sql_edition/install_pg_tle.sql
   CREATE EXTENSION pg_index_deps;
   ```
   SQL edition 0.6 adds `index_deps.index_table_stats`, `index_column_stats` and `index_hints()`; `index_usage` gains a last column `hints`, and `index_drop_impact`'s `note` warns when the table's statistics are stale or missing.
   SQL edition 0.5 only rewrites internal queries with column lists (no `SELECT *`); nothing changes for users.
   Upgrading to SQL edition 0.4 changes `index_drop_impact`: new last column `drop_blocker`, and `p_timeout_ms` is now a budget for the whole call (default 30000) instead of a per-query timeout that never took effect.
   To upgrade a pg_tle install later, run the newer `install_pg_tle.sql` (it registers the missing update paths and the new default version) and then `ALTER EXTENSION pg_index_deps UPDATE;`.
   The plain install has no upgrade path: `DROP SCHEMA index_deps CASCADE;`, run the newer `install.sql`, and set `plan_source` again if you had changed it.
4. Grant read access to whoever investigates: `GRANT pg_read_all_stats TO analyst;` (to see all statements and plans).
5. Check: `SELECT index_deps.resolved_plan_source();` should return `aurora_stat_plans`.

> Verified on Aurora PostgreSQL 17.9.5 (express configuration) and RDS for PostgreSQL 17.11 on 24 Oct 2026; see `docs/TESTING.md` and [AURORA-VALIDATION.md](AURORA-VALIDATION.md). Free-plan accounts get express configuration only: attach your cluster parameter group (with `aurora_compute_plan_id = on`) after creation and reboot, and connect as `postgres` with an IAM auth token (`aws rds generate-db-auth-token`).

## 4. Amazon RDS for PostgreSQL

RDS has no per-plan source, so the dependency views are empty there (since SQL edition 0.2 that includes `index_no_dependents`; 0.1 listed every index there, so upgrade before relying on it). The **drop-impact check still works** (PG 16+): with no captured plans it falls back to every statement in pg_stat_statements that mentions the index's table. `index_query_stats` is empty there too, since it is built on the dependency view.

```sql
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS hypopg;
\i sql_edition/install.sql
SELECT queryid, cost_ratio, plan_changed, note, drop_blocker FROM index_deps.index_drop_impact('public.my_idx');
```

## Removing

```sql
DROP EXTENSION pg_stat_index_queries;     -- then remove it from shared_preload_libraries and restart
DROP EXTENSION pg_index_deps;             -- or DROP SCHEMA index_deps CASCADE for the plain install
```
