#!/usr/bin/env bash
# Overhead benchmark: pgbench with and without pg_stat_index_queries.
# Runs a throwaway cluster in a temp directory. Run as a non-root user.
#
#   ./bench/run.sh [--scale 100] [--secs 300] [--runs 3] [--clients 8] [--wide]
#
# Writes bench/results/<date>-<host>.md
set -euo pipefail
PG_CONFIG=${PG_CONFIG:-pg_config}
BIN=$($PG_CONFIG --bindir)
SCALE=100; SECS=300; RUNS=3; CLIENTS=$(nproc); WIDE=0
while [ $# -gt 0 ]; do case "$1" in
  --scale) SCALE=$2; shift 2;; --secs) SECS=$2; shift 2;; --runs) RUNS=$2; shift 2;;
  --clients) CLIENTS=$2; shift 2;; --wide) WIDE=1; shift;; *) echo "unknown arg $1"; exit 1;; esac; done

DIR=$(mktemp -d); PORT=55433; H="-h $DIR -p $PORT"
trap '$BIN/pg_ctl -D $DIR/data -m fast stop >/dev/null 2>&1 || true; rm -rf $DIR' EXIT
$BIN/initdb -D $DIR/data >/dev/null
cat >> $DIR/data/postgresql.conf <<CONF
port = $PORT
unix_socket_directories = '$DIR'
shared_buffers = '1GB'
compute_query_id = on
max_connections = 200
CONF
start() { $BIN/pg_ctl -D $DIR/data -l $DIR/log -w restart >/dev/null 2>&1 || $BIN/pg_ctl -D $DIR/data -l $DIR/log -w start >/dev/null; }
start
$BIN/createdb $H bench
$BIN/pgbench $H -i -s $SCALE -q bench >/dev/null 2>&1

if [ $WIDE = 1 ]; then
  $BIN/psql $H -d bench -q -f "$(dirname "$0")/wide_schema.sql"
fi

run_set() {  # $1 = label, $2 = pgbench args
  for i in $(seq 1 $RUNS); do
    tps=$($BIN/pgbench $H $2 -c $CLIENTS -j $CLIENTS -T $SECS bench 2>/dev/null | awk '/^tps/ {print $3; exit}')
    echo "$1,$i,$tps"
  done
}

OUT=$DIR/raw.csv
for mode in off on; do
  if [ $mode = on ]; then
    echo "shared_preload_libraries = 'pg_stat_index_queries'" >> $DIR/data/postgresql.conf
    start
  fi
  run_set "select_only,$mode" "-n -S -M prepared" >> $OUT
  run_set "tpcb,$mode" "-n -M prepared" >> $OUT
  if [ $WIDE = 1 ]; then run_set "wide,$mode" "-n -M prepared -f $(dirname "$0")/wide_workload.sql" >> $OUT; fi
done

mkdir -p "$(dirname "$0")/results"
RES="$(dirname "$0")/results/$(date +%Y-%m-%d)-$(hostname -s).md"
{
  echo "# pg_stat_index_queries overhead — $(date -u '+%Y-%m-%d %H:%M UTC')"
  echo
  echo "- Host: $(hostname -s), $(nproc) vCPU, $(free -g | awk '/Mem/ {print $2}') GB RAM"
  echo "- CPU: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)"
  echo "- PostgreSQL: $($BIN/postgres --version)"
  echo "- pgbench scale $SCALE, $CLIENTS clients, $RUNS × ${SECS}s per mode"
  echo
  echo "| Workload | Mean TPS off | Mean TPS on | Change |"
  echo "|---|---|---|---|"
  for w in $(cut -d, -f1 $OUT | sort -u); do
    off=$(awk -F, -v w=$w '$1==w && $2=="off" {s+=$4; n++} END {printf "%.0f", s/n}' $OUT)
    on=$(awk -F, -v w=$w '$1==w && $2=="on" {s+=$4; n++} END {printf "%.0f", s/n}' $OUT)
    chg=$(awk -v a=$off -v b=$on 'BEGIN {printf "%+.2f%%", (b-a)/a*100}')
    echo "| $w | $off | $on | $chg |"
  done
  echo
  echo "Raw runs (workload, mode, run, tps):"
  echo '```'; cat $OUT; echo '```'
} > "$RES"
cat "$RES"
