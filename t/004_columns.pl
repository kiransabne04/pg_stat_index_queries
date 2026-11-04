# Column sets (0.8) survive a clean restart, and a stats file written by
# 0.6/0.7 (format 2, no column masks) is still read: its counts are kept and
# its entries are marked columns_complete = false.
use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

my $node = PostgreSQL::Test::Cluster->new('columns');
$node->init;
$node->append_conf('postgresql.conf',
	"shared_preload_libraries = 'pg_stat_index_queries'\ncompute_query_id = on\n"
	  . "restart_after_crash = on\n");
$node->start;

$node->safe_psql('postgres', q{
	CREATE EXTENSION pg_stat_index_queries;
	CREATE TABLE t (id int PRIMARY KEY, a int, b int);
	CREATE INDEX t_ab_idx ON t (a, b);
	INSERT INTO t SELECT g, g % 10, g % 7 FROM generate_series(1, 1000) g;
	ANALYZE t;
});
$node->safe_psql('postgres',
	q{SET enable_seqscan = off; SELECT count(*) FROM t WHERE a = 1 AND b = 2;});

my $cols_sql = q{SELECT string_agg(format('%s %s %s', calls_executed, cond_columns, columns_complete), ', ')
	FROM pg_stat_index_queries WHERE indexrelid = 't_ab_idx'::regclass};

is($node->safe_psql('postgres', $cols_sql), '1 {1,2} t', 'columns recorded');
$node->restart;
is($node->safe_psql('postgres', $cols_sql), '1 {1,2} t', 'columns survive a clean restart');

# Write a format 2 file (0.6/0.7) with one entry for t_ab_idx.
my $dbid = $node->safe_psql('postgres', q{SELECT oid FROM pg_database WHERE datname = 'postgres'});
my $indexrelid = $node->safe_psql('postgres', q{SELECT 't_ab_idx'::regclass::oid});
my $pgmajor = $node->safe_psql('postgres', q{SELECT current_setting('server_version_num')::int / 100});
$node->stop;
my $file = $node->data_dir . '/pg_stat/pg_stat_index_queries.stat';
open(my $fh, '>:raw', $file) or die "cannot write $file";
# header, PG major, entry count, dealloc, stats_reset, sampled
print $fh pack('LlqqqC', 0x51495302, $pgmajor, 1, 0, 0, 0);
# key (dbid, indexrelid, queryid, toplevel, padding), calls_executed,
# calls_planned, first_seen, last_seen
print $fh pack('LLQCx7qqqq', $dbid, $indexrelid, 12345, 1, 7, 7, 0, 0);
close($fh);
my $logstart = -s $node->logfile;
$node->start;
ok(!$node->log_contains('ignoring invalid pg_stat_index_queries file', $logstart),
	'format 2 file accepted');
is($node->safe_psql('postgres', $cols_sql), '7 {} f',
	'format 2 entry kept, columns marked incomplete');
is($node->safe_psql('postgres',
		q{SELECT format('%s %s %s', queries, queries_columns_unknown, note LIKE 'unknown: 1 of 1 queries%')
		  FROM pg_index_column_usage WHERE indexname = 't_ab_idx' AND key_position = 2}),
	'1 1 t', 'pg_index_column_usage reports the column as unknown, not unused');

# The flag must survive being saved again: before format 4 the next save
# dropped it and the following load marked the entry complete.
$node->restart;
is($node->safe_psql('postgres', $cols_sql), '7 {} f',
	'format 2 entry still incomplete after one restart');
$node->restart;
is($node->safe_psql('postgres', $cols_sql), '7 {} f',
	'format 2 entry still incomplete after two restarts');

# A crash snapshot keeps the flag as well (a real crash: the postmaster's
# shutdown save doesn't run).
$node->safe_psql('postgres', q{ALTER SYSTEM SET pg_stat_index_queries.save_interval = 1});
$node->safe_psql('postgres', q{SELECT pg_reload_conf()});
my $snap = $node->data_dir . '/pg_stat_tmp/pg_stat_index_queries.snap';
my $before = -e $snap ? (Time::HiRes::stat($snap))[9] : 0;
$node->safe_psql('postgres',
	q{SET enable_seqscan = off; SELECT count(*) FROM t WHERE a = 1 AND b = 2;});
my $saved = 0;
for (1 .. 300)
{
	if (-e $snap && (Time::HiRes::stat($snap))[9] > $before)
	{
		$saved = 1;
		last;
	}
	usleep(100_000);
}
ok($saved, 'saver wrote the snapshot');
my $bgwriter = $node->safe_psql('postgres',
	q{SELECT pid FROM pg_stat_activity WHERE backend_type = 'background writer'});
$logstart = -s $node->logfile;
kill 'KILL', $bgwriter;
sleep 3;
{
	local $SIG{PIPE} = 'IGNORE';
	$node->poll_query_until('postgres', q{SELECT true})
	  or die "server did not come back after crash";
}
ok($node->log_contains('terminated by signal 9', $logstart), 'crash restart happened');
is($node->safe_psql('postgres',
		q{SELECT format('%s %s %s', calls_executed, cond_columns, columns_complete)
		  FROM pg_stat_index_queries
		  WHERE indexrelid = 't_ab_idx'::regclass AND queryid = 12345}),
	'7 {} f', 'format 2 entry still incomplete after a crash');

# A format 3 file (0.8-0.10.1) has masks but no flag: its entries may have
# come from a format 1/2 file, so they load as incomplete, masks kept.
$node->stop;
open($fh, '>:raw', $file) or die "cannot write $file";
print $fh pack('LlqqqC', 0x51495303, $pgmajor, 1, 0, 0, 0);
# key, calls_executed, calls_planned, first_seen, last_seen, cond_cols, order_cols
print $fh pack('LLQCx7qqqqLL', $dbid, $indexrelid, 12345, 1, 4, 4, 0, 0, 3, 0);
close($fh);
$logstart = -s $node->logfile;
$node->start;
ok(!$node->log_contains('ignoring invalid pg_stat_index_queries file', $logstart),
	'format 3 file accepted');
is($node->safe_psql('postgres', $cols_sql), '4 {1,2} f',
	'format 3 entry keeps its columns, marked incomplete');

# A reset starts a complete record, and that survives restarts.
$node->safe_psql('postgres', q{SELECT pg_stat_index_queries_reset()});
$node->safe_psql('postgres',
	q{SET enable_seqscan = off; SELECT count(*) FROM t WHERE a = 1 AND b = 2;});
$node->restart;
$node->restart;
is($node->safe_psql('postgres', $cols_sql), '1 {1,2} t',
	'complete entry stays complete across two restarts');

$node->stop;
done_testing();
