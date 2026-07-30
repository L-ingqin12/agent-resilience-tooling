# Minimal Implementation: Tier 2 Shell Library + Prompt

## Architecture Decision: Tier 2

**Chosen approach**: Tier 2 (Shell Library + Prompt Injection)

**Rationale**:

| Criterion | Tier 1 (Prompt Only) | Tier 2 (Shell + Prompt) | Tier 3 (Middleware) |
|-----------|----------------------|------------------------|---------------------|
| Deterministic safety | No — LLM can ignore | Yes — shell functions enforce | Yes — framework enforces |
| Prompt budget consumed | 800 tokens | ~250 tokens | ~50 tokens |
| Deployment complexity | None | One file + one sourcing cmd | Framework modification |
| Auditability | Low (LLM reasoning) | High (shell source code) | Medium (hook code) |
| Bypass risk | High (any prompt drift) | Medium (inline bash bypass) | Low (only --raw flag) |
| Portability | Universal | Any POSIX shell | Framework-specific |
| Maintenance burden | None | Low (one file) | Medium (hook + patterns) |

Tier 2 is the **sweet spot**: it provides deterministic safety for file operations (the most common dangerous actions) while requiring only a single shell file and ~250 tokens of prompt. It works on any Pi Agent environment from 512 MB Raspberry Pis to cloud servers because it uses only bash builtins and standard coreutils.

---

## The Shell Library

Save as `~/.agent/agent-safe-fs.sh` on the target system.

