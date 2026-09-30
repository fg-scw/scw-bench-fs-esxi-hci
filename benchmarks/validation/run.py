#!/usr/bin/env python3
"""Small, non-destructive filesystem comparison runner (Linux + fio)."""

import argparse
import fcntl
import hashlib
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path


def mount_allowed(path, allow_non_mount=False):
    return allow_non_mount or os.path.ismount(path)


def lock_attempt(path):
    with open(path, "a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return 0
        except BlockingIOError:
            return 1


LOCK_PROBE = """import sys
try:
    import fcntl
    lock = open(sys.argv[1], "a")
except Exception as exc:
    print(f"{type(exc).__name__}: {exc}", file=sys.stderr)
    sys.exit(2)

try:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    sys.exit(1)
except Exception as exc:
    print(f"{type(exc).__name__}: {exc}", file=sys.stderr)
    sys.exit(2)
sys.exit(0)
"""


def local_lock_check(path):
    with open(path, "a") as held:
        fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
        blocked = subprocess.run([sys.executable, "-c", LOCK_PROBE, str(path)],
                                 capture_output=True, text=True)
        fcntl.flock(held, fcntl.LOCK_UN)
    available = lock_attempt(path)
    return {"blocked_while_held": blocked.returncode == 1, "acquired_after_release": available == 0,
            "probe_exit_code": blocked.returncode,
            "probe_error": blocked.stderr.strip() if blocked.returncode not in (0, 1) else "",
            "pass": blocked.returncode == 1 and available == 0}


def peer_lock_check(peer, peer_path, path):
    # The peer probe is intentionally read-only except for opening the probe file.
    def attempt():
        remote = "python3 -c {} {}".format(shlex.quote(LOCK_PROBE), shlex.quote(peer_path))
        return subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", peer, remote],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    with open(path, "a") as held:
        fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
        blocked = attempt()
        fcntl.flock(held, fcntl.LOCK_UN)
    available = attempt()
    error = blocked.returncode not in (0, 1) or available.returncode not in (0, 1)
    return {"peer": peer, "local_path": str(path), "peer_path": peer_path,
            "blocked_while_held": blocked.returncode == 1,
            "acquired_after_release": available.returncode == 0,
            "while_held_exit_code": blocked.returncode,
            "after_release_exit_code": available.returncode,
            "ssh_or_probe_error": error,
            "probe_error": (blocked.stderr or available.stderr).strip() if error else "",
            "pass": blocked.returncode == 1 and available.returncode == 0 and not error}


def fio_metrics(data):
    jobs = []
    for job in data.get("jobs", []):
        sync_pct = job.get("sync", {}).get("lat_ns", {}).get("percentile", {})
        for direction in ("read", "write"):
            stats = job.get(direction, {})
            if not stats.get("io_bytes") and not stats.get("total_ios"):
                continue
            lat = stats.get("clat_ns", {})
            pct = lat.get("percentile", {})
            jobs.append({"job": job.get("jobname"), "direction": direction,
                         "iops": stats.get("iops", 0),
                         "throughput_mib_s": stats.get("bw_bytes", stats.get("bw", 0) * 1024) / (1024 ** 2),
                         "p50_us": pct.get("50.000000", 0) / 1000,
                         "p95_us": pct.get("95.000000", 0) / 1000,
                         "p99_us": pct.get("99.000000", 0) / 1000,
                         "fsync_p50_us": sync_pct.get("50.000000", 0) / 1000,
                         "fsync_p95_us": sync_pct.get("95.000000", 0) / 1000,
                         "fsync_p99_us": sync_pct.get("99.000000", 0) / 1000,
                         "fio_error": job.get("error", 0)})
    return jobs


def fio_run(path, name, rw, bs, size, runtime, direct):
    filename = path / "fio.data"
    cmd = ["fio", "--name=" + name, "--filename=" + str(filename), "--rw=" + rw,
           "--bs=" + bs, "--size=" + size, "--ioengine=sync", "--iodepth=1",
           "--numjobs=1", "--direct=" + str(direct), "--group_reporting",
           "--output-format=json"]
    if rw.startswith("rand"):
        cmd.append("--time_based=1")
        cmd.append("--runtime=" + str(runtime))
    if "write" in name:
        cmd.append("--end_fsync=1")
    if name == "sync-write-4k":
        cmd.append("--fdatasync=1")
    proc = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        result = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return {"profile": name, "exit_code": proc.returncode,
                "error": (proc.stderr or proc.stdout)[-2000:]}
    return {"profile": name, "exit_code": proc.returncode,
            "metrics": fio_metrics(result), "fio_errors": [j.get("error", 0) for j in result.get("jobs", [])],
            "stderr": proc.stderr[-1000:] if proc.returncode else "", "fio_raw": result}


def integrity_probe(directory):
    path = directory / "integrity.bin"
    block = bytes(range(256)) * 4096
    digest = hashlib.sha256(block).hexdigest()
    with open(path, "wb") as out:
        for _ in range(16):
            out.write(block)
        out.flush()
        os.fsync(out.fileno())
    h = hashlib.sha256()
    with open(path, "rb") as inp:
        for chunk in iter(lambda: inp.read(1024 * 1024), b""):
            h.update(chunk)
    path.unlink()
    return {"bytes": len(block) * 16, "sha256_expected": hashlib.sha256(block * 16).hexdigest(),
            "sha256_read": h.hexdigest(), "pass": h.hexdigest() == hashlib.sha256(block * 16).hexdigest()}


def publish_probe(local_dir, target_dir, size_mib):
    if not local_dir.is_dir() or not target_dir.is_dir():
        raise ValueError("publish source and destination must already be mounted directories")
    token = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    src = local_dir / ("publish-" + token + ".bin")
    tmp = target_dir / (".publish-" + token + ".tmp")
    dst = target_dir / ("publish-" + token + ".bin")
    h = hashlib.sha256()
    try:
        with open(src, "wb") as f:
            for _ in range(size_mib):
                block = os.urandom(1024 * 1024)
                f.write(block)
                h.update(block)
            f.flush()
            os.fsync(f.fileno())
        started = time.monotonic()
        with open(src, "rb") as inp, open(tmp, "xb") as out:
            shutil.copyfileobj(inp, out, 1024 * 1024)
            out.flush()
            os.fsync(out.fileno())
        os.replace(tmp, dst)
        dir_fd = os.open(target_dir, os.O_RDONLY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
        elapsed = time.monotonic() - started
        got = hashlib.sha256()
        with open(dst, "rb") as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b""):
                got.update(chunk)
        result = {"bytes": size_mib * 1024 * 1024, "seconds": elapsed,
                  "publish_mib_s": size_mib / elapsed, "sha256_expected": h.hexdigest(),
                  "sha256_read": got.hexdigest(), "pass": h.digest() == got.digest(),
                  "published_file": str(dst)}
        if result["pass"]:
            src.unlink()
        else:
            result["source_file"] = str(src)
        return result
    except Exception:
        tmp.unlink(missing_ok=True)
        dst.unlink(missing_ok=True)
        raise


def recovery_watch(path, seconds):
    """Poll by durable create/read/delete; an operator triggers recovery separately."""
    start = time.monotonic()
    if not os.path.ismount(path):
        raise ValueError("--watch path must be a mount point")
    deadline = time.monotonic() + seconds
    failures = []
    successes = 0
    recovered = False
    max_probe_s = 0
    slow_probes = []
    while time.monotonic() < deadline:
        now = time.monotonic()
        probe = path / (".recovery-probe-" + str(os.getpid()))
        try:
            if not os.path.ismount(path):
                raise OSError("mount point unavailable")
            payload = os.urandom(4096)
            with open(probe, "wb") as f:
                f.write(payload)
                f.flush()
                os.fsync(f.fileno())
            with open(probe, "rb") as f:
                if f.read() != payload:
                    raise OSError("probe integrity mismatch")
            probe.unlink()
            successes += 1
            elapsed = time.monotonic() - now
            max_probe_s = max(max_probe_s, elapsed)
            if elapsed >= 1:
                slow_probes.append({"started_at_s": round(now - start, 3),
                                    "duration_s": round(elapsed, 3)})
            if failures:
                recovered = True
                failures[-1]["recovered_at_s"] = now - start
        except OSError as exc:
            if not failures or failures[-1].get("recovered_at_s") is not None:
                failures.append({"started_at_s": now - start, "error": str(exc)})
        time.sleep(min(0.25, max(0, deadline - time.monotonic())))
    return {"path": str(path), "duration_s": seconds, "successful_probes": successes,
            "failure_periods": failures, "interruption_observed": bool(failures),
            "recovery_observed": recovered, "max_probe_s": round(max_probe_s, 3),
            "slow_probes": slow_probes}


def write_result(output_dir, prefix, data):
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    output = output_dir / (prefix + "-" + stamp + ".json")
    with output.open("x", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    return output


def report_failed(report):
    for case in report.get("cases", {}).values():
        if case.get("error") or case.get("cleanup_error"):
            return True
        for key in ("integrity", "flock_local", "flock_inter_host"):
            result = case.get(key)
            if result is not None and not result.get("pass", False):
                return True
        for run in case.get("fio", []):
            if run.get("error") or run.get("exit_code", 1) != 0:
                return True
            if any(code != 0 for code in run.get("fio_errors", [])):
                return True
            if any(metric.get("fio_error", 0) != 0 for metric in run.get("metrics", [])):
                return True
    if report.get("publish_error"):
        return True
    publish = report.get("publish")
    return publish is not None and not publish.get("pass", False)


def self_test():
    with tempfile.TemporaryDirectory() as temp:
        base = Path(temp)
        lock = local_lock_check(base / "lock")
        check = integrity_probe(base)
        metrics = fio_metrics({"jobs": [{"jobname": "demo", "read": {
            "io_bytes": 1, "iops": 2, "bw_bytes": 1048576, "clat_ns": {
                "percentile": {"50.000000": 10, "99.000000": 90}}}}]})
        source = base / "local"
        target = base / "target"
        source.mkdir()
        target.mkdir()
        publish = publish_probe(source, target, 2)
        assert lock["pass"] and check["pass"]
        assert not mount_allowed(base) and mount_allowed(base, allow_non_mount=True)
        assert metrics[0]["p50_us"] == 0.01 and metrics[0]["p99_us"] == 0.09
        assert publish["pass"] and publish["bytes"] == 2 * 1024 * 1024
        Path(publish["published_file"]).unlink()
        from unittest.mock import patch
        probe = subprocess.run([sys.executable, "-c", LOCK_PROBE, str(base / "missing" / "lock")],
                               capture_output=True, text=True)
        assert probe.returncode == 2 and "FileNotFoundError" in probe.stderr
        with patch("subprocess.run", side_effect=[
                subprocess.CompletedProcess(["ssh"], 2, "", "probe failed"),
                subprocess.CompletedProcess(["ssh"], 0, "", "")]):
            peer_lock = peer_lock_check("peer", str(base / "peer"), base / "peer-lock")
        assert not peer_lock["pass"] and peer_lock["ssh_or_probe_error"]
        assert peer_lock["while_held_exit_code"] == 2 and peer_lock["after_release_exit_code"] == 0
        assert peer_lock["local_path"] == str(base / "peer-lock")
        assert peer_lock["peer_path"] == str(base / "peer")
        assert report_failed({"cases": {"nfs": {"error": {"errno": 116}}}})
        assert report_failed({"cases": {"case": {"cleanup_error": {"errno": 5}}}})
        assert report_failed({"cases": {"case": {"fio": [{"exit_code": 1, "fio_errors": [1]}]}}})
        assert report_failed({"cases": {"case": {"integrity": {"pass": False}}}})
        assert report_failed({"cases": {"case": {"flock_local": {"pass": False}}}})
        assert report_failed({"publish": {"pass": False}})
        assert not report_failed({"cases": {"case": {"fio": [{"exit_code": 0, "fio_errors": [0]}]}}})
        fixed_time = datetime(2026, 9, 30, tzinfo=timezone.utc)
        with patch(__name__ + ".datetime") as mock_datetime:
            mock_datetime.now.return_value = fixed_time
            archived = write_result(base, "exclusive", {"value": 1})
            try:
                write_result(base, "exclusive", {"value": 2})
            except FileExistsError:
                pass
            else:
                assert False, "write_result overwrote an existing result"
        assert json.loads(archived.read_text()) == {"value": 1}
    print("self-test: PASS (local/peer flock, error aggregation, integrity, fio metrics, publish)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", action="append", default=[], metavar="NAME=PATH",
                        help="mounted test directory; repeat for virtiofs, loop-ext4, or iscsi-esxi")
    parser.add_argument("--allow-non-mount", action="store_true",
                        help="allow benchmarking a directory that is not a mount point")
    parser.add_argument("--out", type=Path, default=Path("validation-results"))
    parser.add_argument("--size", default="256M", help="fio test file size (default: 256M)")
    parser.add_argument("--runtime", type=int, default=20, help="seconds for random fio runs")
    parser.add_argument("--direct", type=int, choices=(0, 1), default=1)
    parser.add_argument("--peer", help="SSH destination for optional inter-host flock proof")
    parser.add_argument("--peer-path", help="same shared lock directory path as visible on --peer")
    parser.add_argument("--publish-local", type=Path, help="local staging directory for publish test")
    parser.add_argument("--publish-to", type=Path, help="File Storage destination for publish test")
    parser.add_argument("--publish-size-mib", type=int, default=64)
    parser.add_argument("--watch", type=Path, help="poll a mounted path while an operator tests recovery")
    parser.add_argument("--watch-seconds", type=int, default=120)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if args.watch:
        if args.watch_seconds < 1 or not args.watch.is_dir():
            parser.error("--watch requires an existing directory and positive --watch-seconds")
        result = recovery_watch(args.watch.resolve(), args.watch_seconds)
        output_dir = args.out
        output_dir.mkdir(parents=True, exist_ok=True)
        output = write_result(output_dir, "recovery", result)
        print(output)
        return 0
    if args.runtime < 1 or args.publish_size_mib < 1:
        parser.error("runtime and publish-size-mib must be positive")
    if bool(args.peer) != bool(args.peer_path):
        parser.error("--peer and --peer-path must be used together")
    if bool(args.publish_local) != bool(args.publish_to):
        parser.error("--publish-local and --publish-to must be used together")
    if not args.case and not args.publish_to:
        parser.error("provide at least one --case or a publish test")
    cases = []
    for item in args.case:
        if "=" not in item:
            parser.error("--case must be NAME=PATH")
        name, raw_path = item.split("=", 1)
        path = Path(raw_path).resolve()
        if not name or not path.is_dir() or not os.access(path, os.W_OK):
            parser.error("case name/path must identify an existing writable directory: " + item)
        if not mount_allowed(path, args.allow_non_mount):
            parser.error("case path is not a mount point (refusing writes to the underlying filesystem): " + str(path))
        cases.append((name, path))
    if args.publish_to:
        args.publish_to = args.publish_to.resolve()
        if not args.publish_to.is_dir():
            parser.error("--publish-to must be an existing directory")
        if not mount_allowed(args.publish_to, args.allow_non_mount):
            parser.error("--publish-to is not a mount point; use --allow-non-mount only for an intentional local test")
    if shutil.which("fio") is None and args.case:
        parser.error("fio is required for --case runs")
    args.out.mkdir(parents=True, exist_ok=True)
    report = {"created_utc": datetime.now(timezone.utc).isoformat(), "fio_size": args.size,
              "fio_runtime_seconds": args.runtime if args.case else None,
              "fio_version": subprocess.run(["fio", "--version"], capture_output=True, text=True).stdout.strip()
              if args.case else None, "kernel": os.uname().release,
              "direct": args.direct, "cases": {}}
    if shutil.which("losetup"):
        report["loop_devices"] = subprocess.run(
            ["losetup", "--list", "--output", "NAME,BACK-FILE,DIO"],
            capture_output=True, text=True
        ).stdout.strip()
    for name, base in cases:
        case = {"path": str(base), "fio": []}
        report["cases"][name] = case
        work = None
        try:
            work = Path(tempfile.mkdtemp(prefix="ponytail-validation-", dir=base))
            lock = local_lock_check(work / "flock.probe")
            mount = subprocess.run(["findmnt", "-T", str(base), "-n", "-o", "SOURCE,FSTYPE,OPTIONS"],
                                   capture_output=True, text=True)
            case.update({"mount": mount.stdout.strip(), "flock_local": lock,
                         "integrity": integrity_probe(work)})
            if args.peer:
                peer_lock_path = str(Path(args.peer_path) / work.name / "flock-peer.probe")
                case["flock_inter_host"] = peer_lock_check(args.peer, peer_lock_path,
                                                            work / "flock-peer.probe")
            for profile in (("seq-write", "write", "1M"), ("seq-read", "read", "1M"),
                            ("rand-read-4k", "randread", "4k"), ("rand-write-4k", "randwrite", "4k"),
                            ("sync-write-4k", "randwrite", "4k")):
                case["fio"].append(fio_run(work, *profile, args.size, args.runtime, args.direct))
        except OSError as exc:
            case["error"] = {"errno": exc.errno, "message": str(exc)}
        finally:
            if work is not None:
                try:
                    shutil.rmtree(work)
                except OSError as exc:
                    case["cleanup_error"] = {"errno": exc.errno, "message": str(exc)}
    if args.publish_to:
        try:
            report["publish"] = publish_probe(args.publish_local, args.publish_to, args.publish_size_mib)
        except Exception as exc:
            report["publish_error"] = {"type": type(exc).__name__, "message": str(exc),
                                        "errno": getattr(exc, "errno", None)}
    output = write_result(args.out, "validation", report)
    print(output)
    return 1 if report_failed(report) else 0


if __name__ == "__main__":
    raise SystemExit(main())
