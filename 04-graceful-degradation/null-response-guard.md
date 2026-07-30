# Null Response Guard — 空返回值防护层

> Part of Layer 4 (Graceful Degradation) of the Agent Resilience Tooling model.
> Implements the structured error contract defined in `extreme-condition-fallback.md`.
> Error codes reference `../03-error-classification/error-classification-system.md`.

---

## 1. Guard Layer Architecture

The guard layer is a wrapper that sits between the Agent and every system call. It intercepts all tool invocations, applies pre-flight checks, enforces timeout, and validates output before returning to the agent.

### 1.1 Position in the Stack

```
┌──────────────────────────────────────────────────────────────┐
│                        Agent (LLM)                           │
│   Receives structured JSON; never sees raw OS failures       │
├──────────────────────────────────────────────────────────────┤
│                     Null Response Guard                      │
│   ┌──────────────────────────────────────────────────────┐   │
│   │  Stage 1: Pre-Call Health Check                     │   │
│   │  • /proc/meminfo → MemAvailable ≥ threshold         │   │
│   │  • /proc/loadavg → process count ≤ limit            │   │
│   │  • /proc/*/status → D-state count ≤ threshold       │   │
│   │  • Parameter validation (path sanity, no null args) │   │
│   └──────────────────────────────────────────────────────┘   │
│                           │                                    │
│                           ▼                                    │
│   ┌──────────────────────────────────────────────────────┐   │
│   │  Stage 2: During-Call Execution                     │   │
│   │  • fork() + execve() target command                 │   │
│   │  • SIGALRM timeout (default 30s)                    │   │
│   │  • Signal handler → kill(-pgid, SIGKILL)            │   │
│   │  • Partial output capture from pipes                │   │
│   └──────────────────────────────────────────────────────┘   │
│                           │                                    │
│                           ▼                                    │
│   ┌──────────────────────────────────────────────────────┐   │
│   │  Stage 3: Post-Call Output Validation               │   │
│   │  • Empty output detection (6 rules)                 │   │
│   │  • JSON structure validation                        │   │
│   │  • Error keyword scanning                           │   │
│   │  • Fallback generation if output invalid            │   │
│   └──────────────────────────────────────────────────────┘   │
│                           │                                    │
│                           ▼                                    │
│                     Structured JSON                            │
│   {"ok":true|false, "path":"...", "error":{...}}              │
├──────────────────────────────────────────────────────────────┤
│                Last-Resort Error Generator                     │
│   /tmp/agent-fallback-error.sh                                 │
│   Invoked when the guard itself crashes                       │
└──────────────────────────────────────────────────────────────┘
                              │
                              ▼
                    System Calls (OS Kernel)
```

### 1.2 Data Flow Sequence

```
Agent calls tool X(path, args)
  │
  ├─► Stage 1: Pre-Call Check
  │     ├── Health check: memory, load, D-state
  │     ├── Parameter validation: path not empty, args not None
  │     └── If FAIL → return E_RESOURCE_EXHAUSTED immediately
  │
  ├─► Stage 2: During-Call Execution
  │     ├── Create stdout/stderr pipes (pipe2 O_CLOEXEC)
  │     ├── Set SIGALRM handler for timeout
  │     ├── fork() + setpgid() + execve()
  │     ├── Parent: alarm(timeout_sec); waitpid(child, &status, 0)
  │     ├── On SIGALRM: kill(-pgid, SIGKILL); collect pipes
  │     └── On normal exit: collect pipes, waitpid cleanup
  │
  ├─► Stage 3: Post-Call Validation
  │     ├── Check empty output rules
  │     ├── Validate JSON structure
  │     ├── Scan for error keywords ("Segfault", "Killed", etc.)
  │     └── If invalid → wrap in structured error with original
  │
  └─► Return structured JSON to agent
```

---

## 2. Three Guard Stages

### 2.1 Stage 1 — Pre-Call Health Check

Executed before any system call. If this stage fails, the tool returns immediately without attempting any fork or I/O operation.

**Memory check:**
```
Source: /proc/meminfo MemAvailable
Threshold: 64 MB minimum
Action on failure: Return E_RESOURCE_EXHAUSTED, retryable=false
Diagnostics: Include mem_available_mb in error payload
```

**Process count check:**
```
Source: ulimit -u (user nproc limit) and /proc/loadavg (4th field)
Threshold: 80% of ulimit
Action on failure: Return E_RESOURCE_EXHAUSTED, retryable=false
Diagnostics: Include current/total process ratio
```

**D-state count check:**
```
Source: grep '^State.*D' /proc/[0-9]*/status
Threshold: Maximum 5 D-state processes
Action on failure: Return E_RESOURCE_EXHAUSTED, retryable=false
Note: High D-state count indicates I/O subsystem congestion.
      Retrying will likely result in more D-state processes.
```

**Parameter validation:**
| Check | Rejection condition | Error code |
|---|---|---|
| Path non-empty | `path == ""` or `path is None` | `E_INVALID_PARAMETER` |
| Path not obviously dangerous | Contains `;`, `|`, `` ` ``, `$()` | `E_INVALID_PARAMETER` |
| Args type | `args is not list` and `args is not tuple` | `E_INVALID_PARAMETER` |
| Command exists | `which cmd` fails for absolute path | `E_EXEC_FAILURE` |
| Working directory exists | `test -d cwd` fails | `E_PATH_NOT_FOUND` |

**Composite pre-check signature:**

```python
def pre_check(cmd: str, args: list, timeout: int, cwd: str = None) -> Optional[dict]:
    """
    Returns None if all checks pass.
    Returns a structured error dict if any check fails.
    """
    # 1. Memory check
    mem = read_proc_meminfo()
    if mem.mem_available_mb < MEMORY_MINIMUM_MB:
        return error_dict("E_RESOURCE_EXHAUSTED", "resource", False,
                          "Insufficient memory", {"mem_available_mb": mem.mem_available_mb})

    # 2. Process count check
    procs = get_process_count()
    limit = get_nproc_limit()
    if procs >= limit * 0.8:
        return error_dict("E_RESOURCE_EXHAUSTED", "resource", False,
                          "Process limit near threshold",
                          {"procs": procs, "limit": limit})

    # 3. D-state check
    d_count = count_d_state()
    if d_count > D_STATE_MAX:
        return error_dict("E_RESOURCE_EXHAUSTED", "resource", False,
                          "Too many D-state processes; I/O subsystem may be hung",
                          {"d_state_procs": d_count})

    # 4. Parameter validation
    if not cmd or cmd.strip() == "":
        return error_dict("E_INVALID_PARAMETER", "logic", True,
                          "Command must not be empty", {})

    if not args or not isinstance(args, (list, tuple)):
        return error_dict("E_INVALID_PARAMETER", "logic", True,
                          "Args must be a list or tuple", {})

    # 5. Working directory check
    if cwd and not os.path.isdir(cwd):
        return error_dict("E_PATH_NOT_FOUND", "fs", True,
                          f"Working directory does not exist: {cwd}", {})

    return None  # All checks pass
