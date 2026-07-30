#!/bin/bash
# PostToolUse hook: bash output validator
# Intercepts bash tool results, checks for common error patterns,
# and augments the output with structured classifications.
#
# Input:  JSON tool result payload from stdin (Claude Code hook protocol)
# Output: JSON to stdout with potentially augmented result
# Exit:   0 always (hook failure must never block the agent)

set -o pipefail

# ---------------------------------------------------------------------------
# Helper: parse JSON input
# ---------------------------------------------------------------------------

parse_tool_result() {
    if command -v jq &>/dev/null; then
        jq -r '.result // .output // .stdout // empty' 2>/dev/null
    else
        local result
        result=$(grep -oP '"result"\s*:\s*"\K[^"]+' 2>/dev/null || true)
        if [ -z "$result" ]; then
            result=$(grep -oP '"output"\s*:\s*"\K[^"]+' 2>/dev/null || true)
        fi
        if [ -z "$result" ]; then
            result=$(grep -oP '"stdout"\s*:\s*"\K[^"]+' 2>/dev/null || true)
        fi
        echo "$result"
    fi
}

# ---------------------------------------------------------------------------
# Helper: check for empty output
# ---------------------------------------------------------------------------

check_empty_output() {
    local output="$1"
    local stderr="$2"

    # If stdout and stderr are both empty or whitespace-only
    if [ -z "$(echo "$output" | tr -d '[:space:]')" ] && [ -z "$(echo "$stderr" | tr -d '[:space:]')" ]; then
        return 0  # empty
    fi
    return 1  # not empty
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    local raw_input
    raw_input=$(cat)

    # If no input, output empty result JSON and exit
    if [ -z "$raw_input" ]; then
        echo '{"status":"passed","result":"","warnings":[],"errors":[]}'
        exit 0
    fi

    local result_output
    local stderr_output
    local exit_code
    local warnings=()
    local errors=()

    # Extract fields from input JSON
    if command -v jq &>/dev/null; then
        result_output=$(echo "$raw_input" | jq -r '.result // .output // .stdout // ""' 2>/dev/null)
        stderr_output=$(echo "$raw_input" | jq -r '.stderr // ""' 2>/dev/null)
        exit_code=$(echo "$raw_input" | jq -r '.exit_code // .exitCode // "0"' 2>/dev/null)
    else
        result_output=$(echo "$raw_input" | grep -oP '"(result|output|stdout)"\s*:\s*"\K[^"]*' 2>/dev/null | tr '\n' ' ' || true)
        stderr_output=$(echo "$raw_input" | grep -oP '"(stderr)"\s*:\s*"\K[^"]*' 2>/dev/null || true)
        exit_code=$(echo "$raw_input" | grep -oP '"(exit_code|exitCode)"\s*:\s*"\K[^"]*' 2>/dev/null || echo "0")
    fi

    combined_output="${result_output}${stderr_output}"

    # ---- CHECK 1: Empty output ----
    if check_empty_output "$result_output" "$stderr_output"; then
        local empty_error='{"type":"empty_output","severity":"warning","message":"Command produced no output (stdout and stderr both empty). This may indicate the command did not execute or produced no visible result.","classification":"NO_OUTPUT"}'
        errors+=("$empty_error")
    fi

    # ---- CHECK 2: Permission denied ----
    if echo "$combined_output" | grep -q "Permission denied"; then
        local perm_warning='{"type":"permission_denied","severity":"error","message":"Permission denied error detected in command output. Check file ownership, ACLs, or whether elevated privileges are needed.","classification":"PERMISSION_DENIED","action":"Check file ownership with `stat`, verify ACLs with `getfacl`, or prefix with sudo if appropriate and permitted."}'
        warnings+=("$perm_warning")
    fi

    # ---- CHECK 3: Killed / Segmentation fault ----
    local sig_sev="error"
    local sig_action=""

    if echo "$combined_output" | grep -q "Killed"; then
        local killed_error='{"type":"process_killed","severity":"stop","message":"Process was killed (SIGKILL). This is often caused by OOM (Out of Memory) or system resource pressure.","classification":"PROCESS_KILLED","action":"STOP: Do not retry. Check system memory with `free -m`, review OOM logs with `dmesg | grep -i oom`, and reduce memory usage before retrying.","signal":"STOP"}'
        errors+=("$killed_error")
    fi

    if echo "$combined_output" | grep -q "Segmentation fault"; then
        local segfault_error='{"type":"segmentation_fault","severity":"stop","message":"Process experienced a segmentation fault (SIGSEGV). This may indicate memory corruption, a bug in the tool, or filesystem corruption.","classification":"SEGFAULT","action":"STOP: Do not retry. Verify filesystem integrity, check for memory errors, and report the command that caused the fault.","signal":"STOP"}'
        errors+=("$segfault_error")
    fi

    # ---- CHECK 4: Detect common shell errors ----
    if echo "$combined_output" | grep -q "No such file or directory"; then
        local nsf_error='{"type":"no_such_file","severity":"warning","message":"Command references a file or directory that does not exist.","classification":"MISSING_PATH","action":"Verify the path exists before referencing it. Use `ls` or `test -e` to confirm."}'
        warnings+=("$nsf_error")
    fi

    if echo "$combined_output" | grep -q "command not found"; then
        local cnf_error='{"type":"command_not_found","severity":"error","message":"A command in the pipeline was not found.","classification":"MISSING_COMMAND","action":"Check PATH, install missing package, or verify command spelling."}'
        errors+=("$cnf_error")
    fi

    if echo "$combined_output" | grep -q "Read-only file system"; then
        local ro_error='{"type":"readonly_fs","severity":"stop","message":"Target filesystem is read-only. Writes will fail.","classification":"READONLY_FS","action":"STOP: Remount filesystem with write permission or select a different target path.","signal":"STOP"}'
        errors+=("$ro_error")
    fi

    if echo "$combined_output" | grep -q "Disk quota exceeded"; then
        local quota_error='{"type":"disk_quota","severity":"stop","message":"Disk quota exceeded. Cannot write more data.","classification":"DISK_QUOTA","action":"STOP: Free space or increase quota before retrying.","signal":"STOP"}'
        errors+=("$quota_error")
    fi

    # ---- CHECK 5: Exit code analysis ----
    local exit_classification="success"
    if [ "$exit_code" != "0" ] && [ -n "$exit_code" ]; then
        case "$exit_code" in
            1)   exit_classification="general_error" ;;
            2)   exit_classification="misuse" ;;
            126) exit_classification="not_executable" ;;
            127) exit_classification="not_found" ;;
            128) exit_classification="invalid_exit" ;;
            130) exit_classification="interrupted" ;;
            137) exit_classification="killed_oom" ;;
            139) exit_classification="segfault" ;;
            *)   exit_classification="unknown_error" ;;
        esac
    fi

    # ---- Build output JSON ----
    local augmented_result
    if command -v jq &>/dev/null; then
        # Use jq to build clean JSON
        augmented_result=$(echo "$raw_input" | jq \
            --argjson warnings "$(printf '%s\n' "${warnings[@]}" | jq -s '.' 2>/dev/null || echo '[]')" \
            --argjson errors "$(printf '%s\n' "${errors[@]}" | jq -s '.' 2>/dev/null || echo '[]')" \
            --arg exit_classification "$exit_classification" \
            '. + {
                "hook_analysis": {
                    "exit_classification": $exit_classification,
                    "warnings": $warnings,
                    "errors": $errors,
                    "needs_attention": (($errors | length) > 0),
                    "stop_signal": (($errors[] | select(.signal == "STOP")) | true) // false
                }
            }')
    else
        # No jq: pass through with minimal augmentation
        local has_issues="false"
        [ "${#errors[@]}" -gt 0 ] && has_issues="true"

        augmented_result=$(echo "$raw_input" | sed 's/}$//')
        augmented_result="${augmented_result}, \"hook_analysis\": {"
        augmented_result="${augmented_result} \"exit_classification\": \"${exit_classification}\","
        augmented_result="${augmented_result} \"warnings_count\": ${#warnings[@]},"
        augmented_result="${augmented_result} \"errors_count\": ${#errors[@]},"
        augmented_result="${augmented_result} \"needs_attention\": ${has_issues}"
        augmented_result="${augmented_result} }}"
    fi

    echo "$augmented_result"
    exit 0
}

main "$@"
