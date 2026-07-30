#!/bin/bash
# PreToolUse hook: bash command guard
# Intercepts bash tool invocations, scans for dangerous patterns,
# and auto-replaces, blocks, or warns as appropriate.
#
# Input:  JSON tool use payload from stdin (Claude Code hook protocol)
# Output: JSON to stdout with potential command modification
# Exit:   0 always (hook failure must never block the agent)

set -o pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Commands that MUST have -p when used as mkdir
# Patterns that are BLOCKED entirely
BLOCKED_PATTERNS=(
    'rm -rf /[[:space:]]*$'
    'rm -rf /;'
    'rm -rf /&'
    'rm -rf /|'
    'rm -rf /\|'
    'mkfs\.'
    'shutdown'
    'reboot'
    ':(){ :|:& };:'
    'dd if=/dev/zero of=/dev/sd'
    'dd if=/dev/random of=/dev/sd'
    '> /dev/sd'
    'chmod -R 0 /'
    'chown -R .* / '
)

# Patterns that are BLOCKED with special message (rm crossing safe boundary)
BLOCKED_RM_SYSTEM=(
    'rm -rf /etc'
    'rm -rf /usr'
    'rm -rf /boot'
    'rm -rf /dev'
    'rm -rf /proc'
    'rm -rf /sys'
    'rm -rf /lib'
    'rm -rf /bin'
    'rm -rf /sbin'
    'rm -rf /opt'
)

# Blocked rm -rf with destructive flags
BLOCKED_RM_DESTRUCTIVE=(
    'rm -rf --no-preserve-root'
    'rm -rf /$'
)

# ---------------------------------------------------------------------------
# Helper: parse JSON input (no jq dependency)
# ---------------------------------------------------------------------------

parse_tool_input() {
    # Extract the command string from Claude Code's tool input JSON.
    # Format: {"tool":"Bash","input":"command here","tool_use_id":"..."}
    local input_json
    input_json=$(cat)

    # Try to extract the "input" field value using basic string operations.
    # This is intentionally simple; for production, use jq.
    if command -v jq &>/dev/null; then
        echo "$input_json" | jq -r '.input // .command // empty' 2>/dev/null
    else
        # Fallback: naive extraction
        local cmd
        cmd=$(echo "$input_json" | grep -oP '"input"\s*:\s*"\K[^"]+' 2>/dev/null || true)
        if [ -z "$cmd" ]; then
            cmd=$(echo "$input_json" | grep -oP '"command"\s*:\s*"\K[^"]+' 2>/dev/null || true)
        fi
        echo "$cmd"
    fi
}

# ---------------------------------------------------------------------------
# Helper: check if command matches a pattern list
# ---------------------------------------------------------------------------

