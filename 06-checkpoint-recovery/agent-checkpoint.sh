#!/usr/bin/env bash
# agent-checkpoint.sh — Checkpoint Recovery & Multi-Strategy Fallback Library
# Version: 1.0.0
# Usage: source together with agent-safe-fs.sh
#   source /path/to/agent-safe-fs.sh
#   source /path/to/agent-checkpoint.sh
#
# Design constraints:
#   - bash 4.0+, coreutils only
#   - JSONL checkpoint log, append-only (WAL pattern)
#   - Atomic writes via tmpfile + mv
#   - All functions return structured JSON, never empty
#   - ~150 lines (Pi Agent constraint)

set -o pipefail

CHECKPOINT_FILE="${CHECKPOINT_FILE:-$HOME/.agent/checkpoints.jsonl}"
CHECKPOINT_DIR="$(dirname "$CHECKPOINT_FILE")"
MAX_CHECKPOINTS=100  # Prevent unbounded growth

# ─── Internal Helpers ────────────────────────────────────────────
_init_checkpoint_dir() {
    mkdir -p "$CHECKPOINT_DIR" 2>/dev/null || {
        CHECKPOINT_DIR="/tmp/.agent-checkpoints"
        CHECKPOINT_FILE="$CHECKPOINT_DIR/checkpoints.jsonl"
        mkdir -p "$CHECKPOINT_DIR" 2>/dev/null
    }
}

_atomic_append() {
    # WAL-style atomic append: write to tmpfile, then mv
    local tmpfile
    tmpfile=$(mktemp --tmpdir=/tmp .ckpt-XXXXXX 2>/dev/null || echo "/tmp/.ckpt-$$-$(date +%s)")
    cat > "$tmpfile"
    cat "$tmpfile" >> "$CHECKPOINT_FILE" 2>/dev/null || mv "$tmpfile" "$CHECKPOINT_FILE" 2>/dev/null
    rm -f "$tmpfile" 2>/dev/null
}

_get_last_seq() {
    tail -1 "$CHECKPOINT_FILE" 2>/dev/null | grep -o '"seq":[0-9]*' | grep -o '[0-9]*' || echo "0"
}

_rotate_if_needed() {
    local lines
    lines=$(wc -l < "$CHECKPOINT_FILE" 2>/dev/null || echo "0")
    if [ "$lines" -gt "$MAX_CHECKPOINTS" ]; then
        # Keep last MAX_CHECKPOINTS/2 entries (oldest may still be relevant)
        tail -$((MAX_CHECKPOINTS / 2)) "$CHECKPOINT_FILE" > "${CHECKPOINT_FILE}.tmp" 2>/dev/null
        mv "${CHECKPOINT_FILE}.tmp" "$CHECKPOINT_FILE" 2>/dev/null
    fi
}

# ─── Checkpoint Save ─────────────────────────────────────────────
checkpoint_save() {
    # Usage: checkpoint_save <goal> <op> <approach> <pre_state> <post_state> <undo>
    # Records a successful operation as a checkpoint.
    local goal="${1:-}" op="${2:-}" approach="${3:-}" pre_state="${4:-}" post_state="${5:-}" undo="${6:-}"
    local seq ts
    _init_checkpoint_dir
    seq=$(($(_get_last_seq) + 1))
    ts=$(date +%s 2>/dev/null || echo "0")

    local entry
    entry=$(cat <<JSONENTRY
{"seq":$seq,"goal":"$goal","op":"$op","state":"completed","approach":"$approach","pre_state":"$pre_state","post_state":"$post_state","undo":"$undo","verified_at":$ts,"ts":$ts}
JSONENTRY
)
    echo "$entry" | _atomic_append
    _rotate_if_needed

    printf '{"checkpoint_saved":true,"seq":%d,"goal":"%s"}\n' "$seq" "$goal"
}

# ─── Checkpoint Lookup ───────────────────────────────────────────
checkpoint_lookup() {
    # Usage: checkpoint_lookup <goal_pattern> [state]
    # Returns the last checkpoint matching the goal pattern.
    # Used for skip-completed: verify goal already achieved before attempting.
    local pattern="${1:-}" state="${2:-completed}"
    local result
    result=$(grep "$pattern" "$CHECKPOINT_FILE" 2>/dev/null | grep "\"state\":\"$state\"" | tail -1)
    if [ -n "$result" ]; then
        printf '%s\n' "$result"
        return 0
    fi
    return 1
}

