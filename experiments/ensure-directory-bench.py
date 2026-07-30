#!/usr/bin/env python3
"""
ensure-directory-bench.py
Python 3 stdlib benchmark comparing 4 approaches to ensuring a directory exists.

Implementations:
  1. Bare mkdir subprocess
  2. Bare mkdir -p subprocess
  3. ensure_directory native (os.makedirs + stat checks + structured error)
  4. ensure_directory shell wrapper (subprocess shell=True)

Test cases: normal, already exists, permission denied, parent missing,
            file conflict, 50-level deep path.

Metrics: success rate, idempotency, error clarity, latency, retry safety.

Output: Markdown table to stdout.
"""

import os
import sys
import time
import errno
import shutil
import subprocess
import tempfile
import statistics
import textwrap


# ---------------------------------------------------------------------------
# Implementations
# ---------------------------------------------------------------------------

def impl_bare_mkdir(path, label="bare mkdir"):
    """subprocess mkdir (no -p). Fails if parent missing or path exists."""
    start = time.perf_counter()
    result = subprocess.run(["mkdir", path], capture_output=True, text=True)
    elapsed = time.perf_counter() - start
    ok = result.returncode == 0
    detail = result.stderr.strip() if result.stderr else "(no error)"
    return ok, detail, elapsed


def impl_bare_mkdir_p(path, label="bare mkdir -p"):
    """subprocess mkdir -p. Creates parents, tolerates existing."""
    start = time.perf_counter()
    result = subprocess.run(["mkdir", "-p", path], capture_output=True, text=True)
    elapsed = time.perf_counter() - start
    ok = result.returncode == 0
    detail = result.stderr.strip() if result.stderr else "(no error)"
    return ok, detail, elapsed


def impl_native(path, label="native os.makedirs"):
    """Python native os.makedirs + structured error reporting."""
    start = time.perf_counter()
    info = {"success": False, "error": None, "errno": None}
    try:
        os.makedirs(path, exist_ok=True)
        info["success"] = True
    except OSError as e:
        info["success"] = False
        info["error"] = str(e)
        info["errno"] = e.errno
        info["strerror"] = e.strerror
        # Enrich with stat info
        if e.errno in (errno.EEXIST, errno.ENOTDIR):
            try:
                info["exists"] = os.path.exists(path)
                info["is_dir"] = os.path.isdir(path)
            except OSError:
                info["exists"] = None
                info["is_dir"] = None
        elif e.errno == errno.EACCES:
            parent = os.path.dirname(path) or "."
            try:
                st = os.stat(parent)
                info["parent_mode"] = oct(stat.S_IMODE(st.st_mode))
            except OSError:
                info["parent_mode"] = None
    elapsed = time.perf_counter() - start
    ok = info["success"]
    detail = str(info)
    return ok, detail, elapsed


def impl_shell(path, label="shell wrapper"):
    """Shell wrapper: mkdir -p via subprocess with shell=True."""
    start = time.perf_counter()
    # Use sh -c with proper quoting to avoid injection via path names
    safe_path = path.replace("'", "'\\''")
    cmd = f"mkdir -p '{safe_path}'"
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    elapsed = time.perf_counter() - start
    ok = result.returncode == 0
    detail = result.stderr.strip() if result.stderr else "(no error)"
    return ok, detail, elapsed


IMPLEMENTATIONS = [
    ("bare mkdir",      impl_bare_mkdir),
    ("bare mkdir -p",   impl_bare_mkdir_p),
    ("native makedirs", impl_native),
    ("shell wrapper",   impl_shell),
]


# ---------------------------------------------------------------------------
# Test fixtures
# ---------------------------------------------------------------------------

class BenchFixture:
    """Manage a temporary workspace for one benchmark test case."""

    def __init__(self, workspace):
        self.workspace = workspace

    def make_path(self, *parts):
        return os.path.join(self.workspace, *parts)

    def cleanup(self):
        if os.path.isdir(self.workspace):
            shutil.rmtree(self.workspace, ignore_errors=True)


