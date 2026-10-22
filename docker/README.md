# Docker

```bash
# Playground with both extensions on PG 17 (localhost:55432, password postgres)
docker compose -f docker/docker-compose.yml up -d db
psql postgresql://postgres:postgres@localhost:55432/postgres

# Run all tests inside the container for a given PG version
PG_MAJOR=18 docker compose -f docker/docker-compose.yml run --rm test
```

PG 15: the SQL edition is skipped (pg_stat_plans and EXPLAIN GENERIC_PLAN need 16+). For the playground on 15, remove `pg_stat_plans` from `shared_preload_libraries` in `docker-compose.yml`.

Verified on macOS arm64 (Docker 29.6) for PG 15, 16, 17 and 18 (22 Oct 2026). Each PG version gets its own image tag (`pg_stat_index_queries:pgNN`), so switching versions doesn't force a rebuild.

## Fast edit/test loop

The source is copied into the image, so `--build` is what picks up your edits. Only the last layers rebuild (a few seconds); the apt and pg_stat_plans layers stay cached. The build uses `COPT=-Werror`, so a compiler warning fails it.

```bash
# Everything for one version (native regression + TAP, then SQL edition on 16+)
PG_MAJOR=16 docker compose -f docker/docker-compose.yml run --rm --build test

# Only the native suites
PG_MAJOR=16 docker compose -f docker/docker-compose.yml run --rm --build test 'make installcheck'

# One SQL edition test
PG_MAJOR=16 docker compose -f docker/docker-compose.yml run --rm --build test 'make -C sql_edition installcheck REGRESS=parse'

# See the diff after a failure (the container is removed on exit, so print it in the same run)
PG_MAJOR=16 docker compose -f docker/docker-compose.yml run --rm --build test \
  'make -C sql_edition installcheck; cat sql_edition/regression.diffs'

# All four versions
for v in 15 16 17 18; do PG_MAJOR=$v docker compose -f docker/docker-compose.yml run --rm --build test || echo "PG $v FAILED"; done

# Rebuild the playground after an edit
docker compose -f docker/docker-compose.yml up -d --build db

# psql without installing a client on the host (or: brew install libpq)
docker compose -f docker/docker-compose.yml exec db psql -U postgres
```

## Smoke test in the playground

`examples/playground.sql` builds a synthetic `orders` schema (100k rows, a monthly-partitioned copy), runs a mixed workload and prints the dependency views and two drop-impact checks. It drops and recreates schema `playground` and resets the statistics, so it can be rerun.

```bash
docker compose -f docker/docker-compose.yml exec -T db psql -U postgres -X -f - < examples/playground.sql
```

`.dockerignore` keeps host build artifacts (`*.o`, `*.dylib`, `tmp_check/`, …) out of the image, so building natively on the host and in Docker don't interfere.