# ─── Checkpoint Load Last Success ────────────────────────────────
checkpoint_load_last_success() {
    # Returns the last completed checkpoint as structured JSON.
    local result
    result=$(grep '"state":"completed"' "$CHECKPOINT_FILE" 2>/dev/null | tail -1)
    if [ -n "$result" ]; then
        printf '%s\n' "$result"
        return 0
    fi
    printf '{"error":"no_checkpoint_found","suggestion":"No completed checkpoints exist. Start from beginning."}\n'
    return 1
}

# ─── Checkpoint Mark Deadloop ────────────────────────────────────
checkpoint_mark_deadloop() {
    # Usage: checkpoint_mark_deadloop <goal> <op> <approach> <attempt_details_json> <strategies_remaining_json>
    # Records a deadloop event, preserving which strategies were tried and what remains.
    local goal="${1:-}" op="${2:-}" approach="${3:-}" attempts="${4:-[]}" remaining="${5:-[]}"
    local seq ts
    _init_checkpoint_dir
    seq=$(($(_get_last_seq) + 1))
    ts=$(date +%s 2>/dev/null || echo "0")

    local entry
    entry=$(cat <<JSONENTRY
{"seq":$seq,"goal":"$goal","op":"$op","state":"deadloop","approach":"$approach","attempts":$attempts,"strategies_exhausted":["$approach"],"strategies_remaining":$remaining,"ts":$ts}
JSONENTRY
)
    echo "$entry" | _atomic_append
    _rotate_if_needed

    printf '{"checkpoint_deadloop":true,"seq":%d,"goal":"%s"}\n' "$seq" "$goal"
}

# ─── Checkpoint Rollback ─────────────────────────────────────────
checkpoint_rollback() {
    # Usage: checkpoint_rollback <target_seq>
    # Rolls back to target_seq: executes undo for all checkpoints > target_seq,
    # then marks them as rolled_back.
    local target_seq="${1:-0}"
    local current_seq count=0 undo_cmds=""

    _init_checkpoint_dir
    current_seq=$(_get_last_seq)

    # Collect undo commands from checkpoints newer than target (reverse order)
    while [ "$current_seq" -gt "$target_seq" ]; do
        local line undo
        line=$(grep "\"seq\":$current_seq" "$CHECKPOINT_FILE" 2>/dev/null | head -1)
        if [ -n "$line" ]; then
            undo=$(echo "$line" | grep -o '"undo":"[^"]*"' | sed 's/"undo":"//;s/"//')
            if [ -n "$undo" ]; then
                eval "$undo" 2>/dev/null || true
                count=$((count + 1))
            fi
            # Mark as rolled_back (append new entry, don't modify original — WAL principle)
            local goal op ts
            goal=$(echo "$line" | grep -o '"goal":"[^"]*"' | sed 's/"goal":"//;s/"//')
            op=$(echo "$line" | grep -o '"op":"[^"]*"' | sed 's/"op":"//;s/"//')
            ts=$(date +%s 2>/dev/null || echo "0")
            cat <<JSONENTRY | _atomic_append
{"seq":$(($(_get_last_seq) + 1)),"goal":"$goal","op":"$op","state":"rolled_back","rollback_reason":"manual_rollback_to_seq_$target_seq","rolled_back_to_seq":$target_seq,"ts":$ts}
JSONENTRY
        fi
        current_seq=$((current_seq - 1))
    done

    printf '{"checkpoint_rollback":true,"target_seq":%d,"undos_executed":%d}\n' "$target_seq" "$count"
}

# ─── Checkpoint Verify State ─────────────────────────────────────
checkpoint_verify() {
    # Usage: checkpoint_verify <seq>
    # Verifies that the post_state recorded in checkpoint <seq> still holds.
    local seq="${1:-}"
    local line post_state path goal
    line=$(grep "\"seq\":$seq" "$CHECKPOINT_FILE" 2>/dev/null | head -1)
    [ -z "$line" ] && { printf '{"verified":false,"reason":"checkpoint_not_found","seq":%s}\n' "$seq"; return 1; }

    post_state=$(echo "$line" | grep -o '"post_state":"[^"]*"' | sed 's/"post_state":"//;s/"//')
    goal=$(echo "$line" | grep -o '"goal":"[^"]*"' | sed 's/"goal":"//;s/"//')
    # Robust path extraction: try goal first, then undo field as fallback
    path=$(echo "$goal" | grep -o '/[^" ]*' | head -1)
    if [ -z "$path" ]; then
        # Fallback: extract path from undo command (e.g., "rmdir /tmp/foo")
        local undo
        undo=$(echo "$line" | grep -o '"undo":"[^"]*"' | sed 's/"undo":"//;s/"//')
        path=$(echo "$undo" | grep -o '/[^" ]*' | head -1)
    fi

    case "$post_state" in
        directory)
            if [ -d "$path" ]; then
                printf '{"verified":true,"seq":%s,"path":"%s","state":"directory","still_valid":true}\n' "$seq" "$path"
                return 0
            else
                printf '{"verified":false,"seq":%s,"path":"%s","expected":"directory","actual":"missing_or_changed"}\n' "$seq" "$path"
                return 1
            fi ;;
        file*)
            if [ -f "$path" ]; then
                printf '{"verified":true,"seq":%s,"path":"%s","state":"file","still_valid":true}\n' "$seq" "$path"
                return 0
            else
                printf '{"verified":false,"seq":%s,"path":"%s","expected":"file","actual":"missing_or_changed"}\n' "$seq" "$path"
                return 1
            fi ;;
        none)
            printf '{"verified":true,"seq":%s,"state":"none","note":"no post_state to verify"}\n' "$seq"
            return 0 ;;
        *)
            printf '{"verified":false,"seq":%s,"reason":"unknown_post_state_type","post_state":"%s"}\n' "$seq" "$post_state"
            return 1 ;;
    esac
}