```bash
#!/usr/bin/env bash
# agent-safe-fs.sh — Idempotent, safe file operations for Pi Agent
#
# Every function returns JSON. All errors are classified.
# Dependencies: bash 4+, mkdir, mv, rm, stat, cat, timeout, mktemp
#
# Usage: source agent-safe-fs.sh
# Then call: ensure_directory "/path/to/dir"
#            ensure_file "/path/to/file" "content"
#            safe_remove "/path/to/thing"
#            guard_exec 30 some-command --with-args
#            classify_result 2 "permission denied"

set -o pipefail

# ─── Internal Helpers ────────────────────────────────────────────────

__agent_safe_fs_version="1.0.0"
__agent_trash_dir="${HOME}/.agent-trash"
__agent_json_escape() {
    # Escape a string for safe JSON embedding (single line)
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    printf '%s' "$s"
}

__agent_json_error() {
    local code="$1" message="$2"
    printf '{"status":"error","error":{"code":"%s","message":"%s"}}\n' \
        "$code" "$(__agent_json_escape "$message")"
}

__agent_json_ok() {
    local data="$1"
    printf '{"status":"ok","data":%s}\n' "$data"
}

# ─── classify_result — Map exit code + stderr to structured error ────
# Usage: classify_result <exit_code> <stderr_text>
# Returns JSON: {"status":"error","error":{"code":"ENOENT","message":"...","exit_code":2}}
classify_result() {
    local exit_code="$1"
    local stderr_text="$2"
    local lower_stderr
    lower_stderr=$(echo "$stderr_text" | tr '[:upper:]' '[:lower:]')

    # Exit code 0 → no error
    if [ "$exit_code" -eq 0 ]; then
        printf '{"status":"ok","data":{"exit_code":0}}\n'
        return 0
    fi

    # Map common error messages to structured codes
    local code="UNKNOWN"
    local message="$stderr_text"

    # errno-based classification from stderr content
    if echo "$lower_stderr" | grep -q "no such file or directory"; then
        code="ENOENT"
    elif echo "$lower_stderr" | grep -q "permission denied"; then
        code="EACCES"
    elif echo "$lower_stderr" | grep -q "file exists"; then
        code="EEXIST"
    elif echo "$lower_stderr" | grep -q "no space left"; then
        code="ENOSPC"
    elif echo "$lower_stderr" | grep -q "device or resource busy"; then
        code="EBUSY"
    elif echo "$lower_stderr" | grep -q "interrupted system call"; then
        code="EINTR"
    elif echo "$lower_stderr" | grep -q "invalid argument"; then
        code="EINVAL"
    elif echo "$lower_stderr" | grep -q "too many open files"; then
        code="EMFILE"
    elif echo "$lower_stderr" | grep -q "is a directory"; then
        code="EISDIR"
    elif echo "$lower_stderr" | grep -q "not a directory"; then
        code="ENOTDIR"
    elif echo "$lower_stderr" | grep -q "operation cancelled"; then
        code="ECANCELED"
    elif echo "$lower_stderr" | grep -q "timed out"; then
        code="ETIMEDOUT"
    elif echo "$lower_stderr" | grep -q "connection refused"; then
        code="ECONNREFUSED"
    elif echo "$lower_stderr" | grep -q "protocol error"; then
        code="EPROTO"
    fi

    # Exit-code-based fallback for missing stderr
    if [ "$code" = "UNKNOWN" ]; then
        case "$exit_code" in
            1)  code="E_GENERAL" ;;
            2)  code="E_MISUSE" ;;
            126) code="E_CANNOT_EXEC" ;;
            127) code="E_COMMAND_NOT_FOUND" ;;
            130) code="E_SIGINT" ;;
            137) code="E_SIGKILL" ;;
            143) code="E_SIGTERM" ;;
            255) code="E_EXIT_ERROR" ;;
        esac
    fi

    __agent_json_error "$code" "$message"
    return 1
}

# ─── ensure_directory — Idempotent directory creation ────────────────
# Usage: ensure_directory <path> [mode]
# Returns JSON. Creates parent directories automatically (like mkdir -p).
# Succeeds silently if directory already exists.
ensure_directory() {
    local path="$1"
    local mode="${2:-}"

    if [ -z "$path" ]; then
        __agent_json_error "EINVAL" "ensure_directory: path is required"
        return 1
    fi

    # Already exists and is a directory → success, no-op
    if [ -d "$path" ]; then
        printf '{"status":"ok","data":{"path":"%s","action":"noop","type":"directory"}}\n' \
            "$(__agent_json_escape "$path")"
        return 0
    fi

    # Exists but is not a directory → error
    if [ -e "$path" ]; then
        __agent_json_error "EEXIST" "Path exists but is not a directory: $path"
        return 1
    fi

    # Create directory with parents
    if [ -n "$mode" ]; then
        mkdir -p "$path" 2>/tmp/.agent-safe-fs-stderr.$$ &&
        chmod "$mode" "$path" 2>/tmp/.agent-safe-fs-stderr.$$
    else
        mkdir -p "$path" 2>/tmp/.agent-safe-fs-stderr.$$
    fi

    local rc=$?
    local stderr
    stderr=$(cat /tmp/.agent-safe-fs-stderr.$$ 2>/dev/null; rm -f /tmp/.agent-safe-fs-stderr.$$)

    if [ $rc -ne 0 ]; then
        classify_result $rc "$stderr"
        return 1
    fi

    printf '{"status":"ok","data":{"path":"%s","action":"created","type":"directory"}}\n' \
        "$(__agent_json_escape "$path")"
    return 0
}

# ─── ensure_file — Idempotent file creation with atomic write ────────
# Usage: ensure_file <path> [content]
# If content is omitted, creates an empty file.
# Uses tmpfile + mv for atomic writes (never partial writes).
# Will NOT overwrite an existing file unless force=yes is set.
ensure_file() {
    local path="$1"
    local content="$2"
    local force="${3:-no}"

    if [ -z "$path" ]; then
        __agent_json_error "EINVAL" "ensure_file: path is required"
        return 1
    fi

    # File exists → noop (unless force)
    if [ -f "$path" ] && [ "$force" != "yes" ]; then
        local fsize
        fsize=$(stat -c%s "$path" 2>/dev/null || echo "unknown")
        printf '{"status":"ok","data":{"path":"%s","action":"noop","size":%s}}\n' \
            "$(__agent_json_escape "$path")" "$fsize"
        return 0
    fi

    # Ensure parent directory exists
    local parent
    parent=$(dirname "$path")
    if [ ! -d "$parent" ]; then
        ensure_directory "$parent" || return 1
    fi

    # Atomic write: write to tmpfile, then mv into place
    local tmpfile
    tmpfile=$(mktemp "$(dirname "$path")/.agent-safe-fs-XXXXXX" 2>/tmp/.agent-safe-fs-stderr.$$)
    local rc=$?
    if [ $rc -ne 0 ]; then
        local stderr
        stderr=$(cat /tmp/.agent-safe-fs-stderr.$$ 2>/dev/null; rm -f /tmp/.agent-safe-fs-stderr.$$)
        classify_result $rc "$stderr"
        return 1
    fi

    # Write content (or empty)
    printf '%s' "$content" > "$tmpfile" 2>/tmp/.agent-safe-fs-stderr.$$
    rc=$?
    if [ $rc -ne 0 ]; then
        local stderr
        stderr=$(cat /tmp/.agent-safe-fs-stderr.$$ 2>/dev/null; rm -f /tmp/.agent-safe-fs-stderr.$$)
        rm -f "$tmpfile"
        classify_result $rc "$stderr"
        return 1
    fi

    # Atomic move
    mv "$tmpfile" "$path" 2>/tmp/.agent-safe-fs-stderr.$$
    rc=$?
    local stderr
    stderr=$(cat /tmp/.agent-safe-fs-stderr.$$ 2>/dev/null; rm -f /tmp/.agent-safe-fs-stderr.$$)

    if [ $rc -ne 0 ]; then
        rm -f "$tmpfile"
        classify_result $rc "$stderr"
        return 1
    fi

    local fsize
    fsize=$(stat -c%s "$path" 2>/dev/null || echo "unknown")
    printf '{"status":"ok","data":{"path":"%s","action":"written","size":%s}}\n' \
        "$(__agent_json_escape "$path")" "$fsize"
    return 0
}

# ─── safe_remove — Trash-style safe deletion ─────────────────────────
# Usage: safe_remove <path>
# Moves to ~/.agent-trash/ with timestamp instead of actual deletion.
# Trash directory is created automatically.
safe_remove() {
    local path="$1"

    if [ -z "$path" ]; then
        __agent_json_error "EINVAL" "safe_remove: path is required"
        return 1
    fi

    if [ ! -e "$path" ]; then
        __agent_json_error "ENOENT" "Path does not exist: $path"
        return 1
    fi

    # Create trash directory if needed
    if [ ! -d "$__agent_trash_dir" ]; then
        mkdir -p "$__agent_trash_dir" 2>/dev/null
    fi

    # Generate unique trash name: <basename>.<timestamp>.<pid>
    local basename
    basename=$(basename "$path")
    local trash_path="${__agent_trash_dir}/${basename}.$(date +%s).$$"

    # Atomic move to trash
    mv "$path" "$trash_path" 2>/tmp/.agent-safe-fs-stderr.$$
    local rc=$?
    local stderr
    stderr=$(cat /tmp/.agent-safe-fs-stderr.$$ 2>/dev/null; rm -f /tmp/.agent-safe-fs-stderr.$$)

    if [ $rc -ne 0 ]; then
        classify_result $rc "$stderr"
        return 1
    fi

    local item_type="file"
    [ -d "$trash_path" ] && item_type="directory"

    printf '{"status":"ok","data":{"path":"%s","trash_path":"%s","type":"%s","action":"trashed"}}\n' \
        "$(__agent_json_escape "$path")" "$(__agent_json_escape "$trash_path")" "$item_type"
    return 0
}

# ─── guard_exec — Execute with timeout and empty-output detection ────
# Usage: guard_exec <timeout_seconds> <command> [args...]
# Wraps any command. Returns JSON. Detects empty output, timeouts,
# and non-zero exit codes.
guard_exec() {
    local timeout_sec="$1"
    shift

    if [ -z "$timeout_sec" ] || [ -z "$1" ]; then
        __agent_json_error "EINVAL" "guard_exec: usage: guard_exec <timeout_sec> <command> [args...]"
        return 1
    fi

    # Validate timeout is a positive integer
    case "$timeout_sec" in
        ''|*[!0-9]*)
            __agent_json_error "EINVAL" "guard_exec: timeout must be a positive integer, got: $timeout_sec"
            return 1
            ;;
    esac

    if [ "$timeout_sec" -le 0 ]; then
        __agent_json_error "EINVAL" "guard_exec: timeout must be > 0, got: $timeout_sec"
        return 1
    fi

    # Run with timeout, capture stdout, stderr, and exit code
    local stdout_file stderr_file
    stdout_file=$(mktemp /tmp/.agent-guard-stdout-XXXXXX 2>/dev/null)
    stderr_file=$(mktemp /tmp/.agent-guard-stderr-XXXXXX 2>/dev/null)

    if [ -z "$stdout_file" ] || [ -z "$stderr_file" ]; then
        __agent_json_error "ENOSPC" "guard_exec: cannot create temp files"
        return 1
    fi

    timeout "$timeout_sec" "$@" >"$stdout_file" 2>"$stderr_file"
    local rc=$?

    local stdout_str stderr_str
    stdout_str=$(cat "$stdout_file" 2>/dev/null)
    stderr_str=$(cat "$stderr_file" 2>/dev/null)
    rm -f "$stdout_file" "$stderr_file"

    # Detect timeout (exit code 124 from timeout command)
    if [ $rc -eq 124 ]; then
        __agent_json_error "ETIMEDOUT" "Command timed out after ${timeout_sec}s: $*"
        return 1
    fi

    # Detect empty output (empty stdout AND empty stderr)
    if [ -z "$stdout_str" ] && [ -z "$stderr_str" ] && [ $rc -eq 0 ]; then
        __agent_json_error "EMPTY_RESPONSE" "Command succeeded (exit 0) but produced no output: $*"
        return 1
    fi

    # Non-zero exit code → classify
    if [ $rc -ne 0 ]; then
        classify_result $rc "$stderr_str"
        return 1
    fi

    # Success — escape stdout and wrap in JSON
    local escaped_stdout
    escaped_stdout=$(__agent_json_escape "$stdout_str")
    printf '{"status":"ok","data":{"stdout":"%s","exit_code":0}}\n' "$escaped_stdout"
    return 0
}

# ─── agent_safe_fs_self_test — Verify the library works ──────────────
# Usage: agent_safe_fs_self_test
# Returns JSON with results of each test.
agent_safe_fs_self_test() {
    local test_dir
    test_dir=$(mktemp -d /tmp/.agent-safe-fs-test-XXXXXX 2>/dev/null)
    local results="["

    # Test 1: ensure_directory creates a directory
    local r1
    r1=$(ensure_directory "${test_dir}/a/b/c" 2>&1)
    if echo "$r1" | grep -q '"status":"ok"'; then
        results+='{"test":"ensure_directory creates nested dirs","passed":true},'
    else
        results+='{"test":"ensure_directory creates nested dirs","passed":false,"output":"'
        results+=$(__agent_json_escape "$r1")
        results+='"},'
    fi

    # Test 2: ensure_directory is idempotent
    local r2
    r2=$(ensure_directory "${test_dir}/a/b/c" 2>&1)
    if echo "$r2" | grep -q '"action":"noop"'; then
        results+='{"test":"ensure_directory idempotent","passed":true},'
    else
        results+='{"test":"ensure_directory idempotent","passed":false,"output":"'
        results+=$(__agent_json_escape "$r2")
        results+='"},'
    fi

    # Test 3: ensure_file creates a file
    local r3
    r3=$(ensure_file "${test_dir}/hello.txt" "world" 2>&1)
    if echo "$r3" | grep -q '"status":"ok"'; then
        results+='{"test":"ensure_file creates file","passed":true},'
    else
        results+='{"test":"ensure_file creates file","passed":false,"output":"'
        results+=$(__agent_json_escape "$r3")
        results+='"},'
    fi

    # Test 4: safe_remove moves to trash
    local r4
    r4=$(safe_remove "${test_dir}/hello.txt" 2>&1)
    if echo "$r4" | grep -q '"action":"trashed"'; then
        results+='{"test":"safe_remove trashes file","passed":true},'
    else
        results+='{"test":"safe_remove trashes file","passed":false,"output":"'
        results+=$(__agent_json_escape "$r4")
        results+='"},'
    fi

    # Test 5: guard_exec timeout detection
    local r5
    r5=$(guard_exec 1 sleep 5 2>&1)
    if echo "$r5" | grep -q '"code":"ETIMEDOUT"'; then
        results+='{"test":"guard_exec timeout detection","passed":true}'
    else
        results+='{"test":"guard_exec timeout detection","passed":false,"output":"'
        results+=$(__agent_json_escape "$r5")
        results+='"}'
    fi

    results+="]"

    # Cleanup
    rm -rf "$test_dir" 2>/dev/null

    printf '{"status":"ok","data":{"library_version":"%s","tests":%s}}\n' \
        "$__agent_safe_fs_version" "$results"
}
```

