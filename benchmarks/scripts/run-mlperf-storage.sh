#!/usr/bin/env bash
# run-mlperf-storage.sh <scenario> <bench_dir> <results_dir>
# Simulates ML training data pipeline: sequential + random HDF5 file loading
set -euo pipefail
SCENARIO="$1"; BENCH_DIR="$2"; RESULTS="$3"
ML_DIR="${RESULTS}/mlperf"
mkdir -p "$ML_DIR"

DATA_DIR="${BENCH_DIR}/mlperf-data"
VENV="${VENV_PATH:-/opt/benchmarks/mlperf-venv}"
NUM_SAMPLES="${MLPERF_SAMPLES:-100}"

# Check dependencies
if [ ! -d "$VENV" ]; then
    echo "Creating Python venv for MLPerf..."
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install -q numpy h5py 2>/dev/null || {
        echo "Cannot install h5py, skipping MLPerf"
        exit 0
    }
fi

echo "=== MLPerf Storage: generating synthetic dataset ==="
"$VENV/bin/python3" << PYEOF
import numpy as np
import h5py
import os, time

data_dir = "$DATA_DIR"
n_samples = $NUM_SAMPLES
os.makedirs(data_dir, exist_ok=True)

start = time.time()
for i in range(n_samples):
    fp = os.path.join(data_dir, f"sample_{i:04d}.hdf5")
    if not os.path.exists(fp):
        with h5py.File(fp, 'w') as f:
            # UNET3D-like: 128x128x128 volume + label
            f.create_dataset('data', data=np.random.randn(1, 128, 128, 128).astype(np.float32))
            f.create_dataset('label', data=np.random.randint(0, 3, (1, 128, 128, 128)).astype(np.int8))
elapsed = time.time() - start
print(f"Generated {n_samples} samples in {elapsed:.1f}s")
PYEOF

echo "=== MLPerf Storage: running benchmarks ==="
"$VENV/bin/python3" << 'PYEOF' > "$ML_DIR/results.json" 2> "$ML_DIR/benchmark.log"
import numpy as np
import h5py
import os, time, json

data_dir = os.environ.get("DATA_DIR", "$DATA_DIR")
results = {"scenario": "$SCENARIO", "tests": []}
files = sorted([f for f in os.listdir(data_dir) if f.endswith('.hdf5')])
print(f"Found {len(files)} samples", flush=True)

# Test 1: Sequential epoch (training data loading)
print("--- Sequential epoch ---", flush=True)
start = time.time()
total_bytes = 0
for f in files:
    with h5py.File(os.path.join(data_dir, f), 'r') as hf:
        data = hf['data'][:]
        label = hf['label'][:]
        total_bytes += data.nbytes + label.nbytes
elapsed = time.time() - start
r = {"name": "sequential_epoch", "files": len(files),
     "total_mb": total_bytes/1e6, "elapsed_s": round(elapsed, 3),
     "throughput_mbps": round(total_bytes/1e6/elapsed, 1),
     "samples_per_sec": round(len(files)/elapsed, 2)}
results["tests"].append(r)
print(f"  {r['throughput_mbps']} MB/s, {r['samples_per_sec']} samples/s", flush=True)

# Test 2: Random access epoch (shuffled training)
print("--- Random epoch ---", flush=True)
np.random.seed(42)
shuffled = list(np.random.permutation(files))
start = time.time()
total_bytes = 0
for f in shuffled:
    with h5py.File(os.path.join(data_dir, f), 'r') as hf:
        data = hf['data'][:]
        total_bytes += data.nbytes
elapsed = time.time() - start
r = {"name": "random_epoch", "files": len(files),
     "total_mb": total_bytes/1e6, "elapsed_s": round(elapsed, 3),
     "throughput_mbps": round(total_bytes/1e6/elapsed, 1),
     "samples_per_sec": round(len(files)/elapsed, 2)}
results["tests"].append(r)
print(f"  {r['throughput_mbps']} MB/s, {r['samples_per_sec']} samples/s", flush=True)

# Test 3: Multi-worker simulation (parallel data loading)
print("--- Multi-worker (4 workers) ---", flush=True)
from concurrent.futures import ThreadPoolExecutor
def load_sample(filepath):
    with h5py.File(filepath, 'r') as hf:
        return hf['data'][:].nbytes
start = time.time()
with ThreadPoolExecutor(max_workers=4) as ex:
    total_bytes = sum(ex.map(load_sample, [os.path.join(data_dir, f) for f in files]))
elapsed = time.time() - start
r = {"name": "parallel_4workers", "files": len(files),
     "total_mb": total_bytes/1e6, "elapsed_s": round(elapsed, 3),
     "throughput_mbps": round(total_bytes/1e6/elapsed, 1),
     "samples_per_sec": round(len(files)/elapsed, 2)}
results["tests"].append(r)
print(f"  {r['throughput_mbps']} MB/s, {r['samples_per_sec']} samples/s", flush=True)

print(json.dumps(results, indent=2))
PYEOF

cat "$ML_DIR/benchmark.log"
echo "=== MLPerf Storage complete ==="
