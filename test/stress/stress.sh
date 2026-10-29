#!/bin/bash
# Stress pg_stat_index_queries on an assert + ASan/UBSan build
# (test/stress/Dockerfile). Runs as postgres inside that image. DUR seconds
# per phase (default 60). Prints a summary; exits 1 on any finding.
#
# Phases run reads (dynamic SQL in PL/pgSQL: many query IDs, eviction with
# max = 200), FK cascades, cursors, sampling / flush_interval / EXPLAIN /
# parallel queries and the views, while a noise loop resets, runs ALTER
# COLUMN TYPE (index rebuilds) and REINDEX
# (CONCURRENTLY), drops and recreates indexes, reloads save_interval, and
# cancels and terminates backends. Between phases: kill -9 (crash restart),
# kill -9 of the saver, a corrupt snapshot, fast restarts under load, and a
# final check that counters survive a crash. Findings: TRAP (assertion),
# PANIC, stuck spinlock, sanitizer reports, a process killed by a signal
# other than ours, the server not coming back, or lost counters.
set -u
D=/tmp/stress; rm -rf $D; mkdir -p $D
PGDATA=$D/data; export PGHOST=$D PGPORT=55500 PGDATABASE=postgres
DUR=${DUR:-60}
initdb -D $PGDATA -A trust >/dev/null
cat >> $PGDATA/postgresql.conf <<CONF
port = $PGPORT
unix_socket_directories = '$D'
shared_preload_libraries = 'pg_stat_statements,pg_stat_index_queries'
compute_query_id = on
max_connections = 120
pg_stat_index_queries.max = 200
pg_stat_index_queries.track = all
pg_stat_index_queries.save_interval = 1
pg_stat_index_queries.flush_interval = 200
max_worker_processes = 16
max_parallel_workers_per_gather = 2
restart_after_crash = on
log_min_messages = warning
log_line_prefix = '%m [%p] %b '
CONF
pg_ctl -D $PGDATA -l $D/log -w start >/dev/null || { cat $D/log; exit 1; }

psql -qX <<'SQL' >/dev/null
CREATE EXTENSION pg_stat_statements;
CREATE EXTENSION pg_stat_index_queries;
CREATE TABLE parent (id int PRIMARY KEY, v int);
CREATE TABLE child (id serial PRIMARY KEY, pid int REFERENCES parent ON DELETE CASCADE, v int);
CREATE INDEX child_pid_idx ON child (pid);
INSERT INTO parent SELECT g, g FROM generate_series(1, 20000) g;
INSERT INTO child (pid, v) SELECT g % 20000 + 1, g FROM generate_series(1, 100000) g;
CREATE TABLE ev (id int, at date, v int) PARTITION BY RANGE (at);
CREATE TABLE ev1 PARTITION OF ev FOR VALUES FROM ('2026-01-01') TO ('2026-07-01');
CREATE TABLE ev2 PARTITION OF ev FOR VALUES FROM ('2026-07-01') TO ('2027-01-01');
CREATE INDEX ev_at_idx ON ev (at);
INSERT INTO ev SELECT g, date '2026-01-01' + g % 360, g FROM generate_series(1, 50000) g;
-- 40 tables x 3 indexes; queries built dynamically give many query IDs
-- (forces eviction with max = 200).
DO $$ BEGIN
  FOR i IN 1..40 LOOP
    EXECUTE format('CREATE TABLE t%s (id int PRIMARY KEY, a int, b int, c int)', i);
    EXECUTE format('CREATE INDEX t%s_a ON t%s (a)', i, i);
    EXECUTE format('CREATE INDEX t%s_bc ON t%s (b, c)', i, i);
    EXECUTE format('INSERT INTO t%s SELECT g, g %% 97, g %% 13, g %% 7 FROM generate_series(1, 3000) g', i);
  END LOOP;
