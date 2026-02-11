#!/usr/bin/env bash
# run-ioping.sh <scenario> <bench_dir> <results_dir>
set -euo pipefail
SCENARIO="$1"; BENCH_DIR="$2"; RESULTS="$3"
IOPING_DIR="${RESULTS}/ioping"
mkdir -p "$IOPING_DIR"

COUNT="${IOPING_COUNT:-100}"

echo "=== ioping: sequential 4k ==="
ioping -c "$COUNT" -s 4k "$BENCH_DIR" > "$IOPING_DIR/seq-4k.txt" 2>&1
tail -3 "$IOPING_DIR/seq-4k.txt"

echo "=== ioping: random 4k ==="
ioping -c "$COUNT" -s 4k -R "$BENCH_DIR" > "$IOPING_DIR/rand-4k.txt" 2>&1
tail -3 "$IOPING_DIR/rand-4k.txt"

echo "=== ioping: sequential 512k ==="
ioping -c "$COUNT" -s 512k "$BENCH_DIR" > "$IOPING_DIR/seq-512k.txt" 2>&1
tail -3 "$IOPING_DIR/seq-512k.txt"

echo "=== ioping: random 512k ==="
ioping -c "$COUNT" -s 512k -R "$BENCH_DIR" > "$IOPING_DIR/rand-512k.txt" 2>&1
tail -3 "$IOPING_DIR/rand-512k.txt"

echo "=== IOPing complete ==="