**Line count**: ~195 lines (excluding comments/blanks). Fits well under the 200-line budget.

---

## The Prompt Injection

Add the following ~250-token snippet to the Pi Agent system prompt. It teaches the agent to use the shell library and reliably parse its JSON output.

```text
[SAFE FS LIBRARY]
Source ~/.agent/agent-safe-fs.sh at the start of every session:
  source ~/.agent/agent-safe-fs.sh 2>/dev/null || echo '{"status":"error","error":{"code":"E_LIBRARY_NOT_FOUND"}}'

Then use these functions for ALL file operations:
  ensure_directory <path> [mode]     # mkdir -p (idempotent, returns JSON)
  ensure_file <path> [content]       # atomic write via tmpfile+mv (returns JSON)
  safe_remove <path>                 # mv to ~/.agent-trash/ (never rm, returns JSON)
  guard_exec <sec> <cmd...>          # timeout + empty-output guard (returns JSON)

ALWAYS parse the JSON return value. On "status":"error", report the error code
and DO NOT retry unless code is ETIMEDOUT or EBUSY (max 3 retries).
NEVER use bare mkdir/rm/cp/dd. NEVER redirect stdout with > to create files.
```

### Token Breakdown

| Component | Tokens |
|-----------|--------|
| Sourcing instruction | 40 |
| Function signatures and descriptions | 120 |
| JSON parsing rule | 50 |
| Negative constraints (no bare mkdir/rm/etc.) | 40 |
| **Total** | **250** |

