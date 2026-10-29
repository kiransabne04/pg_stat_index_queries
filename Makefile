MODULE_big = pg_stat_index_queries
OBJS = pg_stat_index_queries.o

EXTENSION = pg_stat_index_queries
DATA = pg_stat_index_queries--0.1.sql pg_stat_index_queries--0.2.sql pg_stat_index_queries--0.3.sql pg_stat_index_queries--0.4.sql pg_stat_index_queries--0.5.sql pg_stat_index_queries--0.6.sql pg_stat_index_queries--0.7.sql pg_stat_index_queries--0.8.sql pg_stat_index_queries--0.9.sql pg_stat_index_queries--0.10.sql \
       pg_stat_index_queries--0.1--0.2.sql pg_stat_index_queries--0.2--0.3.sql pg_stat_index_queries--0.3--0.4.sql pg_stat_index_queries--0.4--0.5.sql pg_stat_index_queries--0.5--0.6.sql pg_stat_index_queries--0.6--0.7.sql pg_stat_index_queries--0.7--0.8.sql pg_stat_index_queries--0.8--0.9.sql pg_stat_index_queries--0.9--0.10.sql
PGFILEDESC = "pg_stat_index_queries - track which queries use each index"

REGRESS = basic partitions query_stats usage sampling stats columns sole_path reindex cursors fk_support review upgrade
# Self-contained test instance with the library preloaded.
REGRESS_OPTS = --temp-instance=./tmp_check --temp-config=./test/pg.conf
# C collation so ORDER BY on names is the same on every machine.
NO_LOCALE = 1
TAP_TESTS = 1

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# ---------------------------------------------------------------------------
# Convenience targets
# ---------------------------------------------------------------------------
.PHONY: test-all sql-edition sql-edition-check bench docker-test

test-all: installcheck sql-edition-check

sql-edition:
	$(MAKE) -C sql_edition install managed

sql-edition-check:
	$(MAKE) -C sql_edition installcheck

bench:
	./bench/run.sh

docker-test:
	docker compose -f docker/docker-compose.yml run --rm test
