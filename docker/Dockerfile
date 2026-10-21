# Build and test image for pg_stat_index_queries (native + SQL edition).
#   docker build -f docker/Dockerfile --build-arg PG_MAJOR=17 -t siq:17 .
ARG PG_MAJOR=17
FROM postgres:${PG_MAJOR}
ARG PG_MAJOR

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential git ca-certificates libipc-run-perl libkrb5-dev libzstd-dev \
      postgresql-server-dev-${PG_MAJOR} postgresql-${PG_MAJOR}-hypopg \
    && rm -rf /var/lib/apt/lists/*

# pg_stat_plans (PG 16+) for the SQL edition's live source and tests.
RUN if [ "${PG_MAJOR}" -ge 16 ]; then \
      git clone --depth 1 https://github.com/pganalyze/pg_stat_plans /tmp/pg_stat_plans && \
      make -C /tmp/pg_stat_plans && make -C /tmp/pg_stat_plans install && rm -rf /tmp/pg_stat_plans; \
    fi

COPY --chown=postgres:postgres . /src
WORKDIR /src
RUN make && make install && make -C sql_edition install

# Playground defaults (override with -c on the command line).
ENV PG_MAJOR=${PG_MAJOR}
COPY docker/initdb/ /docker-entrypoint-initdb.d/