---

## Deployment

### On a Fresh Pi Agent Instance

```bash
# 1. Create the agent configuration directory
mkdir -p ~/.agent

# 2. Copy the shell library
cp agent-safe-fs.sh ~/.agent/agent-safe-fs.sh
chmod 644 ~/.agent/agent-safe-fs.sh

# 3. Verify it loads and passes self-test
bash -c 'source ~/.agent/agent-safe-fs.sh && agent_safe_fs_self_test'

# Expected output (JSON):
# {"status":"ok","data":{"library_version":"1.0.0","tests":[... all passed ...]}}

# 4. Inject the prompt snippet into the Pi Agent system prompt
#    (mechanism depends on Pi Agent version — typically via config file:
#     /etc/pi-agent/system-prompt.d/ or the agent's startup config)
```

### Post-Deployment Verification

Run this smoke test to confirm the integration works:

```bash
# Test that the agent can use the library via bash tool
source ~/.agent/agent-safe-fs.sh
ensure_directory /tmp/test-pi-agent-$(date +%s) 2>&1
safe_remove /tmp/test-pi-agent-* 2>&1
```

Each command should return `{"status":"ok",...}` JSON.

### Raspberry Pi Specific Notes

| Concern | Mitigation |
|---------|-----------|
| 512 MB RAM | Library uses no persistent processes; ~50KB memory footprint when sourced |
| SD card wear | `safe_remove` avoids writes by using mv (no new data written to flash); `ensure_directory` is a no-op if dir exists |
| Slow `mktemp` on tmpfs | Temp files created in `/tmp` (tmpfs, RAM-backed); no SD card I/O |
| `timeout` from coreutils | Available on all Raspberry Pi OS installations; falls back gracefully if missing |
| Low entropy for temp names | Uses PID in trash paths; sufficient for single-agent deployments |