def setup_fixture(base, name):
    """Create a fresh fixture for a test case."""
    ws = os.path.join(base, name)
    shutil.rmtree(ws, ignore_errors=True)
    os.makedirs(ws)
    return BenchFixture(ws)


# Test case definitions: (name, setup_func, expected_success_map)
# expected_success_map: mapping from impl index to bool (whether it should succeed)

TEST_CASES = []


def case_normal(base):
    """Normal: directory does not exist, should succeed for all."""
    fx = setup_fixture(base, "normal")
    target = fx.make_path("new_dir")
    yield "normal", [True, True, True, True], fx, target
    fx.cleanup()


def case_already_exists(base):
    """Already exists: directory already present."""
    fx = setup_fixture(base, "exists")
    target = fx.make_path("existing_dir")
    os.makedirs(target, exist_ok=True)
    # bare mkdir fails (EEXIST), mkdir -p succeeds, native with exist_ok succeeds, shell succeeds
    yield "already_exists", [False, True, True, True], fx, target
    fx.cleanup()


def case_permission_denied(base):
    """Permission denied: parent has 000 perms."""
    fx = setup_fixture(base, "perms")
    lock = fx.make_path("locked")
    os.makedirs(lock)
    old_mode = os.stat(lock).st_mode
    os.chmod(lock, 0o000)
    target = os.path.join(lock, "subdir")
    yield "permission_denied", [False, False, False, False], fx, target
    os.chmod(lock, old_mode)
    fx.cleanup()


def case_parent_missing(base):
    """Parent missing: intermediate directory does not exist."""
    fx = setup_fixture(base, "parent_missing")
    target = fx.make_path("a", "b", "c")
    yield "parent_missing", [False, True, True, True], fx, target
    fx.cleanup()


def case_file_conflict(base):
    """File conflict: a regular file sits where the directory is requested."""
    fx = setup_fixture(base, "file_conflict")
    target = fx.make_path("regular_file")
    with open(target, "w") as f:
        f.write("i am a file, not a directory")
    yield "file_conflict", [False, False, False, False], fx, target
    fx.cleanup()


def case_deep_path(base):
    """50-level deep path: deeply nested directory creation."""
    fx = setup_fixture(base, "deep_path")
    deep = "/".join([f"d{i:03d}" for i in range(50)])
    target = fx.make_path(deep)
    yield "deep_path", [False, True, True, True], fx, target
    fx.cleanup()


ALL_TEST_CASES = [
    case_normal,
    case_already_exists,
    case_permission_denied,
    case_parent_missing,
    case_file_conflict,
    case_deep_path,
]


# ---------------------------------------------------------------------------
# Benchmark runner
# ---------------------------------------------------------------------------

def run_benchmark(iterations=5):
    """Run all implementations x test cases and return results matrix."""
    base = tempfile.mkdtemp(prefix="ensure_dir_bench_")
    results = []

    try:
        for case_fn in ALL_TEST_CASES:
            for case_name, expected, fx, target in case_fn(base):
                row = {
                    "test_case": case_name,
                    "expected": expected,
                }
                for impl_idx, (impl_name, impl_fn) in enumerate(IMPLEMENTATIONS):
                    latencies = []
                    successes = []
                    errors = []

                    for run_idx in range(iterations):
                        # Recreate fixture for each run to ensure clean state
                        # For already_exists and file_conflict, we need persistent state
                        fx.cleanup()
                        if case_name == "already_exists":
                            os.makedirs(fx.workspace)
                            os.makedirs(target, exist_ok=True)
                        elif case_name == "permission_denied":
                            os.makedirs(fx.workspace)
                            lock = os.path.join(fx.workspace, "locked")
                            os.makedirs(lock)
                            os.chmod(lock, 0o000)
                        elif case_name == "file_conflict":
                            os.makedirs(fx.workspace)
                            with open(target, "w") as f:
                                f.write("data")
                        elif case_name in ("normal", "parent_missing", "deep_path"):
                            os.makedirs(fx.workspace)

                        ok, detail, elapsed = impl_fn(target)
                        successes.append(ok)
                        errors.append(detail)
                        latencies.append(elapsed)

                    success_rate = sum(successes) / len(successes)
                    is_idempotent = _check_idempotent(impl_fn, target, case_name, fx)
                    error_clarity = _grade_error_clarity(errors, case_name)
                    is_retry_safe = _check_retry_safety(impl_fn, target, case_name, fx)
                    mean_lat = statistics.mean(latencies)
                    max_lat = max(latencies)

                    row[impl_name] = {
                        "success_rate": success_rate,
                        "idempotent": is_idempotent,
                        "error_clarity": error_clarity,
                        "retry_safe": is_retry_safe,
                        "latency_mean_ms": round(mean_lat * 1000, 3),
                        "latency_max_ms": round(max_lat * 1000, 3),
                    }

                results.append(row)
    finally:
        shutil.rmtree(base, ignore_errors=True)

    return results