END $$;
CREATE FUNCTION q(i int, k int) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE r bigint;
BEGIN
  CASE k % 4
    WHEN 0 THEN EXECUTE format('SELECT count(*) FROM t%s WHERE a = $1', i) INTO r USING k % 97;
    WHEN 1 THEN EXECUTE format('SELECT count(*) FROM t%s WHERE b = $1 AND c = $2', i) INTO r USING k % 13, k % 7;
    WHEN 2 THEN EXECUTE format('SELECT count(*) FROM t%s WHERE id = $1 OR a = $2', i) INTO r USING k, k % 97;
    ELSE EXECUTE format('SELECT count(*) FROM t%s x JOIN t%s y ON y.id = x.a WHERE x.b = $1', i, i % 40 + 1) INTO r USING k % 13;
  END CASE;
  RETURN r;
END $$;
ANALYZE;
SQL

cat > $D/read.sql <<'SQL'
\set i random(1, 40)
\set k random(1, 100000)
SELECT q(:i, :k);
SELECT v FROM parent WHERE id = :k % 20000 + 1;
SELECT count(*) FROM child WHERE pid = :k % 20000 + 1;
SELECT count(*) FROM ev WHERE at = date '2026-01-01' + :k % 360;
SQL
cat > $D/write.sql <<'SQL'
\set k random(1, 20000)
BEGIN;
DELETE FROM parent WHERE id = :k;
INSERT INTO parent VALUES (:k, :k) ON CONFLICT DO NOTHING;
INSERT INTO child (pid, v) VALUES (:k, 1);
UPDATE child SET v = v + 1 WHERE pid = :k;
COMMIT;
SQL
cat > $D/cursor.sql <<'SQL'
\set k random(1, 20000)
BEGIN;
DECLARE c CURSOR FOR SELECT id FROM child WHERE pid = :k;
FETCH 2 FROM c;
CLOSE c;
DECLARE d CURSOR WITH HOLD FOR SELECT v FROM parent WHERE id = :k;
COMMIT;
FETCH ALL FROM d;
CLOSE d;
SQL
cat > $D/misc.sql <<'SQL'
\set k random(1, 20000)
SET pg_stat_index_queries.sample_rate = 0.3;
SELECT v FROM parent WHERE id = :k;
RESET pg_stat_index_queries.sample_rate;
SET pg_stat_index_queries.flush_interval = 0;
SELECT v FROM parent WHERE id = :k;
RESET pg_stat_index_queries.flush_interval;
EXPLAIN SELECT v FROM parent WHERE id = :k;
EXPLAIN (ANALYZE, TIMING OFF) SELECT count(*) FROM child WHERE pid = :k;
SET parallel_setup_cost = 0; SET parallel_tuple_cost = 0; SET min_parallel_index_scan_size = 0;
SELECT count(*) FROM child WHERE id < 90000;
RESET ALL;
SQL
cat > $D/views.sql <<'SQL'
SELECT count(*) FROM pg_stat_index_queries;
SELECT count(*) FROM pg_index_usage;
SELECT count(*) FROM pg_index_dependents_rollup;
SELECT count(*) FROM pg_index_sole_path;
SELECT count(*) FROM pg_index_column_usage;
SELECT count(*) FROM pg_index_query_stats;
SELECT entries, dealloc FROM pg_stat_index_queries_info;
SQL

# --max-tries + --failures-detailed: cancels and terminations abort a client,
# so each phase restarts pgbench per client group until the time is up.
run() {
  local end=$((SECONDS + $1)) n=0
  while [ $SECONDS -lt $end ]; do
    pgbench -n -T $((end - SECONDS)) -c "$2" -j "$2" -f "$3" postgres >> $D/pgbench_$(basename $3).out 2>&1
    n=$((n + 1))
  done
}

