#!/usr/bin/env bash
# Index lab runner. Creates databases index_lab and index_lab2 on the target
# server, installs the extensions, runs lab.sql, writes the report, and drops
# both databases (unless --keep).
#
# Connection: standard libpq environment (PGHOST, PGPORT, PGUSER, PGPASSWORD
# or ~/.pgpass, PGSSLMODE). Never pass the password on the command line.
# PGPASSWORD_CMD, if set, is run before each psql to get a fresh password
# (e.g. an RDS IAM auth token, valid 15 minutes for new connections).
#
#   ./run.sh <label> [--simulate-rds] [--pg-tle] [--scale N] [--keep]
#                    [--admin-db postgres] [--out DIR]
#   ./run.sh <label> --reader          # reader phase, against a reader endpoint
#   ./run.sh <label> --teardown        # drop the lab databases only
#
# Output: DIR (default ./lab-out/<label>) gets lab.log, report.md,
# results.csv, plan_fixture.csv and, on Aurora, aurora_*.{jsonl,csv}.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"

label="${1:?usage: run.sh <label> [options]}"; shift
simulate_rds=0 pg_tle=0 scale=1 keep=0 admin_db=postgres out="" mode=full
while [ $# -gt 0 ]; do
  case "$1" in
    --simulate-rds) simulate_rds=1 ;;
    --pg-tle) pg_tle=1 ;;
    --scale) scale="$2"; shift ;;
    --keep) keep=1 ;;
    --admin-db) admin_db="$2"; shift ;;
    --out) out="$2"; shift ;;
    --reader) mode=reader ;;
    --teardown) mode=teardown ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
out="${out:-$PWD/lab-out/$label}"
if [ "$mode" != teardown ]; then
  mkdir -p "$out"
  out="$(cd "$out" && pwd)"
fi

refresh_password() {
  if [ -n "${PGPASSWORD_CMD:-}" ]; then
    PGPASSWORD="$(eval "$PGPASSWORD_CMD")"; export PGPASSWORD
  fi
}
psql_admin() { refresh_password; psql -X -v ON_ERROR_STOP=1 -d "$admin_db" "$@"; }
psql_lab()   { refresh_password; psql -X -v ON_ERROR_STOP=1 -d index_lab "$@"; }

teardown() {
  psql_admin -q -c 'DROP DATABASE IF EXISTS index_lab WITH (FORCE)' \
                -c 'DROP DATABASE IF EXISTS index_lab2 WITH (FORCE)'
  echo "dropped databases index_lab, index_lab2"
}

case "$mode" in
  teardown) teardown; exit 0 ;;
  reader)
    cd "$out"
    psql_lab -v label="$label" -f "$here/reader.sql" 2>&1 | tee reader.log
    exit "${PIPESTATUS[0]}"
    ;;
esac

{
  echo "=== index lab: $label ($(date -u +%FT%TZ)), repo $(git -C "$repo" rev-parse --short HEAD 2>/dev/null || echo '?')"
  psql_admin -q -c 'DROP DATABASE IF EXISTS index_lab WITH (FORCE)' \
                -c 'DROP DATABASE IF EXISTS index_lab2 WITH (FORCE)' \
                -c 'CREATE DATABASE index_lab' \
                -c 'CREATE DATABASE index_lab2'

  echo "=== install extensions"
  psql_lab -q <<'SQL'
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'hypopg') THEN
        CREATE EXTENSION IF NOT EXISTS hypopg;
    ELSE
        RAISE WARNING 'hypopg not available: drop-impact checks will be skipped';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_stat_plans') THEN
        CREATE EXTENSION IF NOT EXISTS pg_stat_plans;
    END IF;
    -- Native extension as ground truth, in its own schema so that
    -- index_drop_impact (which looks it up on the search_path) still uses
    -- the captured-plans path it uses on Aurora.
    IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_stat_index_queries')
       AND current_setting('shared_preload_libraries') LIKE '%pg_stat_index_queries%' THEN
        CREATE SCHEMA lab_native;
        CREATE EXTENSION pg_stat_index_queries SCHEMA lab_native;
    END IF;
END $$;
SQL
  if [ "$pg_tle" = 1 ]; then
    # Registering an extension with pg_tle needs the pgtle_admin role, which
    # the RDS/Aurora master user doesn't have by default.
    psql_lab -q -c 'CREATE EXTENSION IF NOT EXISTS pg_tle' -c 'GRANT pgtle_admin TO CURRENT_USER'
    psql_lab -q \
                -f "$repo/sql_edition/install_pg_tle.sql" \
                -c 'CREATE EXTENSION pg_index_deps'
  else
    psql_lab -q -f "$repo/sql_edition/install.sql"
  fi
  psql_lab -Atc "SELECT 'plan source: ' || index_deps.resolved_plan_source()"

  echo "=== run lab.sql"
  cd "$out"
  args=(-v label="$label" -v scale="$scale")
  [ "$simulate_rds" = 1 ] && args+=(-v simulate_rds=1)
  psql_lab "${args[@]}" -f "$here/lab.sql"
} 2>&1 | tee "$out/lab.log"
status="${PIPESTATUS[0]}"

if [ "$keep" = 1 ]; then
  echo "kept databases index_lab, index_lab2 (run with --teardown to drop)"
else
  teardown
fi
echo "output: $out"
exit "$status"
