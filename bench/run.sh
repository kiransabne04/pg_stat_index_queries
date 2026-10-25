#!/usr/bin/env bash
# Overhead benchmark: pgbench with and without pg_stat_index_queries.
# Runs a throwaway cluster in a temp directory. Run as a non-root user.
#
#   ./bench/run.sh [--scale 100] [--secs 300] [--runs 3] [--clients N] [--wide]
#                  [--only WORKLOAD] [--on-conf 'name=value ...']
#                  [--label NAME] [--note TEXT] [--out DIR]
#
# --on-conf: extra settings for the "on" mode only, e.g.
#   --on-conf 'pg_stat_index_queries.flush_interval=0'
#
# Modes are interleaved (run 1: off then on, run 2: on then off, ...) so cache
# warm-up, table bloat and checkpoints affect both modes equally. Each run
# starts from a CHECKPOINT and checks that the library really is (not) loaded.
#
# Writes <out>/<date>-<label>.md (default bench/results/<date>-<host>.md).
# See docs/BENCHMARK.md for the plan behind publishable numbers.
set -euo pipefail
PG_CONFIG=${PG_CONFIG:-pg_config}
BIN=$($PG_CONFIG --bindir)
HERE=$(cd "$(dirname "$0")" && pwd)
SCALE=100; SECS=300; RUNS=3; CLIENTS=$(nproc); WIDE=0
LABEL=$(hostname -s); NOTE=""; OUTDIR=$HERE/results; ONLY=""; ON_CONF=""
while [ $# -gt 0 ]; do case "$1" in
  --scale) SCALE=$2; shift 2;; --secs) SECS=$2; shift 2;; --runs) RUNS=$2; shift 2;;
  --clients) CLIENTS=$2; shift 2;; --wide) WIDE=1; shift;;
  --label) LABEL=$2; shift 2;; --note) NOTE=$2; shift 2;; --out) OUTDIR=$2; shift 2;;
  --only) ONLY=$2; shift 2;; --on-conf) ON_CONF=$2; shift 2;;
  *) echo "unknown arg $1"; exit 1;; esac; done

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

# set_mode off|on: restart with or without the library preloaded.
set_mode() {
  local libs="" extra=""
  [ "$1" = on ] && libs=pg_stat_index_queries
  if [ "$1" = on ]; then for kv in $ON_CONF; do extra="$extra -c $kv"; done; fi
  $BIN/pg_ctl -D $DIR/data -m fast stop >/dev/null 2>&1 || true
  $BIN/pg_ctl -D $DIR/data -l $DIR/log -w -o "-c shared_preload_libraries=$libs$extra" start >/dev/null
  local got
  got=$($BIN/psql $H -d postgres -XAtc "SHOW shared_preload_libraries")
  if [ "$got" != "$libs" ]; then echo "mode $1: expected '$libs', server has '$got'" >&2; exit 1; fi
}

set_mode off
$BIN/createdb $H bench
$BIN/pgbench $H -i -s $SCALE -q bench >/dev/null 2>&1
if [ $WIDE = 1 ]; then
  $BIN/psql $H -d bench -q -f "$HERE/wide_schema.sql"
fi

WORKLOADS="select_only tpcb"; [ $WIDE = 1 ] && WORKLOADS="$WORKLOADS wide"
[ -n "$ONLY" ] && WORKLOADS="$ONLY"
args_for() { case "$1" in
  select_only) echo "-n -S -M prepared";;
  tpcb) echo "-n -M prepared";;
  wide) echo "-n -M prepared -f $HERE/wide_workload.sql";; esac; }

OUT=$DIR/raw.csv
for i in $(seq 1 $RUNS); do
  if [ $((i % 2)) = 1 ]; then order="off on"; else order="on off"; fi
  for mode in $order; do
    set_mode $mode
    for w in $WORKLOADS; do
      $BIN/psql $H -d bench -XAqc "CHECKPOINT"
      tps=$($BIN/pgbench $H $(args_for $w) -c $CLIENTS -j $CLIENTS -T $SECS bench 2>/dev/null \
            | awk '/^tps/ {print $3; exit}')
      echo "$w,$mode,$i,$tps" | tee -a $OUT
    done
  done
done

mkdir -p "$OUTDIR"
RES="$OUTDIR/$(date +%Y-%m-%d)-$LABEL.md"
{
  echo "# pg_stat_index_queries overhead — $(date -u '+%Y-%m-%d %H:%M UTC')"
  echo
  [ -n "$NOTE" ] && { echo "> $NOTE"; echo; }
  echo "- Machine: $LABEL, $(nproc) vCPU, $(free -g 2>/dev/null | awk '/Mem/ {print $2}') GB RAM"
  cpu=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || true)
  [ -z "$cpu" ] && cpu=$(lscpu 2>/dev/null | awk -F: '/Model name/ {print $2; exit}' | xargs || true)
  [ "$cpu" = "-" ] && cpu=""   # VMs (e.g. Docker Desktop on Apple Silicon) hide the model
  echo "- CPU: ${cpu:-unknown ($(uname -m)); see note}"
  echo "- Kernel: $(uname -sr), arch $(uname -m)"
  echo "- PostgreSQL: $($BIN/postgres --version)"
  echo "- pgbench scale $SCALE, $CLIENTS clients, $RUNS × ${SECS}s per mode, modes interleaved"
  [ -n "$ON_CONF" ] && echo "- Settings in the \"on\" mode: \`$ON_CONF\`"
  echo
  echo "| Workload | Mean TPS off | Mean TPS on | Change | Spread off | Spread on |"
  echo "|---|---|---|---|---|---|"
  for w in $WORKLOADS; do
    # spread = (max - min) / mean across runs of one mode: the noise floor.
    stats() { awk -F, -v w=$w -v m=$1 '$1==w && $2==m {s+=$4; n++; if (n==1||$4<lo) lo=$4; if (n==1||$4>hi) hi=$4}
      END {printf "%.0f %.2f\n", s/n, (hi-lo)/(s/n)*100}' $OUT; }
    read off soff < <(stats off); read on son < <(stats on)
    chg=$(awk -v a=$off -v b=$on 'BEGIN {printf "%+.2f%%", (b-a)/a*100}')
    echo "| $w | $off | $on | $chg | ${soff}% | ${son}% |"
  done
  echo
  echo "A change smaller than the spread is noise."
  echo
  echo "Raw runs (workload, mode, run, tps):"
  echo '```'; cat $OUT; echo '```'
} > "$RES"
cat "$RES"
