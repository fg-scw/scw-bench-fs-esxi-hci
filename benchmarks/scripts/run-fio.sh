#!/usr/bin/env bash
# run-fio.sh <scenario> <bench_dir> <results_dir>
set -euo pipefail
SCENARIO="$1"; BENCH_DIR="$2"; RESULTS="$3"
FIO_DIR="${RESULTS}/fio"
mkdir -p "$FIO_DIR"

BENCH_FILE="${BENCH_DIR}/fio-testfile"
FIO_PROFILES_DIR="$(dirname "$0")/../fio-profiles"

# If no profile directory, use inline profiles
if [ -d "$FIO_PROFILES_DIR" ] && ls "$FIO_PROFILES_DIR"/*.fio &>/dev/null; then
    for profile in "$FIO_PROFILES_DIR"/*.fio; do
        name=$(basename "$profile" .fio)
        echo "=== fio: $name ==="
        BENCH_FILE="$BENCH_FILE" fio "$profile" \
            --output-format=json --output="$FIO_DIR/${name}.json" 2>&1
        rm -f "$BENCH_FILE"
        sleep 3
    done
else
    # Inline tests
    COMMON="--ioengine=libaio --direct=1 --size=10G --runtime=60 --time_based --ramp_time=5 --group_reporting --filename=$BENCH_FILE"

    echo "=== fio: random-read-4k ==="
    fio $COMMON --name=rr4k --rw=randread --bs=4k --iodepth=32 --numjobs=4 \
        --output-format=json --output="$FIO_DIR/random-read-4k.json"
    rm -f "$BENCH_FILE"; sleep 3

    echo "=== fio: random-write-4k ==="
    fio $COMMON --name=rw4k --rw=randwrite --bs=4k --iodepth=32 --numjobs=4 \
        --output-format=json --output="$FIO_DIR/random-write-4k.json"
    rm -f "$BENCH_FILE"; sleep 3

    echo "=== fio: mixed-randrw-4k ==="
    fio $COMMON --name=mix4k --rw=randrw --rwmixread=70 --bs=4k --iodepth=32 --numjobs=4 \
        --output-format=json --output="$FIO_DIR/mixed-randrw-4k.json"
    rm -f "$BENCH_FILE"; sleep 3

    echo "=== fio: seq-read-1m ==="
    fio $COMMON --name=sr1m --rw=read --bs=1m --iodepth=8 --numjobs=4 \
        --output-format=json --output="$FIO_DIR/seq-read-1m.json"
    rm -f "$BENCH_FILE"; sleep 3

    echo "=== fio: seq-write-1m ==="
    fio $COMMON --name=sw1m --rw=write --bs=1m --iodepth=8 --numjobs=4 \
        --output-format=json --output="$FIO_DIR/seq-write-1m.json"
    rm -f "$BENCH_FILE"; sleep 3

    echo "=== fio: latency-profile ==="
    fio --ioengine=libaio --direct=1 --size=10G --runtime=60 --time_based \
        --ramp_time=5 --group_reporting --filename="$BENCH_FILE" \
        --name=lat --rw=randread --bs=4k --iodepth=1 --numjobs=1 \
        --percentile_list=50:90:95:99:99.9:99.99 \
        --output-format=json --output="$FIO_DIR/latency-profile.json"
    rm -f "$BENCH_FILE"
fi

echo "=== FIO complete ==="