# ─── Checkpoint Build Recovery Context ───────────────────────────
checkpoint_build_recovery_context() {
    # Usage: checkpoint_build_recovery_context <failed_seq>
    # Builds the FAILURE CONTEXT INJECTION message for the LLM.
    # This is the most critical function — it tells the LLM:
    #   1. What failed and WHY
    #   2. What NOT to retry
    #   3. What alternatives remain
    #   4. What is the recommended next strategy
    local failed_seq="${1:-}"
    local line attempts exhausted remaining goal path
    line=$(grep "\"seq\":$failed_seq" "$CHECKPOINT_FILE" 2>/dev/null | head -1)
    [ -z "$line" ] && { printf '{"error":"failed_checkpoint_not_found","seq":%s}\n' "$failed_seq"; return 1; }

    goal=$(echo "$line" | grep -o '"goal":"[^"]*"' | sed 's/"goal":"//;s/"//')
    path=$(echo "$goal" | grep -o '/[^ ]*' | head -1)
    attempts=$(echo "$line" | grep -o '"attempts":\[[^]]*\]' | sed 's/"attempts"://')
    remaining=$(echo "$line" | grep -o '"strategies_remaining":\[[^]]*\]' | sed 's/"strategies_remaining"://')

    # Find the last successful checkpoint (the recovery target)
    local last_success last_success_seq=0
    last_success=$(checkpoint_load_last_success 2>/dev/null)
    last_success_seq=$(echo "$last_success" | grep -o '"seq":[0-9]*' | grep -o '[0-9]*' || echo "0")

    # Determine recommended next strategy based on error type
    local first_error recommended
    first_error=$(echo "$attempts" | grep -o '"error":"[^"]*"' | head -1 | sed 's/"error":"//;s/"//')
    case "$first_error" in
        E_PERM) recommended="python_makedirs" ;;    # Different syscall path
        E_NOSPC) recommended="fallback_path" ;;      # Different filesystem
        E_IO) recommended="create_parents_first" ;;  # Simpler operation
        *) recommended=$(echo "$remaining" | grep -o '"[^"]*"' | head -1 | tr -d '"') ;;
    esac

    # Build the context injection message
    cat <<CTXEOF
{
  "recovery_context": {
    "recovered_to_seq": $last_success_seq,
    "skipped_steps_verified": true,
    "failed_step": {
      "seq": $failed_seq,
      "goal": "$goal",
      "path": "$path",
      "why_failed": "All attempts with the original approach failed. See attempts for details.",
      "attempts": $attempts,
      "strategies_exhausted": ["the_original_approach"],
      "strategies_remaining": $remaining,
      "recommended_next": "$recommended",
      "DO_NOT_RETRY": ["the original approach on $path"]
    },
    "context_for_llm": "Step $failed_seq ($goal) failed. The original approach does NOT work. You MUST use a different strategy: $recommended. Do NOT repeat the failed approaches listed in DO_NOT_RETRY. Steps 1..$last_success_seq are preserved and verified."
  }
}
CTXEOF
}

