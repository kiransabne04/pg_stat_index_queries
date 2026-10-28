# Periodic saves (0.10): the saver worker writes the counters every
# save_interval to pg_stat_tmp, so a crash keeps the last snapshot. A clean
# restart followed by a crash keeps the counters too. A reset before a
# crash doesn't bring old counters back; save = off and save_interval = 0
# remove the snapshot. A replica made with pg_basebackup doesn't start with
# the primary's counters. save_interval raised by a reload takes effect.
use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

my $node = PostgreSQL::Test::Cluster->new('periodic');
$node->init(allows_streaming => 1);
$node->append_conf('postgresql.conf',
	"shared_preload_libraries = 'pg_stat_index_queries'\ncompute_query_id = on\n"
	  . "restart_after_crash = on\npg_stat_index_queries.save_interval = 1\n");
$node->start;

my $file = $node->data_dir . '/pg_stat_tmp/pg_stat_index_queries.snap';

$node->safe_psql('postgres', q{
	CREATE EXTENSION pg_stat_index_queries;
	CREATE TABLE t (id int PRIMARY KEY);
	INSERT INTO t SELECT generate_series(1, 1000);
	ANALYZE t;
});

my $query = q{SET enable_seqscan = off; SELECT id FROM t WHERE id = 5;};
my $count_sql = q{SELECT coalesce(sum(calls_executed), 0)
	FROM pg_stat_index_queries WHERE indexrelid = 't_pkey'::regclass};

# Wait (up to 30 s) until $cond returns true.
sub wait_for
{
	my ($cond) = @_;
	for (1 .. 300)
	{
		return 1 if $cond->();
		usleep(100_000);
	}
	return 0;
}

sub crash
{
	my $bgwriter = $node->safe_psql('postgres',
		q{SELECT pid FROM pg_stat_activity WHERE backend_type = 'background writer'});
	my $logstart = -s $node->logfile;
	kill 'KILL', $bgwriter;
	sleep 3;
	{
		local $SIG{PIPE} = 'IGNORE';
		$node->poll_query_until('postgres', q{SELECT true})
		  or die "server did not come back after crash";
	}
	ok($node->log_contains('terminated by signal 9', $logstart),
		'crash restart happened');
}

# File modification time with sub-second precision where available.
sub mtime { return (Time::HiRes::stat($file))[9]; }

# Counts reach the snapshot without a shutdown, and survive a crash.
$node->safe_psql('postgres', $query) for 1 .. 3;
is($node->safe_psql('postgres', $count_sql), '3', 'three calls recorded');
my $before = -e $file ? mtime() : 0;
ok(wait_for(sub { -e $file && mtime() > $before }), 'saver wrote the file');
crash();
is($node->safe_psql('postgres', $count_sql), '3', 'counters survive a crash');
ok(-e $file, 'snapshot kept after loading');

$node->safe_psql('postgres', $query);
is($node->safe_psql('postgres', $count_sql), '4', 'counting continues after crash');

# Clean restart, then a crash before anything changes: the loaded counters
# were saved again as a snapshot.
$node->restart;
ok(wait_for(sub { -e $file }), 'snapshot written after loading the shutdown file');
crash();
is($node->safe_psql('postgres', $count_sql), '4', 'counters survive restart + crash');

# A replica from pg_basebackup starts without the primary's counters.
$node->safe_psql('postgres', 'SELECT pg_create_physical_replication_slot(\'rep\')');
$node->backup('bk');
my $standby = PostgreSQL::Test::Cluster->new('standby');
$standby->init_from_backup($node, 'bk', has_streaming => 1);
$standby->append_conf('postgresql.conf', "primary_slot_name = 'rep'\n");
$standby->start;
ok(!-e $standby->data_dir . '/pg_stat_tmp/pg_stat_index_queries.snap',
	'base backup has no snapshot');
is($standby->safe_psql('postgres', $count_sql), '0', 'replica starts with no counters');
$standby->stop;
$node->safe_psql('postgres', 'SELECT pg_drop_replication_slot(\'rep\')');

# Nothing changed: the saver doesn't rewrite the file.
sleep 2;
my $idle = mtime();
sleep 3;
is(mtime(), $idle, 'no rewrite while nothing changes');

# Reset, then crash: the old counters don't come back.
$node->safe_psql('postgres', 'SELECT pg_stat_index_queries_reset()');
crash();
is($node->safe_psql('postgres', $count_sql), '0', 'no pre-reset counters after a crash');

# save_interval = 0 (reload): the snapshot is removed, a crash loses the counters.
$node->safe_psql('postgres', $query);
ok(wait_for(sub { -e $file }), 'snapshot written');
$node->append_conf('postgresql.conf', "pg_stat_index_queries.save_interval = 0\n");
$node->reload;
ok(wait_for(sub { !-e $file }), 'save_interval = 0 removes the snapshot');
crash();
is($node->safe_psql('postgres', $count_sql), '0', 'save_interval = 0: no counters after a crash');

# save = off (reload) with periodic saves on: the snapshot is removed.
$node->append_conf('postgresql.conf', "pg_stat_index_queries.save_interval = 1\n");
$node->reload;
$node->safe_psql('postgres', $query);
ok(wait_for(sub { -e $file }), 'snapshot written again');
$node->append_conf('postgresql.conf', "pg_stat_index_queries.save = off\n");
$node->reload;
ok(wait_for(sub { !-e $file }), 'save = off removes the snapshot');

# save_interval = 0 at server start, raised later by a reload: the worker
# is always there, so saving starts without a restart.
$node->append_conf('postgresql.conf',
	"pg_stat_index_queries.save = on\npg_stat_index_queries.save_interval = 0\n");
$node->restart;
$node->safe_psql('postgres', $query);
sleep 2;
ok(!-e $file, 'save_interval = 0 at start: no snapshot');
$node->append_conf('postgresql.conf', "pg_stat_index_queries.save_interval = 1\n");
$node->reload;
ok(wait_for(sub { -e $file }), 'raising save_interval by reload starts saving');
crash();
is($node->safe_psql('postgres', $count_sql), '1', 'counters survive a crash after the reload');

$node->stop;
done_testing();
