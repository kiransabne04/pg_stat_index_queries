#!/bin/bash
set -e
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<'SQL'
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pg_stat_index_queries;
CREATE EXTENSION IF NOT EXISTS hypopg;
SQL
if [ "${PG_MAJOR:-0}" -ge 16 ]; then
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
    -c "CREATE EXTENSION IF NOT EXISTS pg_stat_plans; CREATE EXTENSION IF NOT EXISTS pg_index_deps;"
fi