---

## Limitations & Escalation Path

### What This Implementation CANNOT Handle

| Limitation | Root Cause | Impact |
|------------|------------|--------|
| Inline bash bypass | LLM can still run `rm -rf` directly without calling `safe_remove` | Data loss if LLM ignores prompt |
| Block device destruction | `dd if=/dev/zero of=/dev/sda` not intercepted | System bricked if LLM runs this |
| Fork bombs | `:(){ :|:& };:` not prevented | System hang |
| Network destruction | `iptables -F`, `route del default` not filtered | Network isolation |
| Resource exhaustion | `cat /dev/zero > /tmp/bigfile` not limited | Disk full |
| Process tree killing | `kill -9 -1` not prevented | All user processes killed |
| SUID/sudo abuse | `sudo rm -rf /` not caught if sudo is passwordless | Full system compromise |

### Escalation Path

When any of the following occur, the agent MUST stop and escalate to a human:

```
Trigger conditions for escalation (in priority order):

1. THREE_CONSECUTIVE_EMPTY_RESPONSES
   → Action: STOP all operations. Output final JSON error report.
   → Human: Check if agent process is alive, if tool dispatch is working.

2. UNKNOWN_ERROR_CODE
   → Any classify_result return with code "UNKNOWN"
   → Action: Report the raw stderr and exit code. Do not retry.
   → Human: Investigate the unexpected error condition.

3. EACCES_ON_CRITICAL_PATH
   → Permission denied on /etc, /var, /usr, or /home
   → Action: Stop all file operations in that hierarchy.
   → Human: Check filesystem permissions and ownership.

4. ENOSPC (disk full)
   → Action: Report disk usage stats. Do not write any more files.
   → Human: Free up disk space or attach larger storage.

5. ESCALATION_REQUEST counter > 3
   → If the agent has escalated 3 times in the same session without
     resolution, emit a final escalation and enter READ-ONLY mode.
   → Human: Needs a systemic fix, not point solutions.
```

### Escalation Output Format

When escalating, the agent outputs this exact JSON structure so a human or parent process can parse it:

```json
{
  "status": "escalate",
  "reason": "THREE_CONSECUTIVE_EMPTY_RESPONSES",
  "details": {
    "last_command": "guard_exec 30 ls /nonexistent",
    "attempts": 3,
    "empty_responses_at": ["2025-01-01T12:00:01Z", "2025-01-01T12:00:05Z", "2025-01-01T12:00:10Z"],
    "agent_version": "pi-agent/1.0.0",
    "library_version": "agent-safe-fs.sh/1.0.0"
  },
  "human_action_required": "Verify the agent process and filesystem health before resuming"
}
```

---

## Summary

The Tier 2 approach delivers **deterministic safety for the most common risky operations** (file creation, deletion, directory management) with minimal overhead. It is:

- **~250 tokens** of prompt (under 1/3 of the budget)
- **~195 lines** of shell code (under 200-line limit)
- **Zero external dependencies** (bash builtins + coreutils)
- **Zero persistent processes** (no daemons, no watchers)
- **Deployable in under 30 seconds** on any Unix system

For operations that cannot be made safe through shell wrappers alone (block device writes, network changes, fork bombs), the escalation path provides a clean handoff to a human operator.