def _check_idempotent(impl_fn, target, case_name, fx):
    """Run the impl twice and check the second run doesn't error."""
    try:
        # First run
        impl_fn(target)
        # Second run
        ok2, _, _ = impl_fn(target)
        return ok2
    except Exception:
        return False
    finally:
        # Cleanup
        try:
            if os.path.isdir(target):
                shutil.rmtree(target, ignore_errors=True)
            if os.path.isfile(target):
                os.unlink(target)
        except OSError:
            pass


def _check_retry_safety(impl_fn, target, case_name, fx):
    """Check that retrying doesn't leave stale state or corrupt data."""
    try:
        # Run 3 times in a row
        for _ in range(3):
            ok, _, _ = impl_fn(target)
            if not ok:
                return False
        return True
    except Exception:
        return False
    finally:
        try:
            if os.path.isdir(target):
                shutil.rmtree(target, ignore_errors=True)
            if os.path.isfile(target):
                os.unlink(target)
        except OSError:
            pass


def _grade_error_clarity(errors, case_name):
    """Grade error clarity: 3=explicit errno+msg, 2=msg only, 1=opaque."""
    grades = []
    for err in errors:
        if "errno" in err or "EEXIST" in err or "EACCES" in err or "ENOENT" in err or "ENOTDIR" in err or "ELOOP" in err:
            grades.append(3)
        elif any(word in err for word in ["error", "Error", "failed", "denied", "exist", "found", "space"]):
            grades.append(2)
        else:
            grades.append(1)
    if not grades:
        return 1
    return round(sum(grades) / len(grades), 1)


# ---------------------------------------------------------------------------
# Markdown output
# ---------------------------------------------------------------------------

def print_markdown_table(results):
    """Print results as a Markdown table."""
    impl_names = [name for name, _ in IMPLEMENTATIONS]
    sep = " | "

    # Header
    headers = ["Test Case"] + impl_names
    print(sep.join(headers))
    print(sep.join(["---"] * len(headers)))

    for row in results:
        cells = [row["test_case"]]
        for name in impl_names:
            d = row[name]
            # Format: SR% | IDP | CLR | Lμ | RTRY
            sr = f"{d['success_rate']:.0%}"
            idp = "Y" if d["idempotent"] else "N"
            clr = f"{d['error_clarity']}/3"
            lat = f"{d['latency_mean_ms']:.2f}ms"
            rtry = "Y" if d["retry_safe"] else "N"
            cells.append(f"{sr} {idp} {clr} {lat} {rtry}")
        print(sep.join(cells))

    print()
    print("*Format: SuccessRate Idempotent ErrorClarity/3 LatencyMean RetrySafe*")
    print()


