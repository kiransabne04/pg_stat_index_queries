# Counters survive a clean restart, are not saved when save = off,
# and a corrupt file is ignored without breaking startup.
use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('persist');
$node->init;
$node->append_conf('postgresql.conf',
	"shared_preload_libraries = 'pg_stat_index_queries'\ncompute_query_id = on\nrestart_after_crash = on\n");
$node->start;

$node->safe_psql('postgres', q{
	CREATE EXTENSION pg_stat_index_queries;
	CREATE TABLE t (id int PRIMARY KEY);
	INSERT INTO t SELECT generate_series(1, 1000);
	ANALYZE t;
});

my $query = q{SET enable_seqscan = off; SELECT id FROM t WHERE id = 5;};
$node->safe_psql('postgres', $query) for 1 .. 3;

my $count_sql = q{SELECT coalesce(sum(calls_executed), 0)
	FROM pg_stat_index_queries WHERE indexrelid = 't_pkey'::regclass};

is($node->safe_psql('postgres', $count_sql), '3', 'three calls recorded');

$node->restart;
is($node->safe_psql('postgres', $count_sql), '3', 'counters survive a clean restart');

$node->safe_psql('postgres', $query);
is($node->safe_psql('postgres', $count_sql), '4', 'counting continues after restart');

# save = off: nothing is written at shutdown
$node->append_conf('postgresql.conf', "pg_stat_index_queries.save = off\n");
$node->restart;
is($node->safe_psql('postgres', $count_sql), '4', 'loaded file from previous clean shutdown');
$node->restart;
is($node->safe_psql('postgres', $count_sql), '0', 'save = off discards counters at restart');

# Corrupt file: ignored with a LOG message, server starts normally
$node->stop;
my $file = $node->data_dir . '/pg_stat/pg_stat_index_queries.stat';
open(my $fh, '>', $file) or die "cannot write $file";
print $fh "not a valid stats file";
close($fh);
$node->append_conf('postgresql.conf', "pg_stat_index_queries.save = on\n");
my $logstart = -s $node->logfile;
$node->start;
is($node->safe_psql('postgres', $count_sql), '0', 'corrupt file ignored');
ok($node->log_contains('ignoring invalid pg_stat_index_queries file', $logstart),
	'corrupt file reported in log');
ok(!-e $file, 'corrupt file removed');

# Real crash (a server process killed): shared memory is re-created, nothing
# is saved, and no stale file from an earlier shutdown is reloaded.
$node->safe_psql('postgres', $query);
is($node->safe_psql('postgres', $count_sql), '1', 'one call before the crash');
my $bgwriter = $node->safe_psql('postgres',
	q{SELECT pid FROM pg_stat_activity WHERE backend_type = 'background writer'});
kill 'KILL', $bgwriter;
# Give the postmaster time to notice, reset shared memory and recover.
sleep 3;
{
	local $SIG{PIPE} = 'IGNORE';
	$node->poll_query_until('postgres', q{SELECT true})
	  or die "server did not come back after crash";
}
ok($node->log_contains('terminated by signal 9'), 'crash restart happened');
is($node->safe_psql('postgres', $count_sql), '0', 'no stale counters after a crash');

$node->stop;
done_testing();
