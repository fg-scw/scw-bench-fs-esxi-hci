#!/usr/bin/env python3
"""
collect-results.py - Aggregate and compare benchmark results across scenarios.

Usage: python3 collect-results.py <results_base_dir> [--output report.md]

Reads JSON/TXT results from each scenario subdirectory and generates
a comparative report in Markdown format.
"""

import json
import os
import sys
import csv
import argparse
from pathlib import Path
from datetime import datetime


def parse_fio_json(filepath):
    """Parse a fio JSON output file and extract key metrics."""
    try:
        with open(filepath) as f:
            data = json.load(f)
        results = []
        for job in data.get("jobs", []):
            r = job.get("read", {})
            w = job.get("write", {})
            result = {
                "job_name": job.get("jobname", "unknown"),
                "read_iops": r.get("iops", 0),
                "read_bw_kbps": r.get("bw", 0),
                "read_lat_mean_ns": r.get("clat_ns", {}).get("mean", 0),
                "read_lat_p99_ns": r.get("clat_ns", {}).get("percentile", {}).get("99.000000", 0),
                "write_iops": w.get("iops", 0),
                "write_bw_kbps": w.get("bw", 0),
                "write_lat_mean_ns": w.get("clat_ns", {}).get("mean", 0),
                "write_lat_p99_ns": w.get("clat_ns", {}).get("percentile", {}).get("99.000000", 0),
            }
            results.append(result)
        return results
    except Exception as e:
        return [{"error": str(e)}]


def parse_ioping(filepath):
    """Parse ioping output for latency stats."""
    try:
        with open(filepath) as f:
            lines = f.readlines()
        # Last 3 lines typically contain the summary
        return {"summary": [l.strip() for l in lines[-3:] if l.strip()]}
    except Exception:
        return {"summary": ["parse error"]}


def parse_pgbench(filepath):
    """Extract TPS and latency from pgbench output."""
    try:
        with open(filepath) as f:
            content = f.read()
        tps = ""
        latency = ""
        for line in content.split("\n"):
            if "tps = " in line:
                tps = line.strip()
            if "latency average" in line:
                latency = line.strip()
        return {"tps": tps, "latency": latency}
    except Exception:
        return {"tps": "N/A", "latency": "N/A"}


def collect_scenario(scenario_dir):
    """Collect all benchmark results for a scenario."""
    results = {"fio": {}, "ioping": {}, "dd": {}, "bonnie": {}, "pgbench": {}, "sysbench": {}, "mlperf": {}}
    base = Path(scenario_dir)

    # FIO
    fio_dir = base / "fio"
    if fio_dir.exists():
        for f in fio_dir.glob("*.json"):
            results["fio"][f.stem] = parse_fio_json(f)

    # IOPing
    ioping_dir = base / "ioping"
    if ioping_dir.exists():
        for f in ioping_dir.glob("*.txt"):
            results["ioping"][f.stem] = parse_ioping(f)

    # PGBench
    pgbench_dir = base / "pgbench"
    if pgbench_dir.exists():
        for f in pgbench_dir.glob("*.txt"):
            results["pgbench"][f.stem] = parse_pgbench(f)

    # MLPerf
    mlperf_file = base / "mlperf" / "results.json"
    if mlperf_file.exists():
        with open(mlperf_file) as f:
            results["mlperf"] = json.load(f)

    return results


def generate_report(all_results, output_path):
    """Generate a comparative Markdown report."""
    scenarios = sorted(all_results.keys())

    with open(output_path, "w") as out:
        out.write(f"# Storage Benchmark Comparison Report\n\n")
        out.write(f"Generated: {datetime.now().isoformat()}\n\n")
        out.write(f"Scenarios compared: {', '.join(scenarios)}\n\n")

        # FIO Comparison Table
        out.write("## FIO Results\n\n")
        out.write("| Scenario | Profile | Read IOPS | Write IOPS | Read BW (MB/s) | Write BW (MB/s) | Read p99 (µs) | Write p99 (µs) |\n")
        out.write("|----------|---------|-----------|------------|----------------|-----------------|---------------|----------------|\n")

        for scenario in scenarios:
            fio = all_results[scenario].get("fio", {})
            for profile, jobs in sorted(fio.items()):
                for job in jobs:
                    if "error" in job:
                        continue
                    out.write(
                        f"| {scenario} | {profile} "
                        f"| {job['read_iops']:.0f} "
                        f"| {job['write_iops']:.0f} "
                        f"| {job['read_bw_kbps']/1024:.1f} "
                        f"| {job['write_bw_kbps']/1024:.1f} "
                        f"| {job['read_lat_p99_ns']/1000:.1f} "
                        f"| {job['write_lat_p99_ns']/1000:.1f} |\n"
                    )

        # PGBench Comparison
        out.write("\n## PGBench Results\n\n")
        out.write("| Scenario | Test | TPS | Latency |\n")
        out.write("|----------|------|-----|----------|\n")
        for scenario in scenarios:
            pgb = all_results[scenario].get("pgbench", {})
            for test, data in sorted(pgb.items()):
                out.write(f"| {scenario} | {test} | {data['tps']} | {data['latency']} |\n")

        # MLPerf Comparison
        out.write("\n## MLPerf Storage Results\n\n")
        out.write("| Scenario | Test | Throughput (MB/s) | Samples/s |\n")
        out.write("|----------|------|-------------------|----------|\n")
        for scenario in scenarios:
            mlp = all_results[scenario].get("mlperf", {})
            for test in mlp.get("tests", []):
                out.write(
                    f"| {scenario} | {test['name']} "
                    f"| {test.get('throughput_mbps', 'N/A')} "
                    f"| {test.get('samples_per_sec', 'N/A')} |\n"
                )

    print(f"Report written to: {output_path}")


def main():
    parser = argparse.ArgumentParser(description="Collect and compare storage benchmark results")
    parser.add_argument("results_dir", help="Base directory containing scenario subdirectories")
    parser.add_argument("--output", "-o", default="benchmark-report.md", help="Output report file")
    args = parser.parse_args()

    base = Path(args.results_dir)
    if not base.exists():
        print(f"ERROR: {base} does not exist")
        sys.exit(1)

    all_results = {}
    for scenario_dir in sorted(base.iterdir()):
        if scenario_dir.is_dir():
            # Check if there are timestamped subdirs, use the latest
            timestamped = sorted([d for d in scenario_dir.iterdir() if d.is_dir()])
            if timestamped:
                latest = timestamped[-1]
                print(f"Collecting: {scenario_dir.name} ({latest.name})")
                all_results[scenario_dir.name] = collect_scenario(latest)
            else:
                print(f"Collecting: {scenario_dir.name}")
                all_results[scenario_dir.name] = collect_scenario(scenario_dir)

    if not all_results:
        print("No results found!")
        sys.exit(1)

    generate_report(all_results, args.output)

    # Also save raw JSON
    json_path = args.output.replace(".md", ".json")
    with open(json_path, "w") as f:
        json.dump(all_results, f, indent=2, default=str)
    print(f"Raw data: {json_path}")


if __name__ == "__main__":
    main()