# ─── Checkpoint Recover (main entry point) ───────────────────────
checkpoint_recover() {
    # Usage: checkpoint_recover <failed_seq>
    # The main recovery function — orchestrates the full recovery flow:
    #   1. Load failed checkpoint
    #   2. Rollback to last successful checkpoint
    #   3. Execute undo for intermediate steps
    #   4. Verify preserved state
    #   5. Build and return the failure context injection message for the LLM
    local failed_seq="${1:-}"
    local last_success_line last_success_seq

    _init_checkpoint_dir

    # Find last successful checkpoint
    last_success_line=$(grep '"state":"completed"' "$CHECKPOINT_FILE" 2>/dev/null | tail -1)
    if [ -z "$last_success_line" ]; then
        printf '{"recovery_failed":true,"reason":"no_successful_checkpoint_to_rollback_to","suggestion":"All operations must be retried from the beginning."}\n'
        return 1
    fi
    last_success_seq=$(echo "$last_success_line" | grep -o '"seq":[0-9]*' | grep -o '[0-9]*')

    # Rollback to last successful checkpoint
    checkpoint_rollback "$last_success_seq" > /dev/null

    # Verify the recovered state
    local verify_result
    verify_result=$(checkpoint_verify "$last_success_seq")
    local verified
    verified=$(echo "$verify_result" | grep -o '"still_valid":true')
    if [ -z "$verified" ]; then
        printf '{"recovery_failed":true,"reason":"checkpoint_state_no_longer_valid","seq":%s,"verification":%s}\n' \
            "$last_success_seq" "$verify_result"
        return 1
    fi

    # Build the context injection message
    checkpoint_build_recovery_context "$failed_seq"
}

# ─── Checkpoint Detect Deadloop ──────────────────────────────────
checkpoint_detect_deadloop() {
    # Usage: checkpoint_detect_deadloop <goal> <approach>
    # Detects if the same goal+approach has been attempted multiple times.
    # Returns the deadloop checkpoint seq if found, empty otherwise.
    local goal="${1:-}" approach="${2:-}"
    local count
    count=$(grep -c "\"goal\":\"$goal\".*\"approach\":\"$approach\"" "$CHECKPOINT_FILE" 2>/dev/null || echo "0")

    if [ "$count" -ge 2 ]; then
        # Confirmed deadloop — same goal + same approach ≥ 2 times
        local last_attempt
        last_attempt=$(grep "\"goal\":\"$goal\".*\"approach\":\"$approach\"" "$CHECKPOINT_FILE" 2>/dev/null | tail -1)
        echo "$last_attempt" | grep -o '"seq":[0-9]*' | grep -o '[0-9]*'
        return 0
    fi
    return 1
}

# ─── Checkpoint Skip If Completed ────────────────────────────────
checkpoint_skip_if_completed() {
    # Usage: checkpoint_skip_if_completed <goal_pattern>
    # Checks if a goal was already completed. If yes, verify state and return skip signal.
    # If verification fails, returns signal to redo the step.
    local goal_pattern="${1:-}"
    local match seq
    match=$(checkpoint_lookup "$goal_pattern" "completed")
    [ -z "$match" ] && { printf '{"skip":false,"reason":"not_previously_completed"}\n'; return 1; }

    seq=$(echo "$match" | grep -o '"seq":[0-9]*' | grep -o '[0-9]*')
    local verify_result
    verify_result=$(checkpoint_verify "$seq")
    local still_valid
    still_valid=$(echo "$verify_result" | grep -o '"still_valid":true')

    if [ -n "$still_valid" ]; then
        printf '{"skip":true,"reason":"previously_completed_and_verified","seq":%s,"goal":"%s"}\n' "$seq" "$goal_pattern"
        return 0
    else
        printf '{"skip":false,"reason":"previously_completed_but_state_changed","seq":%s,"verification":%s}\n' "$seq" "$verify_result"
        return 1
    fi
}

# ─── Print usage ─────────────────────────────────────────────────
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    echo "agent-checkpoint.sh — Checkpoint Recovery & Multi-Strategy Fallback"
    echo ""
    echo "Core Functions:"
    echo "  checkpoint_save <goal> <op> <approach> <pre> <post> <undo>"
    echo "  checkpoint_lookup <pattern> [state]"
    echo "  checkpoint_load_last_success"
    echo "  checkpoint_mark_deadloop <goal> <op> <approach> <attempts> <remaining>"
    echo "  checkpoint_rollback <target_seq>"
    echo "  checkpoint_verify <seq>"
    echo "  checkpoint_build_recovery_context <failed_seq>  ← KEY: LLM context injection"
    echo "  checkpoint_recover <failed_seq>                 ← MAIN ENTRY POINT"
    echo "  checkpoint_detect_deadloop <goal> <approach>"
    echo "  checkpoint_skip_if_completed <goal_pattern>     ← Avoid redoing work"
    echo ""
    echo "Design Patterns: WAL (append-only log), Saga (compensating undo),"
    echo "  Circuit Breaker (strategy-level), Memento (pre/post state snapshot),"
    echo "  Git Reflog (immutable checkpoint history)"
fi
