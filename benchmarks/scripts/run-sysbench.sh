#!/usr/bin/env bash
# run-sysbench.sh <scenario> <bench_dir> <results_dir>
set -euo pipefail
SCENARIO="$1"; BENCH_DIR="$2"; RESULTS="$3"
SB_DIR="${RESULTS}/sysbench"
mkdir -p "$SB_DIR"

DURATION="${SYSBENCH_DURATION:-60}"
THREADS="${SYSBENCH_THREADS:-8}"
FILE_SIZE="${SYSBENCH_FILE_SIZE:-4G}"

if ! command -v sysbench &>/dev/null; then
    echo "sysbench not found, skipping"
    exit 0
fi

cd "$BENCH_DIR"

echo "=== sysbench: preparing files ==="
sysbench fileio --file-total-size="$FILE_SIZE" prepare > "$SB_DIR/prepare.log" 2>&1

for mode in seqrd seqwr rndrd rndwr rndrw; do
    echo "=== sysbench fileio: ${mode} ==="
    sysbench fileio \
        --file-total-size="$FILE_SIZE" \
        --file-test-mode="$mode" \
        --time="$DURATION" \
        --threads="$THREADS" \
        --file-io-mode=sync \
        --file-fsync-freq=100 \
        run > "$SB_DIR/${mode}.txt" 2>&1

    grep -E "reads/s|writes/s|fsyncs/s|throughput|latency" "$SB_DIR/${mode}.txt" || true
    sleep 3
done

echo "=== sysbench: cleanup ==="
sysbench fileio --file-total-size="$FILE_SIZE" cleanup > /dev/null 2>&1

echo "=== Sysbench complete ==="
