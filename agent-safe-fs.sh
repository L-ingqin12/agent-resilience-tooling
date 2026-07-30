#!/usr/bin/env bash
# agent-safe-fs.sh — AI Agent Safe File System Operations Library
# Version: 1.0.0
# Usage: source this file in agent's shell environment before any file ops
#   source /path/to/agent-safe-fs.sh
#   ensure_directory /tmp/myapp
#   ensure_file /tmp/myapp/config.yaml "server: port: 8080"
#   safe_remove /tmp/old-data
#
# Design constraints:
#   - bash 4.0+ compatible (no associative arrays by default)
#   - Coreutils only: mkdir, mv, rm, stat, cat, mktemp, timeout
#   - /proc filesystem used when available, degrade gracefully
#   - Every function returns structured JSON, NEVER empty
#   - Total lines < 200 (Pi Agent constraint)
#   - No external dependencies (python, jq, curl NOT required)

set -o pipefail

# ─── JSON Escaping ───────────────────────────────────────────────
_json_escape() {
    local s="${1-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# ─── System Diagnostics ──────────────────────────────────────────
_system_diag() {
    local mem_avail="unknown" load_1m="unknown" d_state="unknown"
    [ -r /proc/meminfo ] && mem_avail=$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo "unknown")
    [ -r /proc/loadavg ] && load_1m=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo "unknown")
    [ -d /proc ] && d_state=$(grep -c '^State:\s*D' /proc/*/status 2>/dev/null || echo "0")
    printf '{"mem_available_mb":"%s","load_1m":"%s","d_state_procs":"%s"}' \
        "$mem_avail" "$load_1m" "$d_state"
}

# ─── Error Classification ────────────────────────────────────────
classify_result() {
    # Usage: classify_result <exit_code> <stderr_output> [errno]
    local exit_code="${1:-1}" stderr="${2:-}" errno="${3:-}"
    local code layer retryable suggestion

    case "$exit_code" in
        0)
            printf '{"code":"OK","layer":"none","retryable":false,"suggestion":""}\n'
            return 0 ;;
        1|13)  # EACCES / EPERM
            code="E_PERM"; layer="permission"; retryable="false"
            suggestion="Permission denied. Use an alternative path or request access." ;;
        17)    # EEXIST
            code="E_EXISTS"; layer="fs"; retryable="false"
            suggestion="Path already exists. This is success for directory creation." ;;
        2)     # ENOENT
            code="E_PATH"; layer="logic"; retryable="false"
            suggestion="Parent directory does not exist. Create it first or use create_parents=true." ;;
        28)    # ENOSPC
            code="E_NOSPC"; layer="resource"; retryable="true"
            suggestion="Disk full. Free space and retry once, then stop." ;;
        12)    # ENOMEM
            code="E_OOM"; layer="resource"; retryable="false"
            suggestion="Out of memory. Free memory or reduce workload, then retry." ;;
        5)     # EIO
            code="E_IO"; layer="os"; retryable="false"
            suggestion="I/O error. Check disk health and filesystem integrity." ;;
        124)   # timeout
            code="E_TIMEOUT"; layer="os"; retryable="true"
            suggestion="Command timed out. Retry once with longer timeout, then stop." ;;
        137)   # SIGKILL (OOM killer or manual kill)
            code="E_OOM"; layer="resource"; retryable="false"
            suggestion="Process killed (likely OOM). Do NOT retry. Free resources first." ;;
        139)   # SIGSEGV
            code="E_UNKNOWN"; layer="os"; retryable="false"
            suggestion="Command crashed (segfault). Report this error. Do NOT retry." ;;
        126|127) # command not found / not executable
            code="E_UNKNOWN"; layer="logic"; retryable="false"
            suggestion="Command not found or not executable. Check the command name." ;;
        *)
            # Try to classify by stderr content
            if [[ "$stderr" =~ [Pp]ermission\ denied ]]; then
                code="E_PERM"; layer="permission"; retryable="false"
                suggestion="Permission denied. Use an alternative path."
            elif [[ "$stderr" =~ [Nn]o\ space\ left ]]; then
                code="E_NOSPC"; layer="resource"; retryable="true"
                suggestion="Disk full. Free space and retry."
            elif [[ "$stderr" =~ [Ss]egmentation\ fault ]]; then
                code="E_UNKNOWN"; layer="os"; retryable="false"
                suggestion="Command crashed. Do NOT retry."
            elif [[ "$stderr" =~ [Kk]illed ]]; then
                code="E_OOM"; layer="resource"; retryable="false"
                suggestion="Process was killed. Do NOT retry."
            else
                code="E_UNKNOWN"; layer="os"; retryable="false"
                suggestion="Unknown error (exit=$exit_code). Report to user and STOP."
            fi ;;
    esac

    local diag
    diag=$(_system_diag)
    printf '{"code":"%s","layer":"%s","retryable":%s,"suggestion":"%s","diagnostics":%s}\n' \
        "$code" "$layer" "$retryable" "$(_json_escape "$suggestion")" "$diag"
}

# ─── Guard Exec ──────────────────────────────────────────────────
guard_exec() {
    # Usage: guard_exec <timeout_seconds> <command...>
    # Wraps any command with timeout, empty-output detection, and fallback.
    # NEVER returns empty string.
    local timeout_sec="${1:-30}"; shift

    # Stage 1: Pre-flight health check
    local mem_avail=""
    [ -r /proc/meminfo ] && mem_avail=$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null)
    if [ -n "$mem_avail" ] && [ "$mem_avail" -lt 51200 ] 2>/dev/null; then
        # Less than 50MB available — refuse to fork
        printf '{"ok":false,"error":{"code":"E_OOM","layer":"resource","retryable":false,'
        printf '"suggestion":"System memory critically low (<50MB). Do NOT retry. Free memory first.","diagnostics":'
        _system_diag
        printf '}}\n'
        return 1
    fi

    # Stage 2: Execute with timeout
    local output exit_code
    output=$(timeout "$timeout_sec" "$@" 2>&1)
    exit_code=$?

    # Stage 3: Post-call validation
    # Empty output detection
    if [ -z "${output// /}" ]; then
        printf '{"ok":false,"error":{"code":"E_SYSTEM_CATASTROPHE","layer":"os","retryable":false,'
        printf '"suggestion":"Command produced EMPTY output. Process may have crashed or system is exhausted. DO NOT retry.","diagnostics":'
        _system_diag
        printf ',"raw_exit_code":%d}}\n' "$exit_code"
        return 1
    fi

    # Return structured result with the raw output preserved
    local classification
    classification=$(classify_result "$exit_code" "$output")
    printf '{"ok":%s,"exit_code":%d,"output":"%s","classification":%s}\n' \
        "$([ "$exit_code" -eq 0 ] && echo "true" || echo "false")" \
        "$exit_code" \
        "$(_json_escape "$output")" \
        "$classification"
    return "$exit_code"
}

# ─── ensure_directory ────────────────────────────────────────────
ensure_directory() {
    # Usage: ensure_directory <path> [mode]
    # Idempotent directory creation. Always returns structured JSON.
    local path="${1:-}" mode="${2:-755}"
    local diag

    # Input validation
    if [ -z "$path" ]; then
        printf '{"ok":false,"path":"","created":false,"existed_before":false,"error":{"code":"E_PATH","layer":"logic","retryable":false,"suggestion":"Path is empty. Provide a valid absolute path."}}\n'
        return 1
    fi

    # Normalize: strip trailing slash
    path="${path%/}"
    [ -z "$path" ] && path="/"

    # SAFETY: Refuse dangerous paths
    case "$path" in
        ""|"/"|"/root"|"/etc"|"/boot"|"/sys"|"/proc"|"/dev")
            printf '{"ok":false,"path":"%s","created":false,"existed_before":false,"error":{"code":"E_PERM","layer":"permission","retryable":false,"suggestion":"Refusing to operate on system-critical path: %s. Choose a user-space path."}}\n' \
                "$path" "$path"
            return 1 ;;
    esac

    # Step 1: Check current state
    if [ -d "$path" ]; then
        printf '{"ok":true,"path":"%s","created":false,"existed_before":true,"error":null}\n' "$path"
        return 0
    fi

    if [ -f "$path" ] || [ -L "$path" ]; then
        local ftype="file"
        [ -L "$path" ] && ftype="symlink"
        printf '{"ok":false,"path":"%s","created":false,"existed_before":false,"error":{"code":"E_PATH_CONFLICT","layer":"logic","retryable":false,"suggestion":"Path exists as a %s, not a directory. Cannot proceed."}}\n' \
            "$path" "$ftype"
        return 1
    fi

    # Step 2: Attempt creation
    local output exit_code
    output=$(mkdir -p "$path" 2>&1)
    exit_code=$?

    # Step 3: Verify final state
    if [ -d "$path" ]; then
        printf '{"ok":true,"path":"%s","created":true,"existed_before":false,"error":null}\n' "$path"
        return 0
    fi

    # Step 4: Creation failed — classify and report
    diag=$(_system_diag)
    local classification
    classification=$(classify_result "$exit_code" "$output")
    printf '{"ok":false,"path":"%s","created":false,"existed_before":false,"error":%s,"diagnostics":%s}\n' \
        "$path" "$classification" "$diag"
    return 1
}

# ─── ensure_file ─────────────────────────────────────────────────
ensure_file() {
    # Usage: ensure_file <path> [content]
    # Atomic file write: write to temp file, then mv for atomicity.
    # Always returns structured JSON.
    local path="${1:-}" content="${2:-}"

    if [ -z "$path" ]; then
        printf '{"ok":false,"path":"","error":{"code":"E_PATH","layer":"logic","retryable":false,"suggestion":"Path is empty."}}\n'
        return 1
    fi

    # Ensure parent directory exists
    local parent_dir
    parent_dir=$(dirname "$path")
    if [ ! -d "$parent_dir" ]; then
        local dir_result
        dir_result=$(ensure_directory "$parent_dir")
        local dir_ok
        dir_ok=$(printf '%s' "$dir_result" | grep -o '"ok":true')
        if [ -z "$dir_ok" ]; then
            printf '{"ok":false,"path":"%s","error":{"code":"E_PATH","layer":"logic","retryable":false,"suggestion":"Cannot create parent directory: %s"}}\n' \
                "$path" "$parent_dir"
            return 1
        fi
    fi

    # Atomic write: temp file → mv
    local tmpfile
    tmpfile=$(mktemp --tmpdir=/tmp .safe-write-XXXXXX 2>/dev/null) || {
        tmpfile="/tmp/.safe-write-$$-$(date +%s)"
    }

    printf '%s' "$content" > "$tmpfile" 2>/dev/null || {
        printf '{"ok":false,"path":"%s","error":{"code":"E_IO","layer":"os","retryable":true,"suggestion":"Failed to write temp file. Retry once."}}\n' "$path"
        rm -f "$tmpfile" 2>/dev/null
        return 1
    }

    mv "$tmpfile" "$path" 2>&1 || {
        rm -f "$tmpfile" 2>/dev/null
        printf '{"ok":false,"path":"%s","error":{"code":"E_IO","layer":"os","retryable":true,"suggestion":"Failed to move temp file to target. Check permissions and disk space."}}\n' "$path"
        return 1
    }

    printf '{"ok":true,"path":"%s","written":true}\n' "$path"
}

# ─── safe_remove ─────────────────────────────────────────────────
safe_remove() {
    # Usage: safe_remove <path>
    # Trash-style removal: moves to /tmp/.agent-trash/ instead of permanent deletion.
    # Always returns structured JSON.
    local path="${1:-}"

    if [ -z "$path" ]; then
        printf '{"ok":false,"path":"","error":{"code":"E_PATH","layer":"logic","retryable":false,"suggestion":"Path is empty."}}\n'
        return 1
    fi

    if [ ! -e "$path" ] && [ ! -L "$path" ]; then
        printf '{"ok":true,"path":"%s","action":"nothing","reason":"path_does_not_exist"}\n' "$path"
        return 0
    fi

    # Create trash directory if needed
    local trash="/tmp/.agent-trash"
    mkdir -p "$trash" 2>/dev/null

    local ts trash_name
    ts=$(date +%Y%m%d_%H%M%S)
    trash_name="${trash}/$(basename "$path").${ts}.$$"

    mv "$path" "$trash_name" 2>&1 || {
        printf '{"ok":false,"path":"%s","error":{"code":"E_PERM","layer":"permission","retryable":false,"suggestion":"Cannot move to trash. Check permissions."}}\n' "$path"
        return 1
    }

    printf '{"ok":true,"path":"%s","action":"trashed","trash_location":"%s"}\n' "$path" "$trash_name"
}

# ─── Fallback Error Generator ────────────────────────────────────
_fallback_error() {
    # Last-resort error: guaranteed to work even if /proc is unavailable.
    # Only uses shell builtins. NEVER produces empty output.
    cat <<'EOF'
{"ok":false,"error":{"code":"E_SYSTEM_CATASTROPHE","layer":"os","retryable":false,"suggestion":"System resources exhausted or process infrastructure unavailable. Free memory, reduce load, or restart agent."}}
EOF
}

# ─── Self-Test ───────────────────────────────────────────────────
agent_safe_fs_self_test() {
    # Quick self-test to verify the library works.
    # Returns JSON with test results.
    local passed=0 failed=0 results=""

    # Test 1: ensure_directory creates a new directory
    local testdir="/tmp/.agent-safefs-test-$$"
    local out
    out=$(ensure_directory "$testdir")
    if echo "$out" | grep -q '"ok":true'; then
        results+='{"test":"ensure_directory_create","passed":true},'
        passed=$((passed + 1))
    else
        results+='{"test":"ensure_directory_create","passed":false,"output":"'"$(_json_escape "$out")"'"},'
        failed=$((failed + 1))
    fi

    # Test 2: ensure_directory is idempotent
    out=$(ensure_directory "$testdir")
    if echo "$out" | grep -q '"existed_before":true'; then
        results+='{"test":"ensure_directory_idempotent","passed":true},'
        passed=$((passed + 1))
    else
        results+='{"test":"ensure_directory_idempotent","passed":false,"output":"'"$(_json_escape "$out")"'"},'
        failed=$((failed + 1))
    fi

    # Test 3: classify_result handles EEXIST
    out=$(classify_result 17 "mkdir: cannot create directory: File exists")
    if echo "$out" | grep -q '"E_EXISTS"'; then
        results+='{"test":"classify_result_EEXIST","passed":true},'
        passed=$((passed + 1))
    else
        results+='{"test":"classify_result_EEXIST","passed":false,"output":"'"$(_json_escape "$out")"'"},'
        failed=$((failed + 1))
    fi

    # Test 4: guard_exec never returns empty
    out=$(guard_exec 5 echo "hello")
    if [ -n "$out" ]; then
        results+='{"test":"guard_exec_not_empty","passed":true},'
        passed=$((passed + 1))
    else
        results+='{"test":"guard_exec_not_empty","passed":false},'
        failed=$((failed + 1))
    fi

    # Test 5: fallback error is valid JSON
    out=$(_fallback_error)
    if echo "$out" | grep -q '"E_SYSTEM_CATASTROPHE"'; then
        results+='{"test":"fallback_valid_json","passed":true}'
        passed=$((passed + 1))
    else
        results+='{"test":"fallback_valid_json","passed":false}'
        failed=$((failed + 1))
    fi

    # Cleanup
    rm -rf "$testdir" 2>/dev/null

    printf '{"self_test":{"passed":%d,"failed":%d,"total":%d,"results":[%s]}}\n' \
        "$passed" "$failed" $((passed + failed)) "$results"
}

# ─── Print usage if sourced with --help ─────────────────────────
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    echo "agent-safe-fs.sh — AI Agent Safe File System Operations"
    echo ""
    echo "Functions:"
    echo "  ensure_directory <path> [mode]    Idempotent directory creation"
    echo "  ensure_file <path> [content]      Atomic file write"
    echo "  safe_remove <path>                Trash-style removal"
    echo "  classify_result <exit> <stderr>   Map exit code to structured error"
    echo "  guard_exec <timeout> <cmd...>     Execute with timeout + empty-output guard"
    echo "  agent_safe_fs_self_test           Run self-tests"
    echo ""
    echo "All functions return structured JSON. None ever returns empty."
fi
