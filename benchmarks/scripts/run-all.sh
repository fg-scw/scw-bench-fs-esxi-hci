#!/usr/bin/env bash
# =============================================================================
# run-all.sh - Master benchmark runner
# Usage: ./run-all.sh <scenario> <target_path>
# =============================================================================
set -euo pipefail

SCENARIO="${1:?Usage: $0 <scenario> <target_path>}"
TARGET_PATH="${2:?Usage: $0 <scenario> <target_path>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_BASE="${RESULTS_DIR:-/opt/benchmarks/results}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULTS="${RESULTS_BASE}/${SCENARIO}/${TIMESTAMP}"

GREEN='\033[0;32m'; NC='\033[0m'
log() { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $*"; }

log "========================================"
log "Storage Benchmark: ${SCENARIO}"
log "Target: ${TARGET_PATH}"
log "Results: ${RESULTS}"
log "========================================"

[ -d "$TARGET_PATH" ] || { echo "ERROR: $TARGET_PATH not found"; exit 1; }
mkdir -p "$RESULTS"

BENCH_DIR="${TARGET_PATH}/bench-${SCENARIO}"
mkdir -p "$BENCH_DIR"

# System info
uname -a > "$RESULTS/system-info.txt"
df -h "$TARGET_PATH" >> "$RESULTS/system-info.txt"

# Run each sub-benchmark
for script in run-fio.sh run-ioping.sh run-dd.sh run-bonnie.sh run-pgbench.sh run-sysbench.sh; do
    if [ -x "${SCRIPT_DIR}/${script}" ]; then
        log "--- Running: ${script} ---"
        "${SCRIPT_DIR}/${script}" "$SCENARIO" "$BENCH_DIR" "$RESULTS" || \
            log "WARN: ${script} had errors (continuing)"
    fi
done

log "========================================"
log "ALL BENCHMARKS COMPLETE"
log "Results in: ${RESULTS}"
log "========================================"
