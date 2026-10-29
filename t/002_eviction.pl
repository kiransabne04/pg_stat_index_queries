# With a small max, least recently seen entries are evicted, dealloc is
# counted, and the server keeps working.
use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('evict');
$node->init;
$node->append_conf('postgresql.conf',
	"shared_preload_libraries = 'pg_stat_index_queries'\n"
	  . "compute_query_id = on\n"
	  . "pg_stat_index_queries.max = 100\n");
$node->start;

$node->safe_psql('postgres', 'CREATE EXTENSION pg_stat_index_queries');

# 150 tables, each with its own primary key index -> 150 distinct entries
my $setup = '';
$setup .= "CREATE TABLE e$_ (id int PRIMARY KEY); INSERT INTO e$_ VALUES (1);\n" for 1 .. 150;
$node->safe_psql('postgres', $setup);

my $queries = "SET enable_seqscan = off;\n";
$queries .= "SELECT id FROM e$_ WHERE id = 1;\n" for 1 .. 150;
$node->safe_psql('postgres', $queries);

my ($entries, $dealloc) = split(/\|/,
	$node->safe_psql('postgres', 'SELECT entries, dealloc FROM pg_stat_index_queries_info'));

cmp_ok($entries, '<=', 100, 'entries never exceed max');
cmp_ok($dealloc, '>', 0, 'evictions are counted');

# Most recent entries survive eviction
is($node->safe_psql('postgres',
	q{SELECT count(*) FROM pg_stat_index_queries WHERE indexrelid = 'e150_pkey'::regclass}),
	'1', 'most recently used entry kept');

is($node->safe_psql('postgres', 'SELECT 1'), '1', 'server still healthy');

SKIP:
{
	skip 'background_psql API needs PostgreSQL 16+', 3 if $node->pg_version < 16;

	# A session's known pair evicted by other sessions is published again
	# at once when that session records it next, not batched as known.
	my $bg = $node->background_psql('postgres');
	$bg->query_safe(q{SET pg_stat_index_queries.flush_interval = '60s'});
	$bg->query_safe(q{SET enable_seqscan = off});
	$bg->query_safe(q{SELECT id FROM e1 WHERE id = 1});
	is($node->safe_psql('postgres',
		q{SELECT count(*) FROM pg_stat_index_queries WHERE indexrelid = 'e1_pkey'::regclass}),
		'1', 'pair published');
	my $evict = "SET enable_seqscan = off;\n";
	$evict .= "SELECT id FROM e$_ WHERE id = 1;\n" for 2 .. 150;
	$node->safe_psql('postgres', $evict);
	is($node->safe_psql('postgres',
		q{SELECT count(*) FROM pg_stat_index_queries WHERE indexrelid = 'e1_pkey'::regclass}),
		'0', 'pair evicted by other sessions');
	$bg->query_safe(q{SELECT id FROM e1 WHERE id = 1});
	is($node->safe_psql('postgres',
		q{SELECT count(*) FROM pg_stat_index_queries WHERE indexrelid = 'e1_pkey'::regclass}),
		'1', 'evicted pair published again at once');
	$bg->quit;
}

$node->stop;
done_testing();