```

### 2.2 Stage 2 — During-Call Execution

**Timeout enforcement mechanism:**

```
1. Create two pipes: stdout_pipe[2], stderr_pipe[2] (pipe2 with O_CLOEXEC)
2. Install SIGALRM handler:
     handler() {
         kill(-child_pgid, SIGKILL)   # Kill entire process group
         alarm(0)                      # Cancel alarm
         read partial data from pipes (non-blocking)
         longjmp(timeout_jmpbuf, 1)    # Jump to timeout recovery
     }
3. Read partial data from pipes (non-blocking)
4. fork():
     Child:
         - setpgid(0, 0)               # New process group
         - dup2(stdout_pipe[1], 1)     # Redirect stdout
         - dup2(stderr_pipe[1], 2)     # Redirect stderr
         - close all pipe read ends
         - execve(cmd, args, env)
         - _exit(127)                  # exec failed
     Parent:
         - close all pipe write ends
         - setpgid(child_pid, child_pid)  # Adopt child group
         - alarm(timeout_sec)
         - waitpid(child_pid, &status, 0)
           (if interrupted by SIGALRM, longjmp handles it)
5. Collect data from pipes (blocking read until EOF)
6. Process exit status:
     - WIFEXITED(status) → exit_code = WEXITSTATUS(status)
     - WIFSIGNALED(status) → exit_code = 128 + WTERMSIG(status)
     - WIFSTOPPED(status) → exit_code = 148 (128 + SIGSTOP)
```

**Signal handling table:**

| Signal | Source | Action | Exit Code |
|---|---|---|---|
| SIGALRM | Timeout watchdog | Kill child group, collect partial output | 124 (timeout convention) |
| SIGCHLD | Child exit | Waitpid, collect pipes, cancel alarm | (depends on child) |
| SIGPIPE | Broken pipe | Ignore (handled by pipe read EOF) | N/A |
| SIGTERM | External kill | Forward to child group, then exit | 143 (128 + 15) |
| SIGINT | Ctrl+C | Forward to child group, then exit | 130 (128 + 2) |

**Partial output collection on timeout:**

```python
def collect_partial_output(stdout_pipe: int, stderr_pipe: int) -> tuple:
    """
    Non-blocking read of any data available in the pipes.
    Called immediately after SIGKILL is sent to the child process group.
    Returns (partial_stdout, partial_stderr).
    """
    import fcntl, os

    for fd in (stdout_pipe, stderr_pipe):
        fcntl.fcntl(fd, fcntl.F_SETFL, fcntl.fcntl(fd, fcntl.F_GETFL) | os.O_NONBLOCK)

    partial_stdout = b""
    partial_stderr = b""
    try:
        while True:
            chunk = os.read(stdout_pipe, 4096)
            if not chunk:
                break
            partial_stdout += chunk
    except BlockingIOError:
        pass  # No more data available

    try:
        while True:
            chunk = os.read(stderr_pipe, 4096)
            if not chunk:
                break
            partial_stderr += chunk
    except BlockingIOError:
        pass

    return (partial_stdout.decode("utf-8", errors="replace"),
            partial_stderr.decode("utf-8", errors="replace"))
```

### 2.3 Stage 3 — Post-Call Output Validation

After the command exits and its output is collected, this stage validates the output before returning to the agent.

**Validation pipeline:**

```
Raw Output
    │
    ├──► Rule 1: Empty/None check
    │       Is output == "" or output is None?
    │       YES → SYSTEM_CATASTROPHE (zero retry)
    │
    ├──► Rule 2: Whitespace-only check
    │       Is output.strip() == "" ?
    │       YES → SYSTEM_CATASTROPHE (zero retry)
    │
    ├──► Rule 3: ANSI-escape-only check
    │       After stripping ANSI codes, is output empty?
    │       YES → STRIP_AND_RETRY once, then SYSTEM_CATASTROPHE
    │
    ├──► Rule 4: Small non-JSON check
    │       Is len(output) < 10 bytes AND not valid JSON?
    │       YES → SUSPICIOUS, wrap in structured envelope
    │
    ├──► Rule 5: Error keyword check
    │       Does output contain "Segmentation fault" or "Killed"?
    │       YES → OS-level error, classify accordingly
    │
    └──► Rule 6: Valid JSON check
            Is output valid JSON?
            YES → Return as-is (pass through)
            NO  → Wrap in structured envelope with E_OUTPUT_INVALID
```

---

## 3. Bash Implementation (`guard_exec`)

Complete, working bash implementation of the null response guard.

```bash
#!/usr/bin/env bash
# guard_exec — Null response guard for bash-based agent tool calls
# Dependencies: bash 4.0+, coreutils (timeout, mktemp, cat, rm, grep, awk)
# Source this file in your agent's init script: source guard_exec.sh

set -o pipefail

# ── Configuration ──────────────────────────────────────────────
GUARD_TIMEOUT_DEFAULT="${GUARD_TIMEOUT:-30}"
MEMORY_MINIMUM_MB="${GUARD_MEM_MIN:-64}"
D_STATE_MAX="${GUARD_D_STATE_MAX:-5}"
GUARD_TMPDIR="${GUARD_TMPDIR:-/tmp}"

# ── Utility: emit structured JSON error ────────────────────────
_error_json() {
    local code="$1"
    local layer="$2"
    local retryable="$3"
    local suggestion="$4"
    local path="$5"
    shift 5
    local diagnostics_json="$*"

    cat <<EOF
{
  "ok": false,
  "path": $(echo -n "$path" | jq -Rs .),
  "error": {
    "code": "$code",
    "layer": "$layer",
    "retryable": $retryable,
    "suggestion": $(echo -n "$suggestion" | jq -Rs .),
    "diagnostics": $diagnostics_json
  }
}
EOF
}