def print_detailed_table(results):
    """Print a more detailed breakdown with separate columns per metric."""
    impl_names = [name for name, _ in IMPLEMENTATIONS]
    metrics = ["success_rate", "idempotent", "error_clarity", "latency_mean_ms", "retry_safe"]
    metric_labels = ["Success%", "Idempotent", "Clarity/3", "Latency(ms)", "RetrySafe"]
    sep = " | "

    for test_case in [r["test_case"] for r in results]:
        row = [r for r in results if r["test_case"] == test_case][0]

        print(f"**{test_case}**")
        print()

        # Per-metric header
        for impl_name in impl_names:
            hdr = sep.join([f"{impl_name} {ml}" for ml in metric_labels])
            print(f"| Metric | {hdr} |")
            break
        # Separator
        print(f"| {'-'.rjust(7,'-')} | {' | '.join(['---' * 5] * len(impl_names))} |")

        # Data rows - each metric gets its own row
        for mi, mname in enumerate(metrics):
            vals = []
            for impl_name in impl_names:
                v = row[impl_name][mname]
                if mname == "success_rate":
                    vals.append(f"{v:.0%}")
                elif mname == "idempotent":
                    vals.append("Y" if v else "N")
                elif mname == "error_clarity":
                    vals.append(f"{v}/3")
                elif mname == "latency_mean_ms":
                    vals.append(f"{v:.3f}")
                elif mname == "retry_safe":
                    vals.append("Y" if v else "N")
            print(f"| {metric_labels[mi]:>7} | {' | '.join(vals)} |")

        print()


def print_compact_results(results):
    """Print a compact pass/fail matrix."""
    impl_names = [name for name, _ in IMPLEMENTATIONS]
    sep = " | "

    headers = ["Test Case"] + impl_names
    print(sep.join(headers))
    print(sep.join(["---"] * len(headers)))

    for row in results:
        cells = [row["test_case"]]
        for name in impl_names:
            d = row[name]
            if d["success_rate"] >= 1.0:
                icon = "PASS"
            elif d["success_rate"] >= 0.5:
                icon = "PARTIAL"
            else:
                icon = "FAIL"
            cells.append(icon)
        print(sep.join(cells))

    print()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    iterations = 5
    if len(sys.argv) > 1:
        try:
            iterations = max(1, int(sys.argv[1]))
        except ValueError:
            print(f"Usage: {sys.argv[0]} [iterations]", file=sys.stderr)
            sys.exit(1)

    print("# ensure-directory-bench.py")
    print(f"*Benchmark: {len(IMPLEMENTATIONS)} implementations x 6 test cases, {iterations} iterations each*")
    print()

    results = run_benchmark(iterations=iterations)

    print("## Compact pass/fail matrix")
    print_compact_results(results)

    print("## Detailed results (per-test-case, per-metric)")
    print_detailed_table(results)

    print("## Summary table (SuccessRate Idempotent ErrorClarity/3 LatencyMean RetrySafe)")
    print_markdown_table(results)

    # Summary statistics
    print("## Aggregate")
    print()
    impl_names = [name for name, _ in IMPLEMENTATIONS]
    for impl_name in impl_names:
        srs = []
        lats = []
        for row in results:
            srs.append(row[impl_name]["success_rate"])
            lats.append(row[impl_name]["latency_mean_ms"])
        avg_sr = statistics.mean(srs) * 100
        avg_lat = statistics.mean(lats)
        print(f"- **{impl_name}**: avg success {avg_sr:.0f}%, avg latency {avg_lat:.3f}ms")
    print()

    # Error clarity comparison
    print("## Error clarity samples")
    print()
    base = tempfile.mkdtemp(prefix="ensure_dir_err_")
    try:
        # Collect one error message per impl on a known failure case
        ex_dir = os.path.join(base, "locked")
        os.makedirs(ex_dir)
        os.chmod(ex_dir, 0o000)
        ex_target = os.path.join(ex_dir, "sub")

        for impl_name, impl_fn in IMPLEMENTATIONS:
            ok, detail, _ = impl_fn(ex_target)
            # Truncate long detail
            if len(detail) > 200:
                detail = detail[:200] + "..."
            print(f'  - **{impl_name}**: exit_ok={ok}, detail=`{detail}`')
        print()

        os.chmod(ex_dir, 0o755)
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    main()
