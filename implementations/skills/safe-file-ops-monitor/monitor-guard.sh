#!/usr/bin/env bash
# monitor-guard.sh — Sub-Agent Reliability Monitor
# Version: 1.0.0
#
# Called by the main agent after each sub-agent completes.
# Evaluates the sub-agent's output for reliability signals.
# Returns a structured verdict: RELIABLE or UNRELIABLE (with reason + action).
#
# Usage:
#   source monitor-guard.sh
#   evaluate_subagent_output "$subagent_output" "$goal" "$approach" "$attempt_number"

set -o pipefail

# ─── Configuration ───────────────────────────────────────────────
MONITOR_LOG="${MONITOR_LOG:-$HOME/.agent/monitor.log}"
MAX_RETRIES=3
DEADLOOP_THRESHOLD=2  # Same goal+approach appearing this many times = deadloop

# ─── Reliability Evaluation ──────────────────────────────────────
evaluate_subagent_output() {
    # Usage: evaluate_subagent_output <output> <goal> <approach> <attempt_number>
    # Returns JSON verdict:
    #   RELIABLE: {"verdict":"RELIABLE","reason":"...","result":{...}}
    #   UNRELIABLE: {"verdict":"UNRELIABLE","severity":"CRITICAL|HIGH|MEDIUM",
    #                 "reason":"...","action":"KILL_RETRY|KILL_SWITCH|KILL_ESCALATE","context":{...}}
    local output="${1:-}" goal="${2:-}" approach="${3:-}" attempt="${4:-1}"
    local verdict="UNRELIABLE" severity="MEDIUM" action="KILL_RETRY" reason=""

    # ─── Check 1: Empty Output (CRITICAL) ────────────────────────
    if [ -z "${output// /}" ]; then
        severity="CRITICAL"; action="KILL_SWITCH"
        reason="Sub-agent produced EMPTY output — process likely crashed or hung"
        _emit_verdict "$verdict" "$severity" "$action" "$reason" "$goal" "$approach" "$attempt"
        return 1
    fi

    # ─── Check 2: Not JSON-like (HIGH) ──────────────────────────
    # Pure bash check: JSON must start with { and contain "ok":
    # Must start with { (or whitespace then {)
    if ! echo "$output" | head -c 100 | grep -q '{'; then
        # Check if it contains natural language (sub-agent misbehaving)
        if echo "$output" | grep -qiE "I think|let me|maybe|perhaps|I.ll try"; then
            severity="HIGH"; action="KILL_RETRY"
            reason="Sub-agent produced natural language, not JSON — sub-agent is confused"
        else
            severity="HIGH"; action="KILL_RETRY"
            reason="Sub-agent output does not look like JSON (no { found)"
        fi
        _emit_verdict "$verdict" "$severity" "$action" "$reason" "$goal" "$approach" "$attempt"
        return 1
    fi

    # ─── Check 3: Has "ok" field? ────────────────────────────────
    if ! echo "$output" | grep -q '"ok"'; then
        severity="HIGH"; action="KILL_RETRY"
        reason="JSON output missing required 'ok' field"
        _emit_verdict "$verdict" "$severity" "$action" "$reason" "$goal" "$approach" "$attempt"
        return 1
    fi

    # ─── Check 4: Path mismatch (HIGH) ───────────────────────────
    local result_path
    result_path=$(echo "$output" | grep -o '"path":"[^"]*"' | sed 's/"path":"//;s/"//')
    local expected_path
    expected_path=$(echo "$goal" | grep -o '/[^"]*' | head -1)
    if [ -n "$expected_path" ] && [ -n "$result_path" ] && [ "$result_path" != "$expected_path" ]; then
        severity="HIGH"; action="KILL_RETRY"
        reason="Sub-agent operated on wrong path: expected=$expected_path, got=$result_path"
        _emit_verdict "$verdict" "$severity" "$action" "$reason" "$goal" "$approach" "$attempt"
        return 1
    fi

    # ─── Check 5: Success → RELIABLE ─────────────────────────────
    if echo "$output" | grep -q '"ok":true'; then
        verdict="RELIABLE"; severity="NONE"; action="CONTINUE"
        reason="Operation succeeded"
        _emit_verdict "$verdict" "$severity" "$action" "$reason" "$goal" "$approach" "$attempt"
        return 0
    fi

    # ─── Check 6: Classified error → RELIABLE ────────────────────
    if echo "$output" | grep -q '"error":{[^}]*"code":"E_'; then
        local error_code retryable
        error_code=$(echo "$output" | grep -o '"code":"E_[^"]*"' | sed 's/"code":"//;s/"//')
        retryable=$(echo "$output" | grep -o '"retryable":[^,}]*' | sed 's/"retryable"://;s/ //')
        verdict="RELIABLE"; severity="NONE"; action="CONTINUE"
        reason="Classified error: $error_code (retryable=$retryable)"

        if [ "$retryable" = "false" ]; then
            action="DO_NOT_RETRY"
            reason="Non-retryable error: $error_code — must switch strategy"
        fi

        _emit_verdict "$verdict" "$severity" "$action" "$reason" "$goal" "$approach" "$attempt"
        return 0
    fi

    # ─── Check 7: Unknown failure → UNRELIABLE ───────────────────
    severity="MEDIUM"; action="KILL_RETRY"
    reason="Sub-agent returned ok=false but no classified error"
    _emit_verdict "$verdict" "$severity" "$action" "$reason" "$goal" "$approach" "$attempt"
    return 1
}

