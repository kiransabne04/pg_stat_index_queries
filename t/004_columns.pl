# Column sets (0.8) survive a clean restart, and a stats file written by
# 0.6/0.7 (format 2, no column masks) is still read: its counts are kept and
# its entries are marked columns_complete = false.
use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('columns');
$node->init;
$node->append_conf('postgresql.conf',
	"shared_preload_libraries = 'pg_stat_index_queries'\ncompute_query_id = on\n");
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

$node->stop;
done_testing();
