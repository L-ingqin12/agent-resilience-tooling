#!/usr/bin/env bash
# bash-interceptor.sh — S5 Command-Level Interception Wrapper
# Version: 1.0.0
# Usage: Replace the agent's bash tool command with this wrapper:
#   bash /path/to/bash-interceptor.sh -- <original_command>
# The wrapper inspects the command, applies safety transforms, executes,
# and ensures structured output is always returned.
#
# Integration: Set AGENT_BASH_CMD="bash /path/to/bash-interceptor.sh --"
# or symlink: ln -s /path/to/bash-interceptor.sh /usr/local/bin/agent-bash

set -o pipefail

# ─── Configuration ───────────────────────────────────────────────
SAFE_FS_LIB="${SAFE_FS_LIB:-$HOME/.agent/safe-fs.sh}"
CKPT_LIB="${CKPT_LIB:-$HOME/.agent/agent-checkpoint.sh}"
DEFAULT_TIMEOUT="${AGENT_TIMEOUT:-30}"
BLOCKED_PATTERNS=(
    'rm -rf /[^t]'          # rm -rf /anything (except /tmp)
    'rm -rf ~'               # rm -rf home
    'rm -rf \$HOME'          # rm -rf $HOME
    'mkfs\.'                 # make filesystem
    'dd if=.* of=/dev/'      # raw device write
    '> /dev/sd'              # redirect to block device
    'shutdown'               # system shutdown
    'reboot'                 # system reboot
    ':(){ :|:& };:'          # fork bomb (classic)
    'chmod 777 /'            # world-writable root
    'chmod -R 777 /'         # recursive world-writable root
)
AUTO_FIX_PATTERNS=(
    # Pattern:Replacement
    's/\bmkdir\b(?!\s+-p\b)/mkdir -p/g'          # mkdir → mkdir -p
    's/\brm\b(?!\s+-[rf])/rm -i/g'               # bare rm → rm -i
)
WARN_PATTERNS=(
    'rm -rf /tmp/'           # destructive but in /tmp
    'kill -9'                # forceful kill
)

# ─── Source Safe FS Library ──────────────────────────────────────
[ -f "$SAFE_FS_LIB" ] && source "$SAFE_FS_LIB" 2>/dev/null
[ -f "$CKPT_LIB" ] && source "$CKPT_LIB" 2>/dev/null

# ─── Command Inspection ──────────────────────────────────────────
inspect_command() {
    local cmd="$1"

    # Check blocked patterns
    for pattern in "${BLOCKED_PATTERNS[@]}"; do
        if echo "$cmd" | grep -qE "$pattern"; then
            cat <<EOF
{"ok":false,"intercepted":true,"action":"BLOCKED","reason":"Command matches blocked pattern: $pattern","original_command":"$cmd","suggestion":"This command is too dangerous to execute automatically. Please review manually."}
EOF
            return 1
        fi
    done

    # Check warn patterns
    for pattern in "${WARN_PATTERNS[@]}"; do
        if echo "$cmd" | grep -qE "$pattern"; then
            echo "WARNING: $cmd" >&2
        fi
    done

    # Apply auto-fixes
    local fixed="$cmd"
    for fix in "${AUTO_FIX_PATTERNS[@]}"; do
        local pattern="${fix%%:*}" replacement="${fix##*:}"
        # Apply using sed
        fixed=$(echo "$fixed" | sed -E "$fix" 2>/dev/null || echo "$fixed")
    done

    if [ "$fixed" != "$cmd" ]; then
        cat <<EOF
{"intercepted":true,"action":"AUTO_FIXED","original":"$cmd","fixed":"$fixed"}
EOF
        echo "$fixed"
    else
        echo "$cmd"
    fi

    return 0
}