# ─── Deadloop Detection (across multiple attempts) ──────────────
detect_subagent_deadloop() {
    # Usage: detect_subagent_deadloop <goal> <approach>
    # Checks the monitor log for repeated failures of same goal+approach
    local goal="${1:-}" approach="${2:-}"
    local count

    if [ -f "$MONITOR_LOG" ]; then
        count=$(grep -c "\"goal\":\"$goal\".*\"approach\":\"$approach\".*\"verdict\":\"UNRELIABLE\"" "$MONITOR_LOG" 2>/dev/null || echo "0")
    else
        count=0
    fi

    if [ "${count:-0}" -ge "$DEADLOOP_THRESHOLD" ] 2>/dev/null; then
        echo "true"
        return 0
    fi
    echo "false"
    return 1
}

# ─── Get Alternative Strategy ────────────────────────────────────
get_alternative_strategy() {
    # Usage: get_alternative_strategy <goal_type> <failed_approach> <exhausted_list>
    # Returns the next strategy to try, or "ESCALATE" if all exhausted
    local goal_type="${1:-ensure_directory}" failed="${2:-}" exhausted="${3:-}"
    local strategies=()

    case "$goal_type" in
        ensure_directory) strategies=(mkdir_p python_makedirs perl_makedirs create_parents_first fallback_path) ;;
        ensure_file) strategies=(atomic_write python_write dd_write heredoc_write fallback_path) ;;
        safe_remove) strategies=(trash_move trash_rename copy_then_rm chmod_then_rm) ;;
        *) strategies=(default) ;;
    esac

    for s in "${strategies[@]}"; do
        if ! echo "$exhausted $failed" | grep -q "$s"; then
            echo "$s"
            return 0
        fi
    done

    echo "ESCALATE"
    return 1
}

# ─── Emit Verdict ────────────────────────────────────────────────
_emit_verdict() {
    local verdict="$1" severity="$2" action="$3" reason="$4" goal="$5" approach="$6" attempt="$7"
    local ts
    ts=$(date +%s 2>/dev/null || echo "0")

    # Build structured verdict
    cat <<VERDICT
{
  "verdict": "$verdict",
  "severity": "$severity",
  "action": "$action",
  "reason": "$reason",
  "context": {
    "goal": "$goal",
    "approach": "$approach",
    "attempt": $attempt,
    "timestamp": $ts
  }
}
VERDICT

    # Log to monitor file
    mkdir -p "$(dirname "$MONITOR_LOG")" 2>/dev/null
    cat <<LOGENTRY >> "$MONITOR_LOG" 2>/dev/null
{"ts":$ts,"verdict":"$verdict","severity":"$severity","action":"$action","reason":"$reason","goal":"$goal","approach":"$approach","attempt":$attempt}
LOGENTRY
}