# Maintenance noise, in the background for the whole run.
noise() {
  local end=$((SECONDS + DUR))
  while [ $SECONDS -lt $end ]; do
    i=$((RANDOM % 40 + 1))
    case $((RANDOM % 11)) in
      0) psql -qXc "SELECT pg_stat_index_queries_reset()" >/dev/null 2>&1 ;;
      1) psql -qXc "REINDEX INDEX CONCURRENTLY t${i}_a" >/dev/null 2>&1 ;;
      2) psql -qXc "REINDEX TABLE CONCURRENTLY t${i}" >/dev/null 2>&1 ;;
      3) psql -qXc "DROP INDEX IF EXISTS t${i}_bc; CREATE INDEX IF NOT EXISTS t${i}_bc ON t${i} (b, c)" >/dev/null 2>&1 ;;
      4) psql -qXc "REINDEX INDEX t${i}_a" >/dev/null 2>&1 ;;
      5) psql -qXc "ALTER SYSTEM SET pg_stat_index_queries.save_interval = $((RANDOM % 3))" -c "SELECT pg_reload_conf()" >/dev/null 2>&1 ;;
      6) psql -qXc "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE backend_type = 'client backend' AND pid <> pg_backend_pid() AND random() < 0.2" >/dev/null 2>&1 ;;
      7) psql -qXc "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE backend_type = 'client backend' AND pid <> pg_backend_pid() AND random() < 0.05" >/dev/null 2>&1 ;;
      8) psql -qXc "REINDEX INDEX CONCURRENTLY ev_at_idx" >/dev/null 2>&1 ;;
      # ALTER COLUMN TYPE rebuilds indexes under new OIDs (history carried
      # over, 0.10.1); on b it races case 3's DROP/CREATE of t_bc.
      9) psql -qXc "ALTER TABLE t${i} ALTER COLUMN a TYPE $([ $((RANDOM % 2)) = 0 ] && echo bigint || echo int)" >/dev/null 2>&1 ;;
      10) psql -qXc "ALTER TABLE t${i} ALTER COLUMN b TYPE $([ $((RANDOM % 2)) = 0 ] && echo bigint || echo int)" >/dev/null 2>&1 ;;
    esac
    sleep 0.2
  done
}

phase() {
  echo "phase: $1 at $(date -u +%T)"
  noise & NP=$!
  run $DUR 16 $D/read.sql & P1=$!
  run $DUR 6 $D/write.sql & P2=$!
  run $DUR 4 $D/cursor.sql & P3=$!
  run $DUR 4 $D/misc.sql & P4=$!
  run $DUR 2 $D/views.sql & P5=$!
  wait $P1 $P2 $P3 $P4 $P5 $NP
}

alive() { for _ in $(seq 1 60); do psql -qXAtc "SELECT 1" >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }

phase "load"
echo "kill -9 a backend (crash restart)"
pid=$(psql -qXAtc "SELECT pid FROM pg_stat_activity WHERE backend_type = 'checkpointer'")
echo "  kill checkpointer at $(date -u +%T)"; kill -9 "$pid"; sleep 3; alive || { echo "FINDING: server not back after crash"; touch $D/finding; }
phase "after crash"
echo "kill -9 the saver while it runs"
for _ in 1 2 3; do
  spid=$(pgrep -f 'pg_stat_index_queries saver' | head -1)
  [ -n "$spid" ] && { echo "  kill saver at $(date -u +%T)"; kill -9 "$spid"; }; sleep 2; alive || { echo "FINDING: server not back after saver kill"; touch $D/finding; }
done
echo "corrupt snapshot, then crash"
pg_ctl -D $PGDATA -m immediate stop >/dev/null
head -c 37 /dev/urandom > $PGDATA/pg_stat_tmp/pg_stat_index_queries.snap
pg_ctl -D $PGDATA -l $D/log -w start >/dev/null || { echo "FINDING: start failed with corrupt snapshot"; touch $D/finding; }
alive || { echo "FINDING: not up after corrupt snapshot"; touch $D/finding; }
echo "fast restarts under load"
( run 30 8 $D/read.sql ) & RP=$!
for _ in 1 2 3; do sleep 6; pg_ctl -D $PGDATA -m fast -w restart -l $D/log >/dev/null || { echo "FINDING: restart failed"; touch $D/finding; }; done
wait $RP
alive || { echo "FINDING: not up after restarts"; touch $D/finding; }
phase "final"
# The phases end with crash recovery sometimes in progress: wait, retry, verify.
alive
for _ in $(seq 1 10); do
  psql -qXc "ALTER SYSTEM SET pg_stat_index_queries.save_interval = 1" -c "SELECT pg_reload_conf()" >/dev/null 2>&1 && break
  sleep 1; alive
