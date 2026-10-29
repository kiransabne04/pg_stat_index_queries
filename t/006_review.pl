# Correctness review (native 0.10.1), multi-session and file cases:
# - an (index, query) pair a session records is visible to others at once,
#   even if the session then stays idle (counts of known pairs stay batched);
# - first_seen is the earliest time any session saw the pair;
# - a reset discards counts other sessions had not flushed yet;
# - a stats file with impossible counters or trailing bytes is rejected;
# - counters saturate instead of overflowing;
# - only ALTER TABLE subcommands that rebuild indexes look at tracked
#   indexes, and an index busy in another session is skipped without
#   making the ALTER wait or fail.
use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

my $node = PostgreSQL::Test::Cluster->new('review');
$node->init;
$node->append_conf('postgresql.conf',
	"shared_preload_libraries = 'pg_stat_index_queries'\ncompute_query_id = on\n"
	  . "pg_stat_index_queries.save_interval = 0\n");
$node->start;
$node->safe_psql('postgres', q{
	CREATE EXTENSION pg_stat_index_queries;
	CREATE TABLE f (id int PRIMARY KEY, a int);
	CREATE INDEX f_a_idx ON f (a);
	INSERT INTO f SELECT g, g FROM generate_series(1, 1000) g;
	ANALYZE f;
});

sub calls
{
	my ($index) = @_;
	return $node->safe_psql('postgres',
		"SELECT coalesce(sum(calls_executed), 0) FROM pg_stat_index_queries WHERE indexrelid = '$index'::regclass");
}

SKIP:
{
	skip 'background_psql API needs PostgreSQL 16+', 4 if $node->pg_version < 16;

	# 1. A new pair is published at once, though the session stays idle.
	my $bg = $node->background_psql('postgres');
	$bg->query_safe(q{SET pg_stat_index_queries.flush_interval = '60s'});
	$bg->query_safe(q{SET enable_seqscan = off});
	my $t_bg = $bg->query_safe(q{SELECT statement_timestamp()});
	$bg->query_safe(q{SELECT a FROM f WHERE id = 1});
	is(calls('f_pkey'), '1', 'new (index, query) pair visible while its session idles');

	# 2. first_seen is the earliest sighting, whichever session flushes first.
	sleep 2;
	$node->safe_psql('postgres', q{
		SET pg_stat_index_queries.flush_interval = 0; SET enable_seqscan = off;
		SELECT a FROM f WHERE id = 2;});
	$bg->quit;
	$node->poll_query_until('postgres', "SELECT (" . "SELECT coalesce(sum(calls_executed), 0) FROM pg_stat_index_queries WHERE indexrelid = 'f_pkey'::regclass) = 2")
	  or die 'counts never arrived';
	is($node->safe_psql('postgres',
			"SELECT min(first_seen) <= '$t_bg'::timestamptz + interval '0.5 second' FROM pg_stat_index_queries WHERE indexrelid = 'f_pkey'::regclass"),
		't', 'first_seen is the earliest sighting');

	# 3. Counts of a known pair stay batched (no shared write per statement)...
	my $bg2 = $node->background_psql('postgres');
	$bg2->query_safe(q{SET pg_stat_index_queries.flush_interval = '60s'});
	$bg2->query_safe(q{SET enable_seqscan = off});
	$bg2->query_safe(q{SELECT a FROM f WHERE id = 3});
	$bg2->query_safe(q{SELECT a FROM f WHERE id = 4});
	is(calls('f_pkey'), '2', 'counts of a known pair stay batched while the session idles');

	# ...and a reset discards them: they belong to the epoch before it.
	$node->safe_psql('postgres', 'SELECT pg_stat_index_queries_reset()');
	$bg2->quit;
	usleep(500_000);
	$node->poll_query_until('postgres', q{SELECT count(*) = 0 FROM pg_stat_activity WHERE backend_type = 'client backend' AND pid <> pg_backend_pid()});
	is(calls('f_pkey'), '0', 'counts from before a reset do not arrive after it');
}

# 6. ALTER TABLE subcommands that keep index OIDs skip the capture; ALTER
#    COLUMN TYPE does it (logged at DEBUG1).
$node->safe_psql('postgres', q{
	CREATE TABLE g (id int PRIMARY KEY, b int);
	CREATE INDEX g_b_idx ON g (b);
	INSERT INTO g SELECT x, x FROM generate_series(1, 100) x;
	SET enable_seqscan = off; SELECT b FROM g WHERE id = 1; SELECT id FROM g WHERE b = 1;});
