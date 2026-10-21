# Docker

```bash
# Playground with both extensions on PG 17 (localhost:55432, password postgres)
docker compose -f docker/docker-compose.yml up -d db
psql postgresql://postgres:postgres@localhost:55432/postgres

# Run all tests inside the container for a given PG version
PG_MAJOR=18 docker compose -f docker/docker-compose.yml run --rm test
```

PG 15: the SQL edition is skipped (pg_stat_plans and EXPLAIN GENERIC_PLAN need 16+). For the playground on 15, remove `pg_stat_plans` from `shared_preload_libraries` in `docker-compose.yml`.

> These files were written without access to a Docker daemon and have **not been built yet**. Report problems via an issue (or run task T01).