done
grep -q "save_interval = '1'" $PGDATA/postgresql.auto.conf || { echo "FINDING: harness could not set save_interval"; touch $D/finding; }
sleep 1
run 5 8 $D/read.sql
psql -qXAtc "SELECT 'entries=' || entries || ' dealloc=' || dealloc FROM pg_stat_index_queries_info"
psql -qXAtc "SELECT 'used indexes=' || count(*) FILTER (WHERE queries > 0) || ' of ' || count(*) FROM pg_index_usage"
# Evidence that the ALTER COLUMN TYPE noise ran (its output is discarded).
psql -qXAtc "SELECT 'bigint columns after ALTER noise=' || count(*) FROM pg_attribute WHERE attname IN ('a', 'b') AND atttypid = 'bigint'::regtype AND attrelid::regclass::text ~ '^t[0-9]+$'"
echo "crash after a save: counters must survive"
sleep 3
before=$(psql -qXAtc "SELECT entries FROM pg_stat_index_queries_info")
echo "saver running: $(pgrep -fc 'pg_stat_index_queries saver'); snapshot: $(ls -l $PGDATA/pg_stat_tmp/ | grep -c snap); save_interval at start: $(grep -h 'save_interval' $PGDATA/postgresql.auto.conf)"
echo "  snapshot before crash: $(ls -l --time-style=+%T.%N $PGDATA/pg_stat_tmp/ 2>&1 | grep snap)"
pid=$(psql -qXAtc "SELECT pid FROM pg_stat_activity WHERE backend_type = 'checkpointer'")
crash_at=$(date -u +%T)
echo "  kill checkpointer at $(date -u +%T)"; kill -9 "$pid"; sleep 3; alive || { echo "FINDING: server not back after final crash"; touch $D/finding; }
after=$(psql -qXAtc "SELECT entries FROM pg_stat_index_queries_info")
echo "entries before crash=$before after=$after"
if [ "${after:-0}" -eq 0 ]; then
  echo "FINDING: no counters after crash with save_interval = 1"; touch $D/finding
  echo "  snapshot now: $(ls -l --time-style=+%T.%N $PGDATA/pg_stat_tmp/ 2>&1 | grep snap)"
  echo "  crash at: $crash_at"
  echo "  log after the crash:"; awk -v t="$crash_at" '$2 >= t' $D/log | grep -vE 'checkpoint|redo |connection authorized|connection received' | head -40
fi
pg_ctl -D $PGDATA -m fast -w stop >/dev/null

echo "--- results"
for f in $D/pgbench_*.out; do
  echo "$(basename $f): $(grep -h 'actually processed' $f | awk -F': ' '{s+=$2} END {print s}') transactions, $(grep -c 'aborted' $f) client aborts"
done
F=0
if grep -hE "TRAP:|PANIC|stuck spinlock|AddressSanitizer|runtime error|was terminated by signal (6|11|7|4)" $D/log; then F=1; fi
crashes=$(grep -c "terminated by signal 9" $D/log)
echo "intended SIGKILL crash restarts: $crashes"
ls /tmp/asan* /tmp/ubsan* 2>/dev/null && { cat /tmp/asan* /tmp/ubsan* | head -60; F=1; }
grep -hiE "pg_stat_index_queries" $D/log | sort | uniq -c | sort -rn | head -15
echo "--- processes that died by a signal:"
grep -hE "terminated by signal|was terminated|exited with exit code [^01]" $D/log | sed -E 's/^([0-9-]+ [0-9:.]+) UTC \[[0-9]+\] [a-z ]*LOG: +/\1 /' | head -40
echo "--- statements behind errors other than the induced ones:"
awk '/ERROR: +(cache lookup failed|could not open relation|unexpected|tuple concurrently|deadlock detected)/ {n=6} n > 0 {print; n--}' $D/log | sed -E 's/^[0-9-]+ [0-9:.]+ UTC \[[0-9]+\] //' | cut -c1-300 | head -30
echo "--- distinct ERROR/FATAL messages:"
grep -hE "(ERROR|FATAL):" $D/log | sed -E 's/.*(ERROR|FATAL): +//; s/[0-9]+/N/g' | sort | uniq -c | sort -rn | head -25
grep -q FINDING $D/summary 2>/dev/null && F=1
[ -e $D/finding ] && F=1
[ $F = 0 ] && echo "NO FINDINGS" || echo "FINDINGS ABOVE"
exit $F
