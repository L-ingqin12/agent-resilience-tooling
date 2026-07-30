# Extreme Condition Fallback — 极端系统条件下的兜底反馈

> Part of Layer 4 (Graceful Degradation) of the Agent Resilience Tooling model.
> See `../03-error-classification/error-classification-system.md` for the error code taxonomy that underpins the structured contract defined here.

---

## 1. The Null Response Problem

**Empty tool returns are the #1 cause of agent confusion and retry loops.**

When a tool returns nothing — empty string, whitespace-only, or a bare `null` — the agent has no signal to distinguish "everything is fine but there is no output" from "the system is silently failing." The agent's default response to ambiguity is to retry, which in a degraded system exacerbates resource exhaustion and deepens the death spiral.

### Three Failure Modes

Every null response falls into exactly one of three root causes. Distinguishing them is essential for correct recovery.

#### Failure Mode A: Process Never Started

The fork(2)/execve(2) call itself failed. The child process was never created.

**Root causes:**

| Cause | Detection | Typical exit code |
|---|---|---|
| `fork()` returns -1 (RLIMIT_NPROC exceeded) | `errno == EAGAIN` | N/A (no PID) |
| OOM killer fires during fork memory accounting | kernel log: `oom_kill_process` | N/A (no PID) |
| ulimit violation (RLIMIT_DATA, RLIMIT_STACK) | shell reports "cannot fork" | 127 (bash) |
| cgroup memory limit exceeded | cgroup eventfd notification | N/A (cgroup kill) |
| `/tmp` or `/dev/null` no longer writable | open(2) fails with EACCES/ENOSPC | 126 (bash) |

**Agent-visible signature:** The tool returns instantly with no output. Wall-clock elapsed time is sub-millisecond because the OS never dispatched the process. No PID file or lock is created.

**Recovery strategy:** Do NOT retry. The condition is systemic (resource exhaustion, filesystem failure). Retrying will make it worse. Return structured error with `retryable: false`.

#### Failure Mode B: Process Started but Hung

The process was successfully forked and entered user space, but then stopped making progress. It is stuck in an uninterruptible sleep (D-state) or a livelocked busy loop.

**Root causes:**

| Cause | Detection | Resolution |
|---|---|---|
| D-state I/O block on dead NFS/SMB mount | `/proc/*/status` shows `State: D (disk sleep)` | Only fixable by NFS server recovery or hard reboot |
| FUSE filesystem hang (sshfs, s3fs) | D-state on fuse kernel thread; fuseblk mount | `fusermount -u` or lazy umount |
| Deadlock on kernel mutex | D-state on `btrfs-transaction` or `xfsaild` tasks | Kernel hung task panic after `hung_task_timeout_secs` |
| Stuck POSIX lock (flock/fcntl) | Process in S-state, no CPU usage, strace shows `flock(F_SETLKW)` | Kill process holding the lock |
| Busy-loop with no progress | 100% CPU, no I/O, same syscall repeated | Timeout detection |

**Agent-visible signature:** The tool call blocks indefinitely or until the watchdog timeout fires. Partial output may exist if the process made progress before hanging. The process appears in `ps` and `/proc`.

**Recovery strategy:** Kill the process group (SIGKILL), collect any partial output from stdout/stderr, return structured timeout error with diagnostics about the stuck process. `retryable: false` because the underlying resource (NFS mount, kernel state) is unlikely to self-recover.

#### Failure Mode C: Process Started but Output Lost

The process ran to completion (exit code 0 or non-zero) but its stdout/stderr was captured as empty — the output was produced but never reached the caller.

**Root causes:**

| Cause | Mechanism |
|---|---|
| stdout buffer not flushed before crash | Process used stdio buffering (glibc default: 4 KB), wrote partial output, then segfaulted. `fflush(NULL)` never ran. |
| stderr/file descriptor confusion | Process wrote diagnostics to stderr but caller only captured stdout (or vice versa) |
| PIPE buffer overflow with SIGPIPE | Reader closed pipe; writer got SIGPIPE and exited without flush |
| Container/OOM kill during flush | Process was mid-flush when cgroup OOM killer terminated it |
| TTY vs pipe output format difference | Program detects non-TTY and suppresses progress output, producing silence |
| Exit handler (atexit/on_exit) skipped | `_exit()` called instead of `exit()`, or SIGKILL bypasses all cleanup handlers |

