#!/usr/bin/env bash
# run-pgbench.sh <scenario> <bench_dir> <results_dir>
set -euo pipefail
SCENARIO="$1"; BENCH_DIR="$2"; RESULTS="$3"
PG_DIR="${RESULTS}/pgbench"
mkdir -p "$PG_DIR"

SCALE="${PGBENCH_SCALE:-100}"
DURATION="${PGBENCH_DURATION:-60}"
CLIENTS="${PGBENCH_CLIENTS:-10}"

if ! command -v pgbench &>/dev/null; then
    echo "pgbench not found, skipping"
    exit 0
fi

PGDATA="${BENCH_DIR}/pgdata-$$"
PG_BIN=$(dirname "$(find /usr/lib/postgresql -name pg_ctl 2>/dev/null | head -1)")

if [ -z "$PG_BIN" ]; then
    echo "PostgreSQL binaries not found, skipping"
    exit 0
fi

# Initialize PostgreSQL on target storage
echo "=== pgbench: initializing database on target storage ==="
mkdir -p "$PGDATA"
chown postgres:postgres "$PGDATA"
sudo -u postgres "$PG_BIN/initdb" -D "$PGDATA" > "$PG_DIR/init-db.log" 2>&1

# Configure for benchmarking
cat >> "$PGDATA/postgresql.conf" << EOF
shared_buffers = 256MB
effective_cache_size = 1GB
wal_buffers = 16MB
checkpoint_completion_target = 0.9
synchronous_commit = on
fsync = on
full_page_writes = on
listen_addresses = 'localhost'
port = 5433
EOF

# Start PostgreSQL
sudo -u postgres "$PG_BIN/pg_ctl" -D "$PGDATA" -l "$PGDATA/logfile" start
sleep 3

# Create and initialize benchmark database
sudo -u postgres "$PG_BIN/createdb" -p 5433 benchdb 2>/dev/null || true
sudo -u postgres pgbench -i -s "$SCALE" -p 5433 benchdb > "$PG_DIR/pgbench-init.log" 2>&1

# Read-only benchmark
echo "=== pgbench: read-only (${CLIENTS} clients, ${DURATION}s) ==="
sudo -u postgres pgbench -S -c "$CLIENTS" -T "$DURATION" -p 5433 benchdb \
    > "$PG_DIR/readonly.txt" 2>&1
grep -E "tps|latency" "$PG_DIR/readonly.txt" || true

# Read-write benchmark (default TPC-B-like)
echo "=== pgbench: read-write (${CLIENTS} clients, ${DURATION}s) ==="
sudo -u postgres pgbench -c "$CLIENTS" -T "$DURATION" -p 5433 benchdb \
    > "$PG_DIR/readwrite.txt" 2>&1
grep -E "tps|latency" "$PG_DIR/readwrite.txt" || true

# Cleanup
sudo -u postgres "$PG_BIN/pg_ctl" -D "$PGDATA" stop 2>/dev/null || true
rm -rf "$PGDATA"

echo "=== PGBench complete ==="
