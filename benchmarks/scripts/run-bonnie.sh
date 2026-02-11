#!/usr/bin/env bash
# run-bonnie.sh <scenario> <bench_dir> <results_dir>
set -euo pipefail
SCENARIO="$1"; BENCH_DIR="$2"; RESULTS="$3"
BONNIE_DIR="${RESULTS}/bonnie"
mkdir -p "$BONNIE_DIR"

SIZE="${BONNIE_SIZE_MB:-8192}"

if ! command -v bonnie++ &>/dev/null; then
    echo "bonnie++ not found, skipping"
    exit 0
fi

echo "=== bonnie++: ${SIZE}MB test ==="
bonnie++ -d "$BENCH_DIR" -s "${SIZE}M" -n 256 -u root -q \
    > "$BONNIE_DIR/bonnie.csv" 2>&1

bon_csv2txt < "$BONNIE_DIR/bonnie.csv" > "$BONNIE_DIR/bonnie.txt" 2>/dev/null || true
cat "$BONNIE_DIR/bonnie.txt" 2>/dev/null || cat "$BONNIE_DIR/bonnie.csv"

echo "=== Bonnie++ complete ==="