**Agent-visible signature:** The tool returns quickly (wall time matches expected execution). Exit code may be 0 (confusingly). Empty or truncated output. No diagnostic data on stderr.

**Recovery strategy:** This is the most dangerous failure mode because a zero exit code combined with empty output causes the agent to treat the result as success, proceeding with downstream logic that will fail. Always validate output size even for exit code 0. If output is empty and exit code is 0, downgrade to `retryable: true` with a suspicion score.

---

## 2. Pre-Fork Health Check

Before spawning **any** child process — whether it is a tool call, a subagent, or a shell command — perform the following checks. The goal is to detect conditions that guarantee fork failure or process hang so we can fail fast with a structured error instead of attempting the fork.

### 2.1 Available Memory Check

```
Threshold:  MEMORY_MINIMUM_MB = 64 MB
Source:     /proc/meminfo → MemAvailable
```

```bash
check_memory() {
    local min_mb="${1:-64}"
    local mem_available_kb
    mem_available_kb=$(grep -E '^MemAvailable:' /proc/meminfo | awk '{print $2}')
    if [[ -z "$mem_available_kb" ]]; then
        # Fallback: calculate from MemFree + Cached - Mapped
        local mem_free_kb cached_kb mapped_kb
        mem_free_kb=$(grep -E '^MemFree:' /proc/meminfo | awk '{print $2}')
        cached_kb=$(grep -E '^Cached:' /proc/meminfo | awk '{print $2}')
        mapped_kb=$(grep -E '^Mapped:' /proc/meminfo | awk '{print $2}')
        mem_available_kb=$(( mem_free_kb + cached_kb - mapped_kb ))
    fi
    local mem_available_mb=$(( mem_available_kb / 1024 ))
    if (( mem_available_mb < min_mb )); then
        echo "FAIL: mem_available=${mem_available_mb}MB < ${min_mb}MB"
        return 1
    fi
    echo "OK: mem_available=${mem_available_mb}MB"
    return 0
}
```

**Rationale for 64 MB threshold:** A typical `fork()` requires enough memory to copy page tables for the parent process. Even with overcommit (vm.overcommit_memory=1), kernel memory for page table structures must be physically available. 64 MB ensures a minimal shell process (bash, or a small tool) can fork.

### 2.2 Process Count Check

```
Threshold:  SAFE_PROC_PCT = 80% of RLIMIT_NPROC
Source:     /proc/loadavg (4th field = running/total threads)
            ulimit -u (user process limit)
```

```bash
check_proc_count() {
    local limit
    limit=$(ulimit -u 2>/dev/null || echo 1024)
    local total_procs
    total_procs=$(($(awk '{print $4}' /proc/loadavg | cut -d'/' -f2)))
    local threshold=$(( limit * 80 / 100 ))
    if (( total_procs >= threshold )); then
        echo "FAIL: procs=${total_procs} >= threshold=${threshold} (limit=${limit})"
        return 1
    fi
    echo "OK: procs=${total_procs}, threshold=${threshold}"
    return 0
}
```

### 2.3 D-State Process Count Check

D-state (uninterruptible sleep) processes indicate I/O congestion or dead NFS mounts. A high count means new processes are likely to block too.

```
Threshold:  D_STATE_MAX = 5
Source:     grep -l '^State.*D' /proc/[0-9]*/status
```

```bash
check_d_state() {
    local max_d="${1:-5}"
    local d_count
    d_count=$(grep -l '^State.*D' /proc/[0-9]*/status 2>/dev/null | wc -l)
    if (( d_count > max_d )); then
        echo "FAIL: d_state_procs=${d_count} > ${max_d}"
        return 1
    fi
    echo "OK: d_state_procs=${d_count}"
    return 0
}
```

### 2.4 Composite Health Check

```bash
pre_fork_health_check() {
    local failures=()
    local mem_result proc_result d_result

    mem_result=$(check_memory "${MEMORY_MINIMUM_MB:-64}")
    if [[ "$mem_result" = FAIL:* ]]; then
        failures+=("$mem_result")
    fi

    proc_result=$(check_proc_count)
    if [[ "$proc_result" = FAIL:* ]]; then
        failures+=("$proc_result")
    fi

    d_result=$(check_d_state "${D_STATE_MAX:-5}")
    if [[ "$d_result" = FAIL:* ]]; then
        failures+=("$d_result")
    fi

    if (( ${#failures[@]} > 0 )); then
        # Return structured error — do NOT attempt fork
        cat <<EOF
{
  "ok": false,
  "path": "N/A",
  "error": {
    "code": "E_RESOURCE_EXHAUSTED",
    "layer": "resource",
    "retryable": false,
    "suggestion": "System resources below fork threshold. Free memory or restart agent.",
    "diagnostics": {
      "failures": [$(printf '"%s",' "${failures[@]}" | sed 's/,$//')]
    }
  }
}
EOF
        return 1
    fi
    return 0
}
```