# ─── Main: Evaluate + Decide + Act ───────────────────────────────
monitor_subagent() {
    # Usage: monitor_subagent <output> <goal> <operation> <approach> <attempt> [exhausted]
    # Full pipeline: evaluate → detect deadloop → decide → return action
    local output="$1" goal="$2" op="${3:-ensure_directory}" approach="$4" attempt="${5:-1}" exhausted="${6:-}"
    local verdict_result

    # Step 1: Evaluate reliability
    verdict_result=$(evaluate_subagent_output "$output" "$goal" "$approach" "$attempt")
    local verdict_rc=$?
    local verdict
    verdict=$(echo "$verdict_result" | grep -o '"verdict":"[^"]*"' | sed 's/"verdict":"//;s/"//')

    # Step 2: If RELIABLE, we're done
    if [ "$verdict" = "RELIABLE" ]; then
        echo "$verdict_result"
        return 0
    fi

    # Step 3: Check for deadloop
    local is_deadloop
    is_deadloop=$(detect_subagent_deadloop "$goal" "$approach")

    if [ "$is_deadloop" = "true" ]; then
        # Step 4: Deadloop confirmed — select alternative strategy
        local alternative
        alternative=$(get_alternative_strategy "$op" "$approach" "$exhausted")

        if [ "$alternative" = "ESCALATE" ]; then
            cat <<ESCALATE
{
  "verdict": "UNRELIABLE",
  "severity": "CRITICAL",
  "action": "ESCALATE_TO_USER",
  "reason": "All strategies exhausted for goal: $goal",
  "context": {
    "goal": "$goal",
    "failed_approaches": "$exhausted $approach",
    "attempt": $attempt,
    "recommendation": "Steps before this one are preserved. Manual intervention needed for this step."
  }
}
ESCALATE
            return 2
        fi

        # Return KILL_SWITCH with the recommended alternative
        cat <<SWITCH
{
  "verdict": "UNRELIABLE",
  "severity": "CRITICAL",
  "action": "KILL_SWITCH_STRATEGY",
  "reason": "Deadloop detected: same goal+approach failed $DEADLOOP_THRESHOLD+ times",
  "context": {
    "goal": "$goal",
    "failed_approach": "$approach",
    "DO_NOT_RETRY": ["$approach"],
    "recommended_next": "$alternative",
    "strategies_remaining": "$(get_alternative_strategy "$op" "$alternative" "$exhausted $approach")"
  }
}
SWITCH
        return 1
    fi

    # Step 5: First failure — retry with same approach but stricter prompt
    echo "$verdict_result"
    return 1
}

# ─── Self-Test ───────────────────────────────────────────────────
monitor_self_test() {
    echo "=== Monitor Self-Test ==="
    local pass=0 fail=0

    # Test 1: Reliable success
    R=$(evaluate_subagent_output '{"ok":true,"path":"/tmp/test","created":true}' "ensure /tmp/test" "mkdir_p" 1)
    echo "$R" | grep -q '"verdict":.*"RELIABLE"' && { echo "  ✓ Reliable success detected"; pass=$((pass+1)); } || { echo "  ✗ Failed"; fail=$((fail+1)); }

    # Test 2: Unreliable: empty output
    R=$(evaluate_subagent_output "" "ensure /tmp/test" "mkdir_p" 1)
    echo "$R" | grep -q '"verdict":.*"UNRELIABLE"' && echo "$R" | grep -q '"severity":.*"CRITICAL"' && { echo "  ✓ Empty output = CRITICAL UNRELIABLE"; pass=$((pass+1)); } || { echo "  ✗ Failed"; fail=$((fail+1)); }

    # Test 3: Reliable classified error
    R=$(evaluate_subagent_output '{"ok":false,"error":{"code":"E_PERM","retryable":false}}' "ensure /tmp/test" "mkdir_p" 1)
    echo "$R" | grep -q '"verdict":.*"RELIABLE"' && echo "$R" | grep -q '"action":.*"DO_NOT_RETRY"' && { echo "  ✓ Classified error = RELIABLE (non-retryable)"; pass=$((pass+1)); } || { echo "  ✗ Failed"; fail=$((fail+1)); }

    # Test 4: Not JSON
    R=$(evaluate_subagent_output "I think maybe let me try mkdir..." "ensure /tmp/test" "mkdir_p" 1)
    echo "$R" | grep -q '"verdict":.*"UNRELIABLE"' && { echo "  ✓ Natural language = UNRELIABLE"; pass=$((pass+1)); } || { echo "  ✗ Failed"; fail=$((fail+1)); }

    echo "  Result: $pass/$((pass+fail)) passed"
    [ "$fail" -gt 0 ] && return 1 || return 0
}

# Run self-test if executed directly
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    monitor_self_test
fi