matches_any_pattern() {
    local cmd="$1"
    shift
    local patterns=("$@")
    local pattern
    for pattern in "${patterns[@]}"; do
        if echo "$cmd" | grep -qE "$pattern"; then
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# Helper: auto-add -p to mkdir commands
# ---------------------------------------------------------------------------

fix_mkdir_missing_p() {
    local cmd="$1"

    # Match bare mkdir (without -p) used with a path argument.
    # Handles: mkdir /path, mkdir /path1 /path2, mkdir -m 755 /path
    # Does NOT match: mkdir -p /path (already safe)
    local modified
    modified=$(echo "$cmd" | sed -E \
        -e 's/\bmkdir\s+(-[^p]\S*\s+)*\/([^\s;|&]+)/mkdir -p \/\2/g' \
        2>/dev/null)

    # If modification changed the command, output with transform metadata
    if [ "$modified" != "$cmd" ] && echo "$modified" | grep -qE '\bmkdir -p '; then
        echo "[AUTO-FIX] Added -p flag to mkdir: ${modified}" >&2
        echo "$modified"
        return 0
    fi

    return 1
}

# ---------------------------------------------------------------------------
# Helper: check for rm -rf on critical system paths
# ---------------------------------------------------------------------------

check_rm_dangerous() {
    local cmd="$1"

    # Check for any blocked system directory patterns
    if matches_any_pattern "$cmd" "${BLOCKED_RM_SYSTEM[@]}"; then
        echo "BLOCKED"
        return 0
    fi

    # Check for other destructive patterns
    if matches_any_pattern "$cmd" "${BLOCKED_RM_DESTRUCTIVE[@]}"; then
        echo "BLOCKED"
        return 0
    fi

    # Check for generic rm -rf / (prevent removal of root)
    if echo "$cmd" | grep -qP 'rm\s+-rf\s+/\s*$'; then
        echo "BLOCKED"
        return 0
    fi

    echo "SAFE"
    return 0
}

# ---------------------------------------------------------------------------
# Helper: categorize rm -rf on non-system path (allow with warning)
# ---------------------------------------------------------------------------

is_rm_warn_but_allow() {
    local cmd="$1"

    # If rm -rf targets a path under /tmp, /root/workspace, /home, or
    # other non-system locations, allow with a warning.
    # We do NOT check for -rf alone — only when combined with paths.

    if echo "$cmd" | grep -qP 'rm\s+-rf\s+(/tmp/|/root/workspace/|/home/|/var/tmp/)'; then
        return 0  # it's allowed-with-warning
    fi

    return 1  # not recognized as safe, will be handled by other checks
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    # Read the raw input from stdin (Claude Code hook protocol)
    local raw_input
    raw_input=$(cat)

    # Parse out the bash command string
    local command
    command=$(echo "$raw_input" | parse_tool_input)

    # If no command could be extracted, pass through unchanged
    if [ -z "$command" ]; then
        echo '{"status":"passed","command":""}'
        exit 0
    fi

    local output_cmd="$command"
    local status="passed"
    local warnings=""

    # ---- STAGE 1: Check for blocked patterns (absolute blocks) ----

    # Check for fork bomb / system destruction patterns
    if matches_any_pattern "$command" "${BLOCKED_PATTERNS[@]}"; then
        local matched_pattern
        matched_pattern=$(echo "$command" | grep -oE '(rm -rf /[[:space:]]|mkfs|shutdown|reboot|:\(\)|dd if=/dev/zero|dd if=/dev/random|> /dev/sd|chmod -R 0 /|chown -R .* / )' | head -1)

        echo "{
  \"status\": \"blocked\",
  \"original_command\": $(echo "$command" | jq -Rs .),
  \"reason\": \"Command matches blocked destructive pattern: ${matched_pattern}\",
  \"suggestion\": \"This operation is blocked for safety. If you need to perform this operation, rephrase with explicit path targeting and --no-preserve-root only in an interactive session.\",
  \"command\": \"\"
}"
        exit 0
    fi

    # ---- STAGE 2: Check for rm -rf on system paths (blocked) ----

    local rm_status
    rm_status=$(check_rm_dangerous "$command")
    if [ "$rm_status" = "BLOCKED" ]; then
        echo "{
  \"status\": \"blocked\",
  \"original_command\": $(echo "$command" | jq -Rs .),
  \"reason\": \"rm -rf targets a blocked system directory or root filesystem\",
  \"suggestion\": \"Use the trash-style removal pattern: mkdir -p /tmp/.trash/$(date +%Y%m%d) && mv /path /tmp/.trash/$(date +%Y%m%d)/\",
  \"command\": \"\"
}"
        exit 0
    fi

    # ---- STAGE 3: Auto-fix mkdir without -p ----

    local fixed_command
    fixed_command=$(fix_mkdir_missing_p "$command")
    if [ -n "$fixed_command" ] && [ "$fixed_command" != "$command" ]; then
        output_cmd="$fixed_command"
        status="modified"
        warnings+="AUTO-FIX: Added -p flag to mkdir. "
    fi

    # ---- STAGE 4: Warn-but-allow for certain destructive ops ----

    if is_rm_warn_but_allow "$command"; then
        status="warn_allow"
        warnings+="WARNING: Destructive rm command targeting workspace/temp path. Verify this is intended. "
    fi

    # ---- STAGE 5: Output result as JSON ----

    # Build output JSON
    local json_output
    if command -v jq &>/dev/null; then
        json_output=$(jq -n \
            --arg status "$status" \
            --arg command "$output_cmd" \
            --arg warnings "$warnings" \
            '{status: $status, command: $command, warnings: $warnings}')
    else
        # Manual JSON construction (no jq)
        json_output="{
  \"status\": \"$(echo "$status" | sed 's/"/\\"/g')\",
  \"command\": $(echo "$output_cmd" | sed 's/"/\\"/g'),
  \"warnings\": $(echo "$warnings" | sed 's/"/\\"/g')
}"
        # Wrap command in proper JSON string
        json_output=$(echo "{
  \"status\": \"$status\",
  \"command\": \"$(echo "$output_cmd" | sed 's/"/\\"/g; s/\\/\\\\/g; s/\t/\\t/g; s/\n/\\n/g')\",
  \"warnings\": \"$(echo "$warnings" | sed 's/"/\\"/g')\"
}")
    fi

    echo "$json_output"
    exit 0
}

main "$@"