---

## 3. Timeout + Watchdog Architecture

Every tool call must be wrapped with a timeout. The timeout serves two purposes: (a) prevent the agent from blocking forever on a hung process, and (b) collect partial output before killing the child so we return something useful.

### 3.1 Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                     Agent Process                       │
│  ┌──────────────────────────────────────────────────┐   │
│  │          guard_exec (timeout wrapper)             │   │
│  │                                                   │   │
│  │  1. Set SIGALRM handler (default 30s)             │   │
│  │  2. fork()                                        │   │
│  │  3. Child sets its own process group              │   │
│  │  4. Child exec() target command                   │   │
│  │  5. Parent waitpid() with alarm active            │   │
│  │                                                   │   │
│  │  ┌─ ALARM fires ──┐                               │   │
│  │  │ • kill(-pgid, SIGKILL)                         │   │
│  │  │ • Collect partial stdout/stderr                │   │
│  │  │ • Return E_TIMEOUT error                       │   │
│  │  └────────────────┘                               │   │
│  └──────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

### 3.2 Implementation: Bash (timeout via `timeout(1)`)

```bash
# Wrapper around timeout(1) with partial-output collection
exec_with_timeout() {
    local timeout_sec="${1:-30}"
    shift
    local tmp_stdout
    local tmp_stderr
    tmp_stdout=$(mktemp /tmp/agent_stdout.XXXXXX)
    tmp_stderr=$(mktemp /tmp/agent_stderr.XXXXXX)
    local start_time end_time elapsed

    start_time=$(date +%s%N)

    # Run command under timeout; capture both streams
    timeout --kill-after=5 --signal=TERM "$timeout_sec" "$@" \
        >"$tmp_stdout" 2>"$tmp_stderr"
    local exit_code=$?

    end_time=$(date +%s%N)
    elapsed=$(( (end_time - start_time) / 1000000 ))  # ms

    local stdout_text stderr_text
    stdout_text=$(cat "$tmp_stdout" 2>/dev/null || true)
    stderr_text=$(cat "$tmp_stderr" 2>/dev/null || true)
    rm -f "$tmp_stdout" "$tmp_stderr" 2>/dev/null || true

    # Classify the result
    case $exit_code in
        124|137)  # timeout(1) exit for SIGTERM / SIGKILL
            # Timeout: process was killed
            if [[ -z "$stdout_text" && -z "$stderr_text" ]]; then
                # Case: No output at all → process was hung (Failure Mode B)
                cat <<EOF
{
  "ok": false,
  "path": "$1",
  "error": {
    "code": "E_TIMEOUT_HUNG",
    "layer": "os",
    "retryable": false,
    "suggestion": "Process hung with no output. Check for D-state processes or dead mounts.",
    "diagnostics": {
      "elapsed_ms": $elapsed,
      "timeout_sec": $timeout_sec,
      "exit_code": $exit_code,
      "partial_output": false
    }
  }
}
EOF
            else
                # Case: Partial output exists → process was slow (Failure Mode C variant)
                cat <<EOF
{
  "ok": false,
  "path": "$1",
  "error": {
    "code": "E_TIMEOUT_PARTIAL",
    "layer": "os",
    "retryable": true,
    "suggestion": "Process timed out but produced partial output. Consider increasing timeout or simplifying request.",
    "diagnostics": {
      "elapsed_ms": $elapsed,
      "timeout_sec": $timeout_sec,
      "exit_code": $exit_code,
      "partial_output": true,
      "stdout_bytes": $(echo -n "$stdout_text" | wc -c),
      "stderr_bytes": $(echo -n "$stderr_text" | wc -c)
    }
  },
  "stdout": $(echo -n "$stdout_text" | jq -Rs .),
  "stderr": $(echo -n "$stderr_text" | jq -Rs .)
}
EOF
            fi
            ;;
        *)
            # Normal exit (0 or non-zero)
            cat <<EOF
{
  "ok": $([ "$exit_code" -eq 0 ] && echo true || echo false),
  "path": "$1",
  "exit_code": $exit_code,
  "stdout": $(echo -n "$stdout_text" | jq -Rs .),
  "stderr": $(echo -n "$stderr_text" | jq -Rs .),
  "diagnostics": {
    "elapsed_ms": $elapsed
  }
}
EOF
            ;;
    esac
}
```