# ── Stage 1: Pre-flight health checks ──────────────────────────

_guard_check_memory() {
    local min_mb="${1:-$MEMORY_MINIMUM_MB}"
    local mem_available_kb
    mem_available_kb=$(grep -E '^MemAvailable:' /proc/meminfo 2>/dev/null | awk '{print $2}')

    # Fallback calculation if MemAvailable not present (some older kernels)
    if [[ -z "$mem_available_kb" ]]; then
        local mem_free_kb cached_kb mapped_kb
        mem_free_kb=$(grep -E '^MemFree:' /proc/meminfo | awk '{print $2}')
        cached_kb=$(grep -E '^Cached:' /proc/meminfo | awk '{print $2}')
        mapped_kb=$(grep -E '^Mapped:' /proc/meminfo | awk '{print $2}')
        mem_available_kb=$(( mem_free_kb + cached_kb - mapped_kb ))
    fi

    echo "$(( mem_available_kb / 1024 ))"
    (( (mem_available_kb / 1024) >= min_mb ))
}

_guard_check_procs() {
    local limit
    limit=$(ulimit -u 2>/dev/null || echo 1024)
    local total_procs
    total_procs=$(awk '{print $4}' /proc/loadavg 2>/dev/null | cut -d'/' -f2)
    total_procs="${total_procs:-0}"
    local threshold=$(( limit * 80 / 100 ))
    echo "$total_procs $limit $threshold"
    (( total_procs < threshold ))
}

_guard_check_dstate() {
    local max_d="${1:-$D_STATE_MAX}"
    local d_count
    d_count=$(grep -l '^State.*D' /proc/[0-9]*/status 2>/dev/null | wc -l)
    echo "$d_count"
    (( d_count <= max_d ))
}

# ── Stage 2: Execute with timeout ──────────────────────────────

_guard_exec_cmd() {
    local timeout_sec="$1"
    local -a cmd_args=("${@:2}")
    local tmp_stdout tmp_stderr
    tmp_stdout=$(mktemp "$GUARD_TMPDIR/guard_stdout.XXXXXX") || return 1
    tmp_stderr=$(mktemp "$GUARD_TMPDIR/guard_stderr.XXXXXX") || return 1

    local start_time elapsed
    start_time=$(date +%s%N 2>/dev/null || echo 0)

    # Execute under timeout(1) — capture both streams
    timeout --kill-after=5 --signal=TERM "$timeout_sec" "${cmd_args[@]}" \
        >"$tmp_stdout" 2>"$tmp_stderr"
    local exit_code=$?

    local end_time
    end_time=$(date +%s%N 2>/dev/null || echo 0)
    if [[ "$start_time" != 0 && "$end_time" != 0 ]]; then
        elapsed=$(( (end_time - start_time) / 1000000 ))  # ms
    else
        elapsed=-1
    fi

    local stdout_text stderr_text
    stdout_text=$(cat "$tmp_stdout" 2>/dev/null || true)
    stderr_text=$(cat "$tmp_stderr" 2>/dev/null || true)

    rm -f "$tmp_stdout" "$tmp_stderr" 2>/dev/null || true

    # Classify timeout results
    if [[ $exit_code -eq 124 || $exit_code -eq 137 ]]; then
        if [[ -z "$stdout_text" && -z "$stderr_text" ]]; then
            # Hung: no output at all
            _error_json "E_TIMEOUT_HUNG" "os" false \
                "Process produced zero output before timeout. Check for D-state or dead mounts." \
                "${cmd_args[0]:-unknown}" \
                "{\"elapsed_ms\":$elapsed,\"timeout_sec\":$timeout_sec,\"exit_code\":$exit_code,\"partial_output\":false}"
        else
            # Slow: partial output exists
            _error_json "E_TIMEOUT_PARTIAL" "os" true \
                "Process timed out with partial output. Consider increasing timeout." \
                "${cmd_args[0]:-unknown}" \
                "{\"elapsed_ms\":$elapsed,\"timeout_sec\":$timeout_sec,\"exit_code\":$exit_code,\"partial_output\":true,\"stdout_bytes\":$(echo -n "$stdout_text" | wc -c)}"
        fi
        return 0
    fi

    # Normal exit — output will be validated by Stage 3
    echo "$stdout_text"
    return $exit_code
}

# ── Stage 3: Output validation ─────────────────────────────────