# ─── Main Execution ──────────────────────────────────────────────
main() {
    local args=() cmd=""
    # Parse: everything after -- is the command
    local found_sep=false
    for arg in "$@"; do
        if [ "$found_sep" = true ]; then
            cmd="$cmd $arg"
        elif [ "$arg" = "--" ]; then
            found_sep=true
        else
            args+=("$arg")
        fi
    done
    cmd="${cmd# }"  # Trim leading space

    if [ -z "$cmd" ]; then
        cat <<'EOF'
{"ok":false,"error":{"code":"E_PATH","layer":"logic","retryable":false,"suggestion":"No command provided to bash-interceptor. Use: bash-interceptor.sh -- <command>"}}
EOF
        return 1
    fi

    # ─── Stage 1: Pre-flight Health Check ───────────────────────
    local mem_avail=""
    [ -r /proc/meminfo ] && mem_avail=$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)
    if [ -n "$mem_avail" ] && [ "$mem_avail" -lt 50 ] 2>/dev/null; then
        cat <<EOF
{"ok":false,"intercepted":true,"action":"BLOCKED_LOW_MEMORY","reason":"System memory critically low (${mem_avail}MB available). Refusing to execute command.","diagnostics":{"mem_available_mb":$mem_avail}}
EOF
        return 1
    fi

    # ─── Stage 2: Command Inspection ────────────────────────────
    local inspected fixed_cmd=""
    inspected=$(inspect_command "$cmd")
    local inspect_rc=$?

    if [ $inspect_rc -ne 0 ]; then
        # BLOCKED — return the error and stop
        echo "$inspected"
        return 1
    fi

    # Check if command was auto-fixed
    if echo "$inspected" | grep -q '"action":"AUTO_FIXED"'; then
        # Extract the fixed command (last line)
        fixed_cmd=$(echo "$inspected" | tail -1)
        echo "$inspected" | head -1  # Emit the AUTO_FIXED notice
    else
        fixed_cmd="$cmd"
    fi

    # ─── Stage 3: Execute with Timeout ──────────────────────────
    local output exit_code
    output=$(timeout "$DEFAULT_TIMEOUT" bash -c "$fixed_cmd" 2>&1)
    exit_code=$?

    # ─── Stage 4: Post-Execution Validation ─────────────────────
    if [ -z "${output// /}" ]; then
        cat <<EOF
{"ok":false,"intercepted":true,"action":"EMPTY_OUTPUT_DETECTED","error":{"code":"E_SYSTEM_CATASTROPHE","layer":"os","retryable":false,"suggestion":"Command produced EMPTY output — process may have crashed. DO NOT retry the same command.","diagnostics":{"exit_code":$exit_code,"original_command":"$cmd","fixed_command":"$fixed_cmd"}}}
EOF
        return 1
    fi

    # Check for error signals in output
    local classification=""
    if echo "$output" | grep -q "Permission denied"; then
        classification='"classification":{"code":"E_PERM","retryable":false,"suggestion":"DO NOT retry — use alternative path"}'
    elif echo "$output" | grep -q "No space left"; then
        classification='"classification":{"code":"E_NOSPC","retryable":true,"suggestion":"Retry ONCE after cleanup, then stop"}'
    elif echo "$output" | grep -q "Killed"; then
        classification='"classification":{"code":"E_OOM","retryable":false,"suggestion":"DO NOT retry — system memory exhausted"}'
    elif echo "$output" | grep -q "Segmentation fault"; then
        classification='"classification":{"code":"E_UNKNOWN","retryable":false,"suggestion":"Command crashed — DO NOT retry"}'
    fi

    # Return structured result with output preserved
    printf '{"ok":%s,"intercepted":true,"exit_code":%d,"output":"%s"%s}\n' \
        "$([ $exit_code -eq 0 ] && echo "true" || echo "false")" \
        "$exit_code" \
        "$(echo "$output" | sed 's/"/\\"/g' | tr '\n' ' ' | head -c 4096)" \
        "${classification:+,$classification}"

    return "$exit_code"
}

# ─── Entry Point ─────────────────────────────────────────────────
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    echo "bash-interceptor.sh — S5 Command-Level Interception Wrapper"
    echo ""
    echo "Usage:"
    echo "  bash-interceptor.sh -- <command>"
    echo "  bash-interceptor.sh -- mkdir /tmp/app"
    echo ""
    echo "Environment variables:"
    echo "  AGENT_TIMEOUT     Command timeout in seconds (default: 30)"
    echo "  SAFE_FS_LIB       Path to agent-safe-fs.sh"
    echo "  CKPT_LIB          Path to agent-checkpoint.sh"
    echo ""
    echo "Stages:"
    echo "  1. Pre-flight health check (memory, load)"
    echo "  2. Command inspection (block/auto-fix/warn)"
    echo "  3. Execute with timeout"
    echo "  4. Post-execution validation (empty output, error classification)"
    exit 0
fi

main "$@"
