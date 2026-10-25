#!/usr/bin/env bash
# CPU profile of pgbench -S with the extension loaded: where the per-statement
# cost goes (hooks, plan walk, local counting). Linux with perf installed.
#
#   ./bench/profile.sh [--secs 60] [--scale 100] [--conf 'name=value ...'] [--label NAME]
#
# Writes bench/results/<date>-<label>-profile.txt: the extension's functions
# with their share of all samples, and the top symbols overall.
set -euo pipefail
PG_CONFIG=${PG_CONFIG:-pg_config}
BIN=$($PG_CONFIG --bindir)
HERE=$(cd "$(dirname "$0")" && pwd)
SECS=60; SCALE=100; CONF=""; LABEL=$(hostname -s)
while [ $# -gt 0 ]; do case "$1" in
  --secs) SECS=$2; shift 2;; --scale) SCALE=$2; shift 2;;
  --conf) CONF=$2; shift 2;; --label) LABEL=$2; shift 2;;
  *) echo "unknown arg $1"; exit 1;; esac; done
command -v perf >/dev/null || { echo "perf not found"; exit 1; }

DIR=$(mktemp -d); PORT=55434; H="-h $DIR -p $PORT"
trap '$BIN/pg_ctl -D $DIR/data -m fast stop >/dev/null 2>&1 || true; rm -rf $DIR' EXIT
$BIN/initdb -D $DIR/data >/dev/null
cat >> $DIR/data/postgresql.conf <<CONF
port = $PORT
unix_socket_directories = '$DIR'
shared_buffers = '1GB'
compute_query_id = on
shared_preload_libraries = 'pg_stat_index_queries'
CONF
for kv in $CONF; do echo "$kv" | sed 's/=/ = /' >> $DIR/data/postgresql.conf; done
$BIN/pg_ctl -D $DIR/data -l $DIR/log -w start >/dev/null
$BIN/createdb $H bench
$BIN/pgbench $H -i -s $SCALE -q bench >/dev/null 2>&1
# Warm up, then profile the whole machine while pgbench runs.
$BIN/pgbench $H -n -S -M prepared -c "$(nproc)" -j "$(nproc)" -T 20 bench >/dev/null 2>&1
$BIN/pgbench $H -n -S -M prepared -c "$(nproc)" -j "$(nproc)" -T "$SECS" bench > $DIR/pgbench.out 2>&1 &
sleep 2
sudo perf record -F 999 -a -g -o $DIR/perf.data -- sleep $((SECS - 5)) >/dev/null 2>&1
wait
sudo chown "$(id -u)" $DIR/perf.data

mkdir -p "$HERE/results"
OUT="$HERE/results/$(date +%Y-%m-%d)-$LABEL-profile.txt"
{
  echo "# perf profile: pgbench -S -M prepared, $(nproc) clients, ${SECS}s, scale $SCALE"
  echo "# $($BIN/postgres --version); settings: ${CONF:-defaults}; $(date -u '+%Y-%m-%d %H:%M UTC')"
  grep -E '^tps' $DIR/pgbench.out || true
  echo
  echo "## Share of all samples by shared object (self time)"
  perf report -i $DIR/perf.data --stdio --no-children --sort dso 2>/dev/null | grep -E '^ +[0-9]' | head -15
  echo
  echo "## pg_stat_index_queries functions (self time, % of all samples)"
  perf report -i $DIR/perf.data --stdio --no-children --sort dso,sym 2>/dev/null \
    | grep -E 'pg_stat_index_queries' | grep -E '^ +[0-9]' | head -20
  echo
  echo "## pg_stat_index_queries functions including what they call (children, % of all samples)"
  perf report -i $DIR/perf.data --stdio --children --sort dso,sym 2>/dev/null \
    | grep -E 'pg_stat_index_queries\.so' | grep -E '^ +[0-9]' | head -20
  echo
  echo "## Top 25 symbols overall (self time)"
  perf report -i $DIR/perf.data --stdio --no-children --sort dso,sym 2>/dev/null | grep -E '^ +[0-9]' | head -25
} > "$OUT"
cat "$OUT"