my $alterlog = -s $node->logfile;
$node->safe_psql('postgres', q{
	SET log_min_messages = debug1;
	ALTER TABLE g SET (fillfactor = 90);
	ALTER TABLE g ADD COLUMN z int;
	ALTER TABLE g ALTER COLUMN b SET STATISTICS 200;
	ALTER TABLE g ALTER COLUMN z TYPE bigint, ALTER COLUMN b TYPE bigint;});
my @captures = (slurp_file($node->logfile, $alterlog) =~ /ALTER TABLE may rebuild (\d+) tracked indexes/g);
is(scalar(@captures), 1, 'only ALTER COLUMN TYPE looks at tracked indexes');
is($captures[0], '2', 'it looks at the indexes of that table');
is(calls('g_b_idx'), '1', 'history kept through ALTER COLUMN TYPE');

SKIP:
{
	skip 'background_psql API needs PostgreSQL 16+', 4 if $node->pg_version < 16;

	# 7. A table locked by another session (DROP INDEX in an open
	#    transaction): the capture doesn't wait for it, which could deadlock
	#    with that session; the ALTER then waits for its own lock as usual
	#    and succeeds. The rebuilt index starts from zero; an index the ALTER
	#    doesn't rebuild is untouched.
	my $holder = $node->background_psql('postgres');
	$holder->query_safe(q{BEGIN});
	$holder->query_safe(q{DROP INDEX g_b_idx});
	my $alter = $node->background_psql('postgres');
	$alter->query_until(qr/started/, "\\echo started\nALTER TABLE g ALTER COLUMN b TYPE int;\n");
	$node->poll_query_until('postgres',
		q{SELECT count(*) = 1 FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND query LIKE 'ALTER TABLE g %'})
	  or die 'ALTER never waited for the table lock';
	$holder->query_safe(q{ROLLBACK});
	$alter->query_until(qr/finished/, "\\echo finished\n");
	unlike($alter->{stderr}, qr/ERROR/, 'ALTER succeeded while an index was busy');
	is($node->safe_psql('postgres',
			q{SELECT atttypid::regtype FROM pg_attribute WHERE attrelid = 'g'::regclass AND attname = 'b'}),
		'integer', 'column type changed');
	is(calls('g_b_idx'), '0', 'busy table skipped: no history carried');
	is(calls('g_pkey'), '1', 'index not rebuilt is untouched');
	$alter->quit;
	$holder->quit;
}

# 4. Files with impossible content are rejected as a whole.
$node->safe_psql('postgres', q{SET enable_seqscan = off; SELECT count(*) FROM f WHERE a = 5;});
my ($dbid, $relid, $queryid) = split /\|/, $node->safe_psql('postgres', q{
	SELECT dbid, indexrelid, queryid FROM pg_stat_index_queries
	 WHERE indexrelid = 'f_a_idx'::regclass LIMIT 1});
my ($major) = $node->safe_psql('postgres', q{SELECT current_setting('server_version_num')::int / 100});
my $file = $node->data_dir . '/pg_stat/pg_stat_index_queries.stat';

sub write_file
{
	my ($executed, $planned, $first, $last, $extra) = @_;
	$node->stop;
	open(my $fh, '>:raw', $file) or die "cannot write $file";
	print $fh pack('V l< q< q< q< C', 0x51495303, $major, 1, 0, 0, 0);
	print $fh pack('V V q< C x7 q< q< q< q< V V',
		$dbid, $relid, $queryid, 1, $executed, $planned, $first, $last, 1, 0);
	print $fh $extra if defined $extra;
	close($fh);
	my $logstart = -s $node->logfile;
	$node->start;
	return $logstart;
}

my $now = 846000000000000;    # 2026-10-23 in PostgreSQL microseconds
my $max = '9223372036854775807';
my $logstart = write_file(-5, 3, $now, $now);
is(calls('f_a_idx'), '0', 'negative counter: file rejected');
ok($node->log_contains('ignoring invalid pg_stat_index_queries file', $logstart), 'rejection logged');
write_file(5, 3, $now, $now);
is(calls('f_a_idx'), '0', 'executed > planned: file rejected');
write_file(1, 1, $now + 10, $now);
is(calls('f_a_idx'), '0', 'first_seen after last_seen: file rejected');
write_file(1, 1, $now, $now, "garbage");
is(calls('f_a_idx'), '0', 'trailing bytes: file rejected');

# 5. A valid file loads; counters saturate instead of overflowing.
write_file('9223372036854775806', '9223372036854775806', $now, $now);
is(calls('f_a_idx'), '9223372036854775806', 'valid file loads');
$node->safe_psql('postgres', q{SET enable_seqscan = off;
	SELECT count(*) FROM f WHERE a = 6; SELECT count(*) FROM f WHERE a = 7; SELECT count(*) FROM f WHERE a = 8;});
is(calls('f_a_idx'), $max, 'counter saturates at the int64 maximum');

$node->stop;
done_testing();
