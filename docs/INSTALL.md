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
```

```sql
CREATE EXTENSION pg_stat_index_queries;
```

Do the same on each replica: each server only sees the queries it runs.

**Upgrading 0.1 → 0.2:** install the new build, restart, then `ALTER EXTENSION pg_stat_index_queries UPDATE TO '0.2';`.

**Upgrading 0.2 → 0.3:** install the new build, then `ALTER EXTENSION pg_stat_index_queries UPDATE TO '0.3';`. Only the `pg_index_no_dependents` view changes, so no restart is needed.

**Upgrading 0.3 → 0.4:** `ALTER EXTENSION pg_stat_index_queries UPDATE TO '0.4';` (adds `pg_index_query_stats`; SQL only, no restart). The view needs pg_stat_statements when you query it.

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
   \i sql_edition/install_pg_tle.sql
   CREATE EXTENSION pg_index_deps;
   ```
   To upgrade a pg_tle install later, run the newer `install_pg_tle.sql` (it registers the missing update paths and the new default version) and then `ALTER EXTENSION pg_index_deps UPDATE;`.
   The plain install has no upgrade path: `DROP SCHEMA index_deps CASCADE;`, run the newer `install.sql`, and set `plan_source` again if you had changed it.
4. Grant read access to whoever investigates: `GRANT pg_read_all_stats TO analyst;` (to see all statements and plans).
5. Check: `SELECT index_deps.resolved_plan_source();` should return `aurora_stat_plans`.

> The Aurora path has **not yet been run against a live cluster** (see `docs/TESTING.md`). If `index_deps.plan_source()` errors on column names, compare with `SELECT * FROM aurora_stat_plans(true) LIMIT 1` and fix the adapter; task `codex/tasks/T05-aurora-validation.md` covers this. Step-by-step validation run: [AURORA-VALIDATION.md](AURORA-VALIDATION.md).

## 4. Amazon RDS for PostgreSQL

RDS has no per-plan source, so the dependency views are empty there (since SQL edition 0.2 that includes `index_no_dependents`; 0.1 listed every index there, so upgrade before relying on it). The **drop-impact check still works** (PG 16+): with no captured plans it falls back to every statement in pg_stat_statements that mentions the index's table. `index_query_stats` is empty there too, since it is built on the dependency view.

```sql
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS hypopg;
\i sql_edition/install.sql
SELECT * FROM index_deps.index_drop_impact('public.my_idx');
```

## Removing

```sql
DROP EXTENSION pg_stat_index_queries;     -- then remove it from shared_preload_libraries and restart
DROP EXTENSION pg_index_deps;             -- or DROP SCHEMA index_deps CASCADE for the plain install
```
