EXTENSION = pg_index_deps
DATA = pg_index_deps--0.1.sql pg_index_deps--0.2.sql pg_index_deps--0.3.sql pg_index_deps--0.4.sql \
       pg_index_deps--0.1--0.2.sql pg_index_deps--0.2--0.3.sql pg_index_deps--0.3--0.4.sql
PGFILEDESC = "pg_index_deps - SQL edition of pg_stat_index_queries"

REGRESS = parse dependents query_stats drop_impact usage upgrade
REGRESS_OPTS = --temp-instance=./tmp_check --temp-config=./test/pg.conf
# C collation so ORDER BY on names is the same on every machine.
NO_LOCALE = 1

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# Plain-SQL install for managed Postgres (RDS / Aurora): no control file needed.
install.sql: pg_index_deps--0.4.sql
	{ echo '-- pg_index_deps 0.4, plain install (generated, do not edit)'; \
	  echo 'CREATE SCHEMA IF NOT EXISTS index_deps;'; \
	  echo 'SET search_path = index_deps, public;'; \
	  grep -v '^\\echo' pg_index_deps--0.4.sql | grep -v 'pg_extension_config_dump'; } > $@

# pg_tle install for RDS / Aurora (needs the pg_tle extension). Also upgrades
# an older pg_tle registration: see gen_pg_tle.sh.
install_pg_tle.sql: pg_index_deps--0.4.sql $(wildcard pg_index_deps--*--*.sql) gen_pg_tle.sh
	./gen_pg_tle.sh 0.4 > $@

managed: install.sql install_pg_tle.sql