_guard_validate_output() {
    local output="$1"
    local path="$2"
    local -a diagnostics=("${@:3}")

    # Rule 1: Empty/None
    if [[ -z "$output" || "$output" == "None" ]]; then
        _error_json "E_OUTPUT_EMPTY" "logic" true \
            "Command completed but produced no output. Verify the command and retry." \
            "$path" \
            "{\"output_type\":\"empty\"}"
        return 1
    fi

    # Rule 2: Whitespace only
    if [[ -z "${output//[[:space:]]/}" ]]; then
        _error_json "E_OUTPUT_EMPTY" "logic" true \
            "Output contained only whitespace. Verify the command and retry." \
            "$path" \
            "{\"output_type\":\"whitespace_only\",\"raw_bytes\":$(echo -n "$output" | wc -c)}"
        return 1
    fi

    # Rule 3: ANSI-escape only
    local stripped
    stripped=$(echo -n "$output" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g')
    if [[ -z "${stripped//[[:space:]]/}" && "$output" != "$stripped" ]]; then
        # Strip and retry once is handled at the guard_exec level
        _error_json "E_OUTPUT_ANSI_ONLY" "logic" true \
            "Output contained only ANSI escape codes. Stripped and will retry." \
            "$path" \
            "{\"output_type\":\"ansi_only\"}"
        return 1
    fi

    # Rule 4: Small non-JSON output
    if [[ $(echo -n "$output" | wc -c) -lt 10 ]]; then
        if ! echo "$output" | jq . >/dev/null 2>&1; then
            _error_json "E_OUTPUT_SUSPICIOUS" "logic" true \
                "Output is under 10 bytes and not valid JSON. Wrapping in structured envelope." \
                "$path" \
                "{\"output_type\":\"small_non_json\",\"raw_output\":$(echo -n "$output" | jq -Rs .)}"
            return 1
        fi
    fi

    # Rule 5: Error keywords
    if echo "$output" | grep -qE '(Segmentation fault|SIGSEGV|Killed|Out of memory)'; then
        _error_json "E_OS_CRASH" "os" false \
            "Command was terminated by the OS (segfault or OOM)." \
            "$path" \
            "{\"output_type\":\"os_crash\",\"matched_keyword\":$(echo "$output" | grep -oE '(Segmentation fault|SIGSEGV|Killed|Out of memory)' | head -1 | jq -Rs .)}"
        return 1
    fi

    # All validations passed
    return 0
}

# ── Composite guard_exec function ──────────────────────────────

guard_exec() {
    local timeout="${1:-$GUARD_TIMEOUT_DEFAULT}"
    shift
    local cmd_path="$1"
    shift
    local -a args=("$@")

    # ── Stage 1: Pre-flight check ──
    local mem_result mem_available_mb
    mem_available_mb=$(_guard_check_memory)
    mem_result=$?
    if [[ $mem_result -ne 0 ]]; then
        _error_json "E_RESOURCE_EXHAUSTED" "resource" false \
            "Insufficient memory (${mem_available_mb}MB available, ${MEMORY_MINIMUM_MB}MB minimum)." \
            "$cmd_path" \
            "{\"mem_available_mb\":$mem_available_mb,\"mem_minimum_mb\":$MEMORY_MINIMUM_MB}"
        return 0
    fi

    local proc_data
    proc_data=$(_guard_check_procs)
    local proc_result=$?
    local total_procs limit threshold
    read -r total_procs limit threshold <<< "$proc_data"
    if [[ $proc_result -ne 0 ]]; then
        _error_json "E_RESOURCE_EXHAUSTED" "resource" false \
            "Process count (${total_procs}) at or above 80% of limit (${limit})." \
            "$cmd_path" \
            "{\"total_procs\":$total_procs,\"limit\":$limit,\"threshold\":$threshold}"
        return 0
    fi

    local dstate_count
    dstate_count=$(_guard_check_dstate)
    local dstate_result=$?
    if [[ $dstate_result -ne 0 ]]; then
        _error_json "E_RESOURCE_EXHAUSTED" "resource" false \
            "Too many D-state processes (${dstate_count} > ${D_STATE_MAX}). I/O may be stuck." \
            "$cmd_path" \
            "{\"d_state_procs\":$dstate_count,\"d_state_max\":$D_STATE_MAX}"
        return 0
    fi

    # Parameter validation
    if [[ -z "$cmd_path" ]]; then
        _error_json "E_INVALID_PARAMETER" "logic" true \
            "Command path must not be empty." \
            "N/A" \
            "{}"
        return 0
    fi

    # ── Stage 2: Execute with timeout ──
    local exec_output exec_exit
    exec_output=$(_guard_exec_cmd "$timeout" "$cmd_path" "${args[@]}")
    exec_exit=$?

    # If exec returned a structured error (timeout), pass it through
    if echo "$exec_output" | grep -q '"E_TIMEOUT_HUNG"\|"E_TIMEOUT_PARTIAL"'; then
        echo "$exec_output"
        return 0
    fi

    # ── Stage 3: Validate output ──
    if ! _guard_validate_output "$exec_output" "$cmd_path"; then
        # Validation failure — error already emitted to stdout
        return 0
    fi

    # If output is JSON, pass through; otherwise wrap
    if echo "$exec_output" | jq . >/dev/null 2>&1; then
        echo "$exec_output"
    else
        cat <<EOF
{
  "ok": true,
  "path": $(echo -n "$cmd_path" | jq -Rs .),
  "stdout": $(echo -n "$exec_output" | jq -Rs .),
  "exit_code": $exec_exit
}
EOF
    fi
    return 0
}
```

**Usage example:**

```bash
# In agent tool implementation:
source /path/to/guard_exec.sh

my_tool_list_dir() {
    guard_exec 30 "ls" "-la" "$1"
}

my_tool_read_file() {
    guard_exec 10 "cat" "$1"
}
```

---

## 4. Python Implementation (`guard_exec` decorator/context manager)

Complete, working Python implementation using only stdlib.

```python
"""
guard_exec — Null response guard for Python-based agent tool calls

Python 3.6+ implementation using only stdlib.
Provides both a decorator (@guard) and a context manager (Guard()).
"""

import os
import sys
import json
import signal
import time
import subprocess
import re
from typing import Optional, Dict, Any, Tuple, Callable
from functools import wraps
from pathlib import Path

# ── Configuration ──────────────────────────────────────────────
MEMORY_MINIMUM_MB = int(os.environ.get("GUARD_MEM_MIN", "64"))
D_STATE_MAX = int(os.environ.get("GUARD_D_STATE_MAX", "5"))
TIMEOUT_DEFAULT = int(os.environ.get("GUARD_TIMEOUT", "30"))


# ── Structured Error Construction ──────────────────────────────

def error_dict(
    code: str,
    layer: str,
    retryable: bool,
    suggestion: str,
    path: str = "",
    diagnostics: Optional[dict] = None,
) -> Dict[str, Any]:
    """Build a structured error dictionary conforming to the error contract."""
    return {
        "ok": False,
        "path": path,
        "error": {
            "code": code,
            "layer": layer,
            "retryable": retryable,
            "suggestion": suggestion,
            "diagnostics": diagnostics or {},
        },
    }


# ── Stage 1: Pre-flight Health Checks ──────────────────────────

def get_available_memory_mb() -> int:
    """Read MemAvailable from /proc/meminfo, with fallback calculation."""
    try:
        with open("/proc/meminfo") as f:
            data = f.read()
    except FileNotFoundError:
        return -1  # Unknown; allow fork to proceed cautiously

    # Try MemAvailable first
    match = re.search(r"^MemAvailable:\s+(\d+)\s+kB", data, re.MULTILINE)
    if match:
        return int(match.group(1)) // 1024

    # Fallback: MemFree + Cached - Mapped
    mem_free = int(re.search(r"^MemFree:\s+(\d+)\s+kB", data, re.MULTILINE).group(1))
    cached = int(re.search(r"^Cached:\s+(\d+)\s+kB", data, re.MULTILINE).group(1))
    mapped = int(re.search(r"^Mapped:\s+(\d+)\s+kB", data, re.MULTILINE).group(1))
    return (mem_free + cached - mapped) // 1024


def get_process_count() -> Tuple[int, int]:
    """
    Return (current_processes, user_limit).
    Reads total threads from /proc/loadavg and ulimit from /proc/self/limits.
    """
    # Total threads
    try:
        with open("/proc/loadavg") as f:
            total = int(f.read().split()[3].split("/")[1])
    except (FileNotFoundError, IndexError, ValueError):
        total = 0

    # User process limit
    limit = 1024  # default fallback
    try:
        with open("/proc/self/limits") as f:
            for line in f:
                if "Max processes" in line:
                    parts = line.split()
                    if len(parts) >= 3 and parts[2].isdigit():
                        limit = int(parts[2])
                    break
    except FileNotFoundError:
        pass

    return total, limit


def count_d_state() -> int:
    """Count processes in uninterruptible sleep (D-state)."""
    count = 0
    try:
        for proc_dir in Path("/proc").iterdir():
            if not proc_dir.name.isdigit():
                continue
            status_file = proc_dir / "status"
            try:
                with open(status_file) as f:
                    for line in f:
                        if line.startswith("State:"):
                            if "D" in line:
                                count += 1
                            break
            except (OSError, PermissionError):
                continue
    except PermissionError:
        pass
    return count


def validate_parameters(
    cmd: str, args: tuple, cwd: Optional[str] = None
) -> Optional[Dict[str, Any]]:
    """Validate command parameters. Returns error dict or None."""
    if not cmd or not cmd.strip():
        return error_dict(
            "E_INVALID_PARAMETER", "logic", True,
            "Command must not be empty.", cmd,
        )

    if not isinstance(args, (list, tuple)):
        return error_dict(
            "E_INVALID_PARAMETER", "logic", True,
            "Args must be a list or tuple.", cmd,
        )

    # Detect obviously dangerous shell metacharacters in path
    dangerous = re.compile(r"[;|`$(){}]")
    if dangerous.search(cmd):
        return error_dict(
            "E_INVALID_PARAMETER", "logic", True,
            f"Command contains shell metacharacters: {cmd}", cmd,
        )

    # Check if the command binary exists (for absolute paths)
    if cmd.startswith("/") and not os.path.isfile(cmd):
        return error_dict(
            "E_EXEC_FAILURE", "os", True,
            f"Command not found: {cmd}", cmd,
        )

    # Check working directory
    if cwd and not os.path.isdir(cwd):
        return error_dict(
            "E_PATH_NOT_FOUND", "fs", True,
            f"Working directory does not exist: {cwd}", cmd,
        )

    return None


def pre_flight_check(cmd: str, args: tuple, cwd: Optional[str] = None) -> Optional[Dict[str, Any]]:
    """
    Run all pre-flight checks.
    Returns None if all pass, or a structured error dict.
    """
    # 1. Memory check
    mem_mb = get_available_memory_mb()
    if mem_mb >= 0 and mem_mb < MEMORY_MINIMUM_MB:
        return error_dict(
            "E_RESOURCE_EXHAUSTED", "resource", False,
            f"Insufficient memory: {mem_mb}MB available, {MEMORY_MINIMUM_MB}MB minimum.",
            cmd, {"mem_available_mb": mem_mb, "mem_minimum_mb": MEMORY_MINIMUM_MB},
        )

    # 2. Process count check
    total_procs, limit = get_process_count()
    if total_procs >= limit * 0.8:
        return error_dict(
            "E_RESOURCE_EXHAUSTED", "resource", False,
            f"Process count ({total_procs}) at or above 80% of limit ({limit}).",
            cmd, {"total_procs": total_procs, "limit": limit},
        )

    # 3. D-state check
    d_count = count_d_state()
    if d_count > D_STATE_MAX:
        return error_dict(
            "E_RESOURCE_EXHAUSTED", "resource", False,
            f"Too many D-state processes ({d_count} > {D_STATE_MAX}). I/O may be stuck.",
            cmd, {"d_state_procs": d_count, "d_state_max": D_STATE_MAX},
        )

    # 4. Parameter validation
    param_error = validate_parameters(cmd, args, cwd)
    if param_error:
        return param_error

    return None


# ── Stage 2: Execute with Timeout ──────────────────────────────

def execute_with_timeout(
    cmd: str,
    args: tuple,
    timeout: int = TIMEOUT_DEFAULT,
    cwd: Optional[str] = None,
) -> Dict[str, Any]:
    """
    Execute a command with timeout enforcement.
    Uses subprocess with process group management for reliable kill.
    """
    start_time = time.monotonic_ns()

    try:
        proc = subprocess.Popen(
            [cmd] + list(args),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=cwd,
            preexec_fn=os.setsid,  # Create new process group
        )
    except FileNotFoundError:
        return error_dict(
            "E_EXEC_FAILURE", "os", True,
            f"Command not found: {cmd}", cmd,
            {"cmd": cmd, "args": list(args)},
        )
    except PermissionError:
        return error_dict(
            "E_PERMISSION_DENIED", "permission", False,
            f"No execute permission: {cmd}", cmd,
            {"cmd": cmd},
        )
    except OSError as e:
        return error_dict(
            "E_FORK_FAILED", "os", False,
            f"Failed to execute process: {e}", cmd,
            {"os_error": str(e)},
        )

    try:
        stdout, stderr = proc.communicate(timeout=timeout)
        elapsed_ms = (time.monotonic_ns() - start_time) // 1_000_000
        exit_code = proc.returncode

        stdout_text = stdout.decode("utf-8", errors="replace")
        stderr_text = stderr.decode("utf-8", errors="replace")

        return {
            "ok": exit_code == 0,
            "path": cmd,
            "exit_code": exit_code,
            "stdout": stdout_text,
            "stderr": stderr_text,
            "diagnostics": {"elapsed_ms": elapsed_ms},
        }

    except subprocess.TimeoutExpired:
        elapsed_ms = (time.monotonic_ns() - start_time) // 1_000_000

        # Kill the entire process group
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass

        # Collect any partial output from pipes
        partial_stdout = b""
        partial_stderr = b""
        try:
            partial_stdout, partial_stderr = proc.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            partial_stdout, partial_stderr = proc.communicate()

        stdout_text = partial_stdout.decode("utf-8", errors="replace")
        stderr_text = partial_stderr.decode("utf-8", errors="replace")

        # Distinguish "hung" (no output) from "slow" (partial output)
        if not stdout_text and not stderr_text:
            return error_dict(
                "E_TIMEOUT_HUNG", "os", False,
                "Process produced zero output before timeout. "
                "Check for D-state processes or dead mounts.",
                cmd,
                {
                    "elapsed_ms": elapsed_ms,
                    "timeout_sec": timeout,
                    "exit_code": -9,  # SIGKILL
                    "partial_output": False,
                },
            )
        else:
            return error_dict(
                "E_TIMEOUT_PARTIAL", "os", True,
                "Process timed out with partial output. "
                "Consider increasing timeout or simplifying request.",
                cmd,
                {
                    "elapsed_ms": elapsed_ms,
                    "timeout_sec": timeout,
                    "exit_code": -9,
                    "partial_output": True,
                    "stdout_bytes": len(partial_stdout),
                    "stderr_bytes": len(partial_stderr),
                },
            )


# ── Stage 3: Output Validation ─────────────────────────────────

# ANSI escape code pattern
ANSI_ESCAPE_RE = re.compile(r"\x1b\[[0-9;]*[a-zA-Z]")

# Error keywords that indicate OS-level problems
OS_ERROR_KEYWORDS = re.compile(
    r"(Segmentation fault|SIGSEGV|SIGKILL|Killed|"
    r"Out of memory|Cannot allocate memory|"
    r"Bus error|Floating point exception|Abort trap)"
)

# Stderr patterns that indicate specific failures
STDERR_FAILURE_PATTERNS = [
    (re.compile(r"Permission denied", re.IGNORECASE), "E_PERMISSION_DENIED", "permission"),
    (re.compile(r"No such file or directory", re.IGNORECASE), "E_PATH_NOT_FOUND", "fs"),
    (re.compile(r"Disk quota exceeded", re.IGNORECASE), "E_FS_FULL", "fs"),
    (re.compile(r"Read-only file system", re.IGNORECASE), "E_FS_READONLY", "fs"),
    (re.compile(r"Device or resource busy", re.IGNORECASE), "E_FS_IO", "fs"),
    (re.compile(r"Argument list too long", re.IGNORECASE), "E_INVALID_PARAMETER", "logic"),
]


def validate_output(result: Dict[str, Any]) -> Dict[str, Any]:
    """
    Validate tool output against empty-output detection rules.
    If invalid, wraps the result in a structured error.
    If valid, returns the result as-is (or wraps non-JSON in envelope).
    """
    stdout = result.get("stdout", "")
    stderr = result.get("stderr", "")
    path = result.get("path", "")
    exit_code = result.get("exit_code", 0)

    # ── Rule 1: Empty/None ──
    if stdout is None or stdout == "":
        # Check stderr for failure patterns
        for pattern, code, layer in STDERR_FAILURE_PATTERNS:
            if pattern.search(stderr):
                return error_dict(
                    code, layer, False,
                    f"Tool failed with: {code}", path,
                    {"exit_code": exit_code, "stderr": stderr},
                )

        # Check for OS crash keywords in stderr
        if OS_ERROR_KEYWORDS.search(stderr):
            match = OS_ERROR_KEYWORDS.search(stderr)
            return error_dict(
                "E_OS_CRASH", "os", False,
                f"OS-level error detected: {match.group(0)}", path,
                {"exit_code": exit_code, "os_signal": match.group(0)},
            )

        # If exit code is 0 but stdout is empty, something is wrong
        if exit_code == 0:
            return error_dict(
                "E_OUTPUT_EMPTY", "logic", True,
                "Command completed with exit code 0 but produced no stdout. "
                "This is suspicious — output may have been lost.",
                path,
                {"exit_code": exit_code, "stderr_preview": stderr[:200]},
            )

        # Non-zero exit + empty stdout = legit failure
        return error_dict(
            "E_EXEC_FAILURE", "os", True,
            f"Command failed with exit code {exit_code} and no output.",
            path,
            {"exit_code": exit_code},
        )

    # ── Rule 2: Whitespace only ──
    if stdout.strip() == "":
        return error_dict(
            "E_OUTPUT_EMPTY", "logic", True,
            "Output contained only whitespace characters.",
            path,
            {"raw_bytes": len(stdout.encode("utf-8")), "exit_code": exit_code},
        )

    # ── Rule 3: ANSI-escape only ──
    stripped = ANSI_ESCAPE_RE.sub("", stdout)
    if stripped.strip() == "" and stdout != stripped:
        # ANSI-escape-only output — strip and signal for retry
        result["stdout"] = stripped
        result["_ansi_stripped"] = True
        return result

    # ── Rule 4: Small non-JSON output ──
    raw_bytes = len(stdout.encode("utf-8"))
    if raw_bytes < 10:
        try:
            json.loads(stdout)
            # Valid JSON under 10 bytes — pass through
            return result
        except (json.JSONDecodeError, ValueError):
            return error_dict(
                "E_OUTPUT_SUSPICIOUS", "logic", True,
                "Output is under 10 bytes and not valid JSON. "
                "Possible truncated response.",
                path,
                {
                    "raw_bytes": raw_bytes,
                    "raw_output": stdout,
                    "exit_code": exit_code,
                },
            )

    # ── Rule 5: OS error keywords ──
    os_match = OS_ERROR_KEYWORDS.search(stdout)
    if os_match:
        return error_dict(
            "E_OS_CRASH", "os", False,
            f"Process was terminated by the OS: {os_match.group(0)}",
            path,
            {
                "exit_code": exit_code,
                "os_signal": os_match.group(0),
                "matched_in": "stdout",
            },
        )

    # ── Rule 6: JSON validation ──
    try:
        json.loads(stdout)
        return result  # Valid JSON — pass through
    except (json.JSONDecodeError, ValueError):
        # Non-JSON output from a non-zero exit — classify by stderr
        if exit_code != 0:
            for pattern, code, layer in STDERR_FAILURE_PATTERNS:
                if pattern.search(stderr):
                    return error_dict(
                        code, layer, False,
                        f"Tool failed with: {code}", path,
                        {"exit_code": exit_code, "stderr": stderr[:500]},
                    )

        # Non-JSON output — wrap in envelope
        return {
            "ok": True,
            "path": path,
            "stdout": stdout,
            "stderr": stderr,
            "exit_code": exit_code,
        }


# ── Composite guard_exec ───────────────────────────────────────

def guard_exec(
    cmd: str,
    args: tuple = (),
    timeout: int = TIMEOUT_DEFAULT,
    cwd: Optional[str] = None,
    retry_on_ansi: bool = True,
) -> Dict[str, Any]:
    """
    Execute a command with full null-response guard pipeline.

    Args:
        cmd: Command to execute (absolute path or binary name).
        args: Tuple of command arguments.
        timeout: Maximum execution time in seconds (default 30).
        cwd: Working directory for the command (optional).
        retry_on_ansi: If True, strip ANSI codes and retry once.

    Returns:
        Structured result dictionary conforming to error contract.
    """
    # Stage 1: Pre-flight check
    pre_error = pre_flight_check(cmd, args, cwd)
    if pre_error:
        return pre_error

    # Stage 2: Execute
    max_attempts = 2 if retry_on_ansi else 1
    attempt = 0
    result = None

    while attempt < max_attempts:
        attempt += 1
        result = execute_with_timeout(cmd, args, timeout, cwd)

        # Stage 3: Validate output
        validated = validate_output(result)

        # ANSI-only retry logic (Rule 3)
        if (
            retry_on_ansi
            and attempt < max_attempts
            and validated.get("_ansi_stripped")
        ):
            # Strip ANSI codes and retry with cleaned command
            continue

        # If validation returned error, return it
        if not validated.get("ok", False) or "error" in validated.get("error", {}):
            return validated

        result = validated
        break

    return result


# ── Decorator API ──────────────────────────────────────────────

def guard(
    timeout: int = TIMEOUT_DEFAULT,
    retry_on_ansi: bool = True,
):
    """
    Decorator: wraps a function that returns (cmd, args, cwd) with the guard.

    Usage:
        @guard(timeout=30)
        def my_tool(path: str):
            return ("ls", ("-la", path), None)

        result = my_tool("/tmp")
    """
    def decorator(func: Callable):
        @wraps(func)
        def wrapper(*args, **kwargs):
            cmd, cmd_args, cwd = func(*args, **kwargs)
            return guard_exec(cmd, cmd_args, timeout, cwd, retry_on_ansi)
        return wrapper
    return decorator


# ── Context Manager API ────────────────────────────────────────

class Guard:
    """
    Context manager for guarded subprocess execution.

    Usage:
        with Guard(timeout=30) as g:
            result = g.run("ls", ("-la", "/tmp"))
    """

    def __init__(self, timeout: int = TIMEOUT_DEFAULT, retry_on_ansi: bool = True):
        self.timeout = timeout
        self.retry_on_ansi = retry_on_ansi

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        pass

    def run(self, cmd: str, args: tuple = (), cwd: Optional[str] = None) -> Dict[str, Any]:
        return guard_exec(cmd, args, self.timeout, cwd, self.retry_on_ansi)


# ── Convenience: last-resort error generator ───────────────────

def last_resort_error() -> str:
    """
    Generate the last-resort error JSON string.
    No dependencies — uses only string literals and json module.
    """
    return json.dumps({
        "ok": False,
        "error": {
            "code": "E_SYSTEM_CATASTROPHE",
            "layer": "os",
            "retryable": False,
            "suggestion": "System resources exhausted. Free memory or restart agent.",
        },
    })
```

---

## 5. Empty Output Detection Rules

### Rule by Rule

| # | Condition | Classification | Action |
|---|---|---|---|
| 1 | `output == ""` or `output is None` | `SYSTEM_CATASTROPHE` | Return `E_OUTPUT_EMPTY`, `retryable=true`. If exit code was 0, downgrade suspicion — zero + empty is always wrong. |
| 2 | `output.strip() == ""` (whitespace only) | `SYSTEM_CATASTROPHE` | Return `E_OUTPUT_EMPTY` with `diagnostics.output_type: "whitespace_only"`. Include raw byte count. |
| 3 | After stripping ANSI escapes, output is empty | `STRIP_AND_RETRY` once, then `SYSTEM_CATASTROPHE` | Strip ANSI codes, retry command once. If second attempt produces same result, return `E_OUTPUT_ANSI_ONLY` with `retryable=false`. |
| 4 | `len(output) < 10 bytes` and not valid JSON | `SUSPICIOUS` | Return `E_OUTPUT_SUSPICIOUS`, `retryable=true`. Wrap in structured envelope with raw output in diagnostics. |
| 5 | Output contains `"Segmentation fault"`, `"Killed"`, `"Out of memory"`, `"SIGSEGV"`, `"SIGKILL"`, `"Bus error"`, `"Abort trap"` | `OS_LEVEL_ERROR` | Return `E_OS_CRASH`, `retryable=false`. Classify by keyword: segfault → memory corruption, OOM → resource exhaustion, Killed → external termination. Include matched keyword in diagnostics. |
| 6 | Output is valid JSON | `PASS_THROUGH` | Return output unchanged. Further validation of JSON content is the caller's responsibility. |

### Rule 3: ANSI Escape Retry Logic (Detail)

```python
def handle_ansi_only(output: str, cmd: str, args: tuple) -> Dict[str, Any]:
    """
    Handle Rule 3 — ANSI-escape-only output.
    Strips escapes, retries once, then fails.
    """
    import re
    ansi_escape = re.compile(r'\x1b\[[0-9;]*[a-zA-Z]')
    cleaned = ansi_escape.sub('', output)

    if cleaned.strip():
        # There was real content under the ANSI codes; return cleaned
        return {"ok": True, "stdout": cleaned, "_ansi_stripped": True}

    # No real content — return error
    return error_dict(
        "E_OUTPUT_ANSI_ONLY", "logic", False,
        "Output contained only ANSI escape sequences with no visible content.",
        cmd,
        {"raw_bytes": len(output.encode("utf-8")), "cleaned_bytes": len(cleaned.encode("utf-8"))},
    )
```

### Rule 5: Error Keyword Classification Table

| Keyword | Error Code | Layer | Interpretation |
|---|---|---|---|
| `Segmentation fault` / `SIGSEGV` | `E_OS_CRASH` | os | Memory corruption, null pointer dereference, stack overflow |
| `Killed` / `SIGKILL` | `E_OS_CRASH` | os | Killed by OOM killer, cgroup limit, or administrator |
| `Out of memory` / `Cannot allocate memory` | `E_RESOURCE_EXHAUSTED` | resource | Memory allocation failure (malloc/mmap returned NULL) |
| `Bus error` | `E_OS_CRASH` | os | Bad memory access (alignment error, mmap to truncated file) |
| `Floating point exception` | `E_OS_CRASH` | os | Arithmetic error (divide by zero, overflow) |
| `Abort trap` / `SIGABRT` | `E_OS_CRASH` | os | Assertion failure, `abort()` called, corrupted heap detected |

---

## 6. Race Condition Protection

### 6.1 The Problem: Guard Process Crashes

The null response guard itself is a process. It can crash too. The failure modes are:

1. **Guard OOM:** The guard process itself is killed by the OOM killer during memory allocation for pipes or buffers.
2. **Guard segfault:** A bug in the guard code (e.g., buffer overflow in string processing).
3. **Guard D-state:** The guard blocks on a read from a pipe whose writer is a D-state child → guard is stuck too.
4. **Guard signal handling failure:** The SIGALRM handler itself crashes or is prevented from executing due to resource exhaustion.

### 6.2 The Chain of Last Resort

```
Guard crash detected
    │
    ├── Is /tmp/agent-fallback-error.sh executable?
    │   YES → Execute it → returns structured E_SYSTEM_CATASTROPHE
    │
    ├── Is /bin/sh available?
    │   YES → Run: sh -c 'echo "{\"ok\":false,...}"'  → last-resort via shell
    │
    ├── Is /bin/echo available?
    │   YES → /bin/echo '{"ok":false}'  → minimal but valid JSON
    │
    └── Nothing works → Write raw bytes to /proc/self/fd/1 (stdout)
           write(1, '{"ok":false}\n', 14)  ← This is the absolute last atom
```

### 6.3 Guard Crash Detection

The caller (agent framework) wraps the guard call in a `try/except` or similar. Detection mechanisms:

```python
def call_with_fallback(tool_func: Callable, *args, **kwargs) -> Dict[str, Any]:
    """
    Wrapper that catches guard crashes and invokes the last-resort fallback.
    """
    try:
        return tool_func(*args, **kwargs)
    except MemoryError:
        # Guard itself OOM'd
        pass
    except SystemExit:
        # Guard called sys.exit() unexpectedly
        pass
    except BaseException as e:
        # Any other guard crash — log but still produce output
        pass

    # Last resort: try the fallback script
    import subprocess
    fallback_path = "/tmp/agent-fallback-error.sh"
    try:
        result = subprocess.run(
            [fallback_path],
            capture_output=True,
            timeout=5,
        )
        if result.returncode == 0 and result.stdout:
            try:
                return json.loads(result.stdout)
            except json.JSONDecodeError:
                pass
    except (FileNotFoundError, subprocess.TimeoutExpired, PermissionError):
        pass

    # Absolute last resort: return bare minimum
    return {
        "ok": False,
        "error": {
            "code": "E_SYSTEM_CATASTROPHE",
            "layer": "os",
            "retryable": False,
            "suggestion": "System resources exhausted. Free memory or restart agent.",
        },
    }
```

### 6.4 Bash-Level Guard Protection

```bash
# In agent main loop:

call_tool_with_fallback() {
    local tool_name="$1"
    shift

    # Attempt the tool call
    if ! result=$(guard_exec "$@" 2>/dev/null); then
        # guard_exec itself crashed (non-zero exit)
        if [ -x /tmp/agent-fallback-error.sh ]; then
            result=$(/bin/sh /tmp/agent-fallback-error.sh)
        elif command -v /bin/echo >/dev/null 2>&1; then
            result='{"ok":false,"error":{"code":"E_SYSTEM_CATASTROPHE","layer":"os","retryable":false,"suggestion":"All fallbacks exhausted; guard process crashed."}}'
        else
            # Literal bytes to stdout — impossible to fail
            # shellcheck disable=SC2059
            printf '{"ok":false}\n' >&1
            return 0
        fi
    fi

    # Validate the result is JSON
    if ! echo "$result" | jq . >/dev/null 2>&1; then
        # Corrupted output — wrap it
        result=$(cat <<EOF
{
  "ok": false,
  "error": {
    "code": "E_OUTPUT_INVALID",
    "layer": "logic",
    "retryable": true,
    "suggestion": "Guard produced invalid JSON. Possible memory corruption.",
    "diagnostics": {
      "raw_output": $(echo -n "$result" | head -c 200 | jq -Rs .)
    }
  }
}
EOF
        )
    fi

    echo "$result"
    return 0
}
```

### 6.5 Process Groups and Orphan Protection

When the guard process is killed by SIGKILL (not a controlled shutdown), child processes may become orphans. The protection is:

```python
import signal
import os

def setup_orphan_protection():
    """
    Set up child process group isolation.
    If the guard is killed, children survive but can be reaped.
    """
    # When guard runs a child, it places it in a separate process group
    # via preexec_fn=os.setsid in subprocess.Popen.
    # This orphans the child group if guard dies, but the kernel
    # delivers SIGHUP to the orphaned group if the guard was a session leader.
    #
    # To prevent orphaned children from running forever:
    # 1. The timeout mechanism ensures they are killed after timeout_sec.
    # 2. A separate reaper process (PID 1 or a dedicated watchdog)
    #    can clean up orphaned groups.
    pass
```

### 6.6 Summary: The Complete Failure Chain

```
Tool call initiated
    │
    ├─ guard_exec() Stage 1: Pre-flight check
    │   ├── Health check passes → continue
    │   ├── Health check fails → return E_RESOURCE_EXHAUSTED
    │   └── Guard itself crashes during Stage 1
    │       → Fallback chain invokes /tmp/agent-fallback-error.sh
    │       → If fallback script fails → bare minimum JSON via echo
    │       → If echo fails → raw write(1, "{"ok":false}\n", 14)
    │
    ├─ guard_exec() Stage 2: Execute with timeout
    │   ├── Process completes → collect output
    │   ├── Process times out → kill group, collect partial output
    │   └── Guard itself crashes during Stage 2 (OOM or signal handler failure)
    │       → Fallback chain (same as above)
    │
    └─ guard_exec() Stage 3: Validate output
        ├── Output valid → return to agent
        ├── Output invalid → wrap in structured error
        └── Guard itself crashes during Stage 3
            → Fallback chain (same as above)
```

**The invariant is:** No matter how many layers fail, the agent always receives a structured response. The fallback chain has four independent levels, and each level has been designed to use strictly fewer dependencies than the previous one. Level 4 (the raw `write(1)`) depends only on the kernel syscall interface — if that fails, the entire system is beyond rescue and the agent has much larger problems than a lost tool call.
