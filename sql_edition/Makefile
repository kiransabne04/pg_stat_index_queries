EXTENSION = pg_index_deps
DATA = pg_index_deps--0.1.sql
PGFILEDESC = "pg_index_deps - SQL edition of pg_stat_index_queries"

REGRESS = parse dependents drop_impact
REGRESS_OPTS = --temp-instance=./tmp_check --temp-config=./test/pg.conf
# C collation so ORDER BY on names is the same on every machine.
NO_LOCALE = 1

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# Plain-SQL install for managed Postgres (RDS / Aurora): no control file needed.
install.sql: pg_index_deps--0.1.sql
	{ echo '-- pg_index_deps 0.1, plain install (generated, do not edit)'; \
	  echo 'CREATE SCHEMA IF NOT EXISTS index_deps;'; \
	  echo 'SET search_path = index_deps, public;'; \
	  grep -v '^\\echo' pg_index_deps--0.1.sql | grep -v 'pg_extension_config_dump'; } > $@

# pg_tle install for RDS / Aurora (needs the pg_tle extension).
install_pg_tle.sql: pg_index_deps--0.1.sql
	{ echo '-- pg_index_deps 0.1 via pg_tle (generated, do not edit)'; \
	  echo "SELECT pgtle.install_extension('pg_index_deps', '0.1',"; \
	  echo "  'which queries depend on each index; drop-impact check',"; \
	  echo '$$_pgtle_$$'; \
	  echo 'CREATE SCHEMA IF NOT EXISTS index_deps;'; \
	  grep -v '^\\echo' pg_index_deps--0.1.sql; \
	  echo '$$_pgtle_$$);'; } > $@

managed: install.sql install_pg_tle.sql
