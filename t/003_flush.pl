# Backend-local batching (0.6): other sessions see a backend's counts only
# after it flushes (flush_interval, or when it disconnects), and nothing is
# lost when a session ends.
use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('flush');
$node->init;
$node->append_conf('postgresql.conf',
	"shared_preload_libraries = 'pg_stat_index_queries'\n"
	  . "compute_query_id = on\n");
$node->start;

$node->safe_psql('postgres', q{
	CREATE EXTENSION pg_stat_index_queries;
	CREATE TABLE f (id int PRIMARY KEY, a int);
	INSERT INTO f SELECT g, g FROM generate_series(1, 1000) g;
	ANALYZE f;
});

my $count = q{SELECT coalesce(sum(calls_executed), 0) FROM pg_stat_index_queries
              WHERE indexrelid = 'f_pkey'::regclass};

# A session that ends flushes on the way out, even with a long interval.
$node->safe_psql('postgres', q{
	SET pg_stat_index_queries.flush_interval = '60s';
	SET enable_seqscan = off;
	SELECT a FROM f WHERE id = 1;
	SELECT a FROM f WHERE id = 2;
	SELECT a FROM f WHERE id = 3;
});
is($node->safe_psql('postgres', $count), '3', 'counts flushed when the session ends');

# While a session is open with a long interval, others don't see its counts
# yet; after it disconnects they do. (BackgroundPsql is PG 16+.)
SKIP:
{
	skip 'background_psql API needs PostgreSQL 16+', 2 if $node->pg_version < 16;

	my $bg = $node->background_psql('postgres');
	$bg->query_safe(q{SET pg_stat_index_queries.flush_interval = '60s'});
	$bg->query_safe(q{SET enable_seqscan = off});
	$bg->query_safe(q{SELECT a FROM f WHERE id = 4});
	$bg->query_safe(q{SELECT a FROM f WHERE id = 5});
	is($node->safe_psql('postgres', $count), '3',
		'pending counts of an open session are not visible to others yet');
	$bg->quit;
	# The exit hook runs as the backend shuts down; wait for it.
	$node->poll_query_until('postgres', "SELECT ($count) = 5")
	  or die 'counts of the closed session never arrived';
	is($node->safe_psql('postgres', $count), '5', 'visible after the session disconnects');
}

# flush_interval = 0: visible to other sessions right away.
SKIP:
{
	skip 'background_psql API needs PostgreSQL 16+', 1 if $node->pg_version < 16;

	my $bg = $node->background_psql('postgres');
	$bg->query_safe(q{SET pg_stat_index_queries.flush_interval = 0});
	$bg->query_safe(q{SET enable_seqscan = off});
	$bg->query_safe(q{SELECT a FROM f WHERE id = 6});
	is($node->safe_psql('postgres', $count), '6', 'flush_interval = 0 updates shared memory at once');
	$bg->quit;
}

done_testing();