### 3.3 Distinguishing "No Output" from "Partial Output"

This is the critical distinction that drives correct recovery.

| Heuristic | "No Output" (Hung) | "Partial Output" (Slow) |
|---|---|---|
| stdout/stderr empty after kill | Yes | No |
| Process D-state on /proc check | Likely | Unlikely |
| Wall time / timeout ratio | ~1.0 (hit deadline exactly) | < 1.0 (output was being produced) |
| Exit code from SIGKILL (137) | Yes | Yes |
| CPU usage before kill | 0% (blocked on I/O) | > 0% (was computing) |
| Recovery | Do NOT retry | Consider retry with more resources |

### 3.4 SIGALRM Handler (Low-Level C/Python)

For languages where direct signal handling is possible, use SIGALRM to implement the watchdog rather than depending on `timeout(1)`:

```
Signal:  SIGALRM (14)
Handler: watchdog_handler()
Action:  1. kill(-child_pgid, SIGKILL)
         2. read(pipe_stdout) → partial buffer
         3. read(pipe_stderr) → partial buffer
         4. longjmp() or raise exception
```

---

## 4. The Last-Resort Error Generator

When **all** other mechanisms have failed — the health check crashed, the timeout wrapper itself segfaulted, memory is measured in kilobytes, and even `printf` might not work — this script is the final line of defense.

### 4.1 Design Constraints

- **Zero dependencies** beyond what a POSIX shell guarantees.
- **Must work after catastrophic resource exhaustion.**
- **Must never itself fork or allocate memory.**
- **Must be a pre-allocated, pre-interpreted script** loaded at agent startup.

### 4.2 The Script: `/tmp/agent-fallback-error.sh`

```bash
#!/bin/sh
# agent-fallback-error.sh — Last-resort error generator
# Pre-loaded at agent startup. Never modified at runtime.
# Only uses /bin/echo (shell builtin, never fails).
# No fork, no exec, no allocation beyond echo's internal buffer.

# Use shell built-in echo; /bin/echo only if built-in not available
ECHO="echo"
if ! command -v $ECHO >/dev/null 2>&1; then
    # Fallback: write directly to /dev/tty or /proc/self/fd/1
    # If even echo is gone, we are beyond help — write raw bytes
    :
fi

# Return the canonical catastrophic error JSON
# This string is hardcoded — no string concatenation, no variable interpolation
cat <<'EOF_ERROR'
{
  "ok": false,
  "error": {
    "code": "E_SYSTEM_CATASTROPHE",
    "layer": "os",
    "retryable": false,
    "suggestion": "System resources exhausted. Free memory or restart agent."
  }
}
EOF_ERROR
```

### 4.3 Pre-Load Protocol

At agent startup, this script is validated and pre-loaded into the shell's `source` cache:

```bash
# In agent init script:
AGENT_FALLBACK_ERROR="/tmp/agent-fallback-error.sh"

# Verify the file exists and is valid
if [ -f "$AGENT_FALLBACK_ERROR" ]; then
    # Syntax-check by sourcing (dry run)
    if ! sh -n "$AGENT_FALLBACK_ERROR" 2>/dev/null; then
        echo "FATAL: Fallback error script is corrupt. Cannot continue."
        exit 1
    fi
    # Verify it produces valid JSON
    if ! sh "$AGENT_FALLBACK_ERROR" | grep -q '"E_SYSTEM_CATASTROPHE"'; then
        echo "FATAL: Fallback error script does not produce expected output."
        exit 1
    fi
    # Source it into the current shell for quick access
    . "$AGENT_FALLBACK_ERROR"
else
    echo "FATAL: Fallback error script not found at $AGENT_FALLBACK_ERROR"
    exit 1
fi
```

### 4.4 Invocation Chain

