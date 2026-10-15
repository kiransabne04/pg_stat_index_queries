MODULE_big = pg_stat_index_queries
OBJS = pg_stat_index_queries.o

EXTENSION = pg_stat_index_queries
DATA = pg_stat_index_queries--0.1.sql
PGFILEDESC = "pg_stat_index_queries - track which queries use each index"

REGRESS = basic
# Self-contained test instance with the library preloaded.
REGRESS_OPTS = --temp-instance=./tmp_check --temp-config=./test/pg.conf

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
