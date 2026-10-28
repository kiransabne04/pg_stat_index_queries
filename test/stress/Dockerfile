# PostgreSQL built from source with assertions (--enable-cassert) and
# AddressSanitizer + UndefinedBehaviorSanitizer, with the extension built
# against it. QA only: slow, not for benchmarks. ASan's quarantine is kept
# small: at the default 256 MB per process, ~60 backends exhaust an 8 GB
# Docker VM and the kernel OOM-kills backends (looks like a crash).
#
#   docker build -f test/stress/Dockerfile --build-arg PGV=17.11 -t siq-debug:17 .
#   docker run --rm siq-debug:17 make installcheck PG_CONFIG=/usr/local/pgsql/bin/pg_config
#   docker run --rm --shm-size=1g -e DUR=120 siq-debug:17 bash test/stress/stress.sh
FROM debian:bookworm
ARG PGV=17.11
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential curl ca-certificates libreadline-dev zlib1g-dev libipc-run-perl bison flex pkg-config libicu-dev \
      perl procps python3 bzip2 && rm -rf /var/lib/apt/lists/*
RUN useradd -m postgres
WORKDIR /build
RUN curl -fsSL https://ftp.postgresql.org/pub/source/v${PGV}/postgresql-${PGV}.tar.bz2 | tar xj
ENV SAN="-fsanitize=address,undefined -fno-sanitize=alignment -fno-omit-frame-pointer"
RUN cd postgresql-${PGV} && \
    ./configure --prefix=/usr/local/pgsql --enable-cassert --enable-debug --enable-tap-tests \
      CFLAGS="-O1 -g $SAN" LDFLAGS="$SAN" > /tmp/configure.log 2>&1 || (tail -30 /tmp/configure.log; exit 1)
RUN cd postgresql-${PGV} && make -j"$(nproc)" -s > /tmp/make.log 2>&1 || (grep -E 'error' /tmp/make.log | head -20; exit 1)
RUN cd postgresql-${PGV} && make -s install >/dev/null && \
    make -C contrib/pg_stat_statements -s install >/dev/null
RUN chown -R postgres /build
ENV PATH=/usr/local/pgsql/bin:$PATH \
    ASAN_OPTIONS=detect_leaks=0:abort_on_error=1:log_path=/tmp/asan:quarantine_size_mb=8:malloc_context_size=5 \
    UBSAN_OPTIONS=print_stacktrace=1:log_path=/tmp/ubsan
COPY --chown=postgres:postgres . /src
WORKDIR /src
USER postgres
RUN make clean >/dev/null && make COPT=-Werror PG_CONFIG=/usr/local/pgsql/bin/pg_config >/dev/null
USER root
RUN make install PG_CONFIG=/usr/local/pgsql/bin/pg_config >/dev/null
USER postgres
