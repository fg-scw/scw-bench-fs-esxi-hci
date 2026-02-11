#!/usr/bin/env bash
# run-dd.sh <scenario> <bench_dir> <results_dir>
set -euo pipefail
SCENARIO="$1"; BENCH_DIR="$2"; RESULTS="$3"
DD_DIR="${RESULTS}/dd"
mkdir -p "$DD_DIR"

echo "=== dd: write 1GB (1M blocks) ==="
dd if=/dev/zero of="${BENCH_DIR}/dd-test" bs=1M count=1024 conv=fdatasync 2> "$DD_DIR/write-1m.txt"
cat "$DD_DIR/write-1m.txt"

echo "=== dd: read 1GB (1M blocks) ==="
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
dd if="${BENCH_DIR}/dd-test" of=/dev/null bs=1M 2> "$DD_DIR/read-1m.txt"
cat "$DD_DIR/read-1m.txt"

echo "=== dd: write 1GB (4K blocks - small IO) ==="
dd if=/dev/zero of="${BENCH_DIR}/dd-test-4k" bs=4k count=262144 conv=fdatasync 2> "$DD_DIR/write-4k.txt"
cat "$DD_DIR/write-4k.txt"

rm -f "${BENCH_DIR}/dd-test" "${BENCH_DIR}/dd-test-4k"
echo "=== DD complete ==="