```
Normal tool call → guard_exec() → health check passes → fork + exec → success

Normal tool call → guard_exec() → health check fails → structured error → done

Normal tool call → guard_exec() → health check passes → fork + exec → timeout → E_TIMEOUT

Normal tool call → guard_exec() → guard itself crashes (OOM, segfault)
    → caller catches guard failure
    → attempts /tmp/agent-fallback-error.sh ← THIS IS THE LAST RESORT
    → if that fails too → bare minimum: write "{\"ok\":false}" to stderr

Normal tool call → guard_exec() → guard passes → fork + exec → exec fails → E_EXEC_FAILURE
```

### 4.5 Script Invariant

The last-resort script must NEVER be modified at runtime. It is created once at agent installation and only replaced during upgrade. This prevents a corrupted agent from overwriting its own lifeline.

```bash
# Immutable file permissions:
chmod 444 /tmp/agent-fallback-error.sh     # read-only for all
chattr +i /tmp/agent-fallback-error.sh      # immutable (Linux ext4/xfs/btrfs)
```

---

## 5. Structured Error Contract

**Every tool, no matter what, must return JSON that conforms to this contract.** There is no exception. If the tool cannot produce JSON, the fallback system produces it instead.

### 5.1 Schema

```json
{
  "ok": false,
  "path": "/requested/path",
  "error": {
    "code": "ERROR_CODE",
    "layer": "os|fs|permission|resource|logic",
    "retryable": true|false,
    "suggestion": "Human-readable next step",
    "diagnostics": {
      "mem_available_mb": 128,
      "load_avg": 4.2,
      "d_state_procs": 3,
      "exit_code": 137
    }
  }
}
```

### 5.2 Error Code Reference

| Code | Layer | Meaning | Retryable |
|---|---|---|---|
| `E_SYSTEM_CATASTROPHE` | os | Complete system failure (OOM, kernel panic) | false |
| `E_RESOURCE_EXHAUSTED` | resource | Memory or process limit reached | false |
| `E_TIMEOUT_HUNG` | os | Process produced zero output before timeout | false |
| `E_TIMEOUT_PARTIAL` | os | Process produced partial output before timeout | true |
| `E_FORK_FAILED` | os | fork(2) returned error | false |
| `E_EXEC_FAILURE` | os | execve(2) failed (binary not found, no permission) | true (if path corrected) |
| `E_OUTPUT_EMPTY` | logic | Process completed but produced no output | true |
| `E_OUTPUT_INVALID` | logic | Output is not valid JSON or is corrupted | true |
| `E_PERMISSION_DENIED` | permission | Insufficient OS permissions | false |
| `E_PATH_NOT_FOUND` | fs | Requested path does not exist | true (after path correction) |
| `E_FS_FULL` | fs | Disk full (ENOSPC) | false |
| `E_FS_IO` | fs | I/O error on filesystem | false |
| `E_FS_READONLY` | fs | Filesystem mounted read-only | false |
| `E_NFS_HANG` | fs | NFS mount is unresponsive | false |

### 5.3 Layer Definitions

| Layer | Scope | Characteristic |
|---|---|---|
| `os` | Kernel, signals, process lifecycle | Retry rarely helps; system state must change |
| `fs` | Filesystem, storage, mount points | May be transient (remount) or permanent (disk failure) |
| `permission` | Capabilities, ownership, DAC/MAC | Retry never helps; fix requires reconfiguration |
| `resource` | Memory, CPU, file descriptors, process table | Retry may help if other tasks release resources |
| `logic` | Tool internal logic, parameter validation, output parsing | Retry often helps if inputs are corrected |

### 5.4 Zero-Loss Guarantee

The structured error contract is not a "best effort" — it is a guarantee. Every code path in the tool system must end in one of:

1. **Happy path:** `{"ok":true, ...data...}`
2. **Structured error:** `{"ok":false, "error":{...}}`
3. **Fallback script:** The last-resort error generator
4. **Desperate fallback:** If everything above fails, write the bare string `{"ok":false}` to stderr

There is no path 5. The agent must never receive a null response, an empty string, or a process crash without structured output.

### 5.5 Validation Rule

Every path returning from `guard_exec` must pass this assertion:

```bash
validate_structured_output() {
    local json="$1"
    local required_fields="ok path error.code error.layer error.retryable error.suggestion"
    for field in $required_fields; do
        if ! echo "$json" | jq -e ". | has(\"$field\")" >/dev/null 2>&1; then
            echo "FAIL: Missing required field '$field' in: $json"
            return 1
        fi
    done
    return 0
}
```
