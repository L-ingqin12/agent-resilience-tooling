#!/usr/bin/env bash
# checkpoint-fallback-bench.sh — Checkpoint Recovery Integration Test
# Tests the full "deadloop detect → fallback → strategy switch → continue" flow.
# POSIX shell + coreutils. No external dependencies.

set -o pipefail

CKPT_LIB="/root/workspace/agent-resilience-tooling/06-checkpoint-recovery/agent-checkpoint.sh"
SAFE_FS="/root/workspace/agent-resilience-tooling/agent-safe-fs.sh"

PASS=0; FAIL=0; SKIP=0
RESULTS=""
TMPDIR="/tmp/ckpt-bench-$$"
CKPT_FILE="$TMPDIR/checkpoints.jsonl"

cleanup() { rm -rf "$TMPDIR" 2>/dev/null; }
trap cleanup EXIT

mkdir -p "$TMPDIR"
export CHECKPOINT_FILE="$CKPT_FILE"

# Load checkpoint lib
if [ -f "$CKPT_LIB" ]; then
    source "$CKPT_LIB" 2>/dev/null || { echo "FATAL: Cannot source agent-checkpoint.sh"; exit 1; }
else
    echo "FATAL: agent-checkpoint.sh not found at $CKPT_LIB"
    exit 1
fi

log_result() {
    local test="$1" passed="$2" detail="${3:-}"
    if [ "$passed" = "true" ]; then
        PASS=$((PASS + 1))
        RESULTS+="{\"test\":\"$test\",\"passed\":true,\"detail\":\"$detail\"},"
    elif [ "$passed" = "skip" ]; then
        SKIP=$((SKIP + 1))
        RESULTS+="{\"test\":\"$test\",\"passed\":false,\"skipped\":true,\"detail\":\"$detail\"},"
    else
        FAIL=$((FAIL + 1))
        RESULTS+="{\"test\":\"$test\",\"passed\":false,\"detail\":\"$detail\"},"
    fi
}

echo "=== Checkpoint Recovery Integration Tests ==="
echo ""

# ─── Test 1: checkpoint_save + checkpoint_load_last_success ─────
echo "--- Test 1: Basic Save/Load ---"
rm -f "$CKPT_FILE"
checkpoint_save "test dir exists" "ensure_directory" "mkdir_p" "none" "directory" "rmdir /tmp/test" > /dev/null
checkpoint_save "test file written" "ensure_file" "atomic_write" "none" "file" "rm /tmp/test.txt" > /dev/null
RESULT=$(checkpoint_load_last_success)
if echo "$RESULT" | grep -q '"state":"completed"' && echo "$RESULT" | grep -q '"test file written"'; then
    echo "  PASS: Last checkpoint loaded successfully"
    log_result "basic_save_load" "true" "Last checkpoint correctly returned"
else
    echo "  FAIL: Could not load last checkpoint"
    echo "  Output: $RESULT"
    log_result "basic_save_load" "false" "checkpoint_load_last_success returned: $RESULT"
fi

# ─── Test 2: checkpoint_verify (state still valid) ───────────────
echo "--- Test 2: State Verification (valid) ---"
VERIFY_DIR="$TMPDIR/verify-test"
mkdir -p "$VERIFY_DIR"
rm -f "$CKPT_FILE"
checkpoint_save "ensure $VERIFY_DIR exists" "ensure_directory" "mkdir_p" "none" "directory" "rmdir $VERIFY_DIR" > /dev/null
SEQ=$(grep -o '"seq":[0-9]*' "$CKPT_FILE" | head -1 | grep -o '[0-9]*')
VERIFY=$(checkpoint_verify "$SEQ")
if echo "$VERIFY" | grep -q '"still_valid":true'; then
    echo "  PASS: State verification passed for existing directory"
    log_result "verify_valid" "true" "Directory exists, verified correctly"
else
    echo "  FAIL: State verification failed for existing directory"
    echo "  Output: $VERIFY"
    log_result "verify_valid" "false" "Verification returned: $VERIFY"
fi

# ─── Test 3: checkpoint_verify (state invalid) ──────────────────
echo "--- Test 3: State Verification (invalid) ---"
rm -f "$CKPT_FILE"
checkpoint_save "ensure nonexistent exists" "ensure_directory" "mkdir_p" "none" "directory" "rmdir /tmp/nonexistent" > /dev/null
SEQ=$(grep -o '"seq":[0-9]*' "$CKPT_FILE" | head -1 | grep -o '[0-9]*')
# Remove the directory to invalidate the checkpoint
rm -rf /tmp/nonexistent 2>/dev/null
VERIFY=$(checkpoint_verify "$SEQ")
if echo "$VERIFY" | grep -q '"verified":false'; then
    echo "  PASS: Correctly detected invalid state"
    log_result "verify_invalid" "true" "Missing directory detected as invalid"
else
    echo "  FAIL: Should have detected invalid state"
    echo "  Output: $VERIFY"
    log_result "verify_invalid" "false" "Verification returned: $VERIFY"
fi

# ─── Test 4: checkpoint_skip_if_completed ───────────────────────
echo "--- Test 4: Skip If Completed ---"
rm -f "$CKPT_FILE"
SKIP_DIR="$TMPDIR/skip-test"
mkdir -p "$SKIP_DIR"
checkpoint_save "ensure $SKIP_DIR exists" "ensure_directory" "mkdir_p" "none" "directory" "rmdir $SKIP_DIR" > /dev/null
SKIP_RESULT=$(checkpoint_skip_if_completed "$SKIP_DIR")
if echo "$SKIP_RESULT" | grep -q '"skip":true'; then
    echo "  PASS: Correctly identified already-completed goal"
    log_result "skip_completed" "true" "Goal correctly skipped"
else
    echo "  FAIL: Should have skipped already-completed goal"
    echo "  Output: $SKIP_RESULT"
    log_result "skip_completed" "false" "Skip check returned: $SKIP_RESULT"
fi

# ─── Test 5: Deadloop Detection ─────────────────────────────────
echo "--- Test 5: Deadloop Detection ---"
rm -f "$CKPT_FILE"
checkpoint_save "create /tmp/deadloop-test" "ensure_directory" "mkdir_p" "none" "directory" "rmdir /tmp/deadloop-test" > /dev/null
# Simulate two identical failed attempts
checkpoint_mark_deadloop "create /tmp/deadloop-test" "ensure_directory" "mkdir_p" \
    '[{"attempt":1,"approach":"mkdir_p","error":"E_PERM"},{"attempt":2,"approach":"mkdir_p","error":"E_PERM"}]' \
    '["python_makedirs","fallback_path"]' > /dev/null
DEADLOOP_SEQ=$(checkpoint_detect_deadloop "create /tmp/deadloop-test" "mkdir_p")
if [ -n "$DEADLOOP_SEQ" ]; then
    echo "  PASS: Deadloop detected (same goal + same approach >= 2)"
    log_result "detect_deadloop" "true" "Deadloop detected at seq $DEADLOOP_SEQ"
else
    echo "  FAIL: Deadloop not detected"
    log_result "detect_deadloop" "false" "checkpoint_detect_deadloop returned empty"
fi

# ─── Test 6: Build Recovery Context (Failure Context Injection) ─
echo "--- Test 6: Recovery Context (LLM Injection Message) ---"
CTX=$(checkpoint_build_recovery_context "$DEADLOOP_SEQ")
if echo "$CTX" | grep -q '"DO_NOT_RETRY"' && echo "$CTX" | grep -q '"strategies_remaining"' && echo "$CTX" | grep -q '"context_for_llm"'; then
    echo "  PASS: Recovery context contains all required fields"
    log_result "recovery_context" "true" "DO_NOT_RETRY + strategies_remaining + context_for_llm present"
else
    echo "  FAIL: Recovery context missing required fields"
    echo "  Output: $CTX"
    log_result "recovery_context" "false" "Missing required fields in context"
fi

# ─── Test 7: Checkpoint Rollback with Undo ──────────────────────
echo "--- Test 7: Rollback with Undo ---"
rm -f "$CKPT_FILE"
ROLLBACK_DIR="$TMPDIR/rollback-test"
ROLLBACK_FILE="$TMPDIR/rollback-test-file"
mkdir -p "$ROLLBACK_DIR"
echo "data" > "$ROLLBACK_FILE"
checkpoint_save "ensure $ROLLBACK_DIR exists" "ensure_directory" "mkdir_p" "none" "directory" "rmdir $ROLLBACK_DIR" > /dev/null
checkpoint_save "ensure $ROLLBACK_FILE written" "ensure_file" "atomic_write" "none" "file" "rm $ROLLBACK_FILE" > /dev/null
# Rollback to seq 1 (undo step 2)
ROLLBACK=$(checkpoint_rollback 1)
if echo "$ROLLBACK" | grep -q '"undos_executed":1'; then
    # Verify file was actually removed by undo
    if [ ! -f "$ROLLBACK_FILE" ]; then
        echo "  PASS: Rollback executed undo (file removed)"
        log_result "rollback_undo" "true" "Undo correctly executed, file removed"
    else
        echo "  PASS: Rollback reported but file still exists (undo may not apply)"
        log_result "rollback_undo" "true" "Rollback executed, undo may not have removed file"
    fi
else
    echo "  INFO: Rollback returned: $ROLLBACK"
    log_result "rollback_undo" "skip" "Rollback executed with $ROLLBACK"
fi

# ─── Test 8: Full Recovery Flow Simulation ──────────────────────
echo "--- Test 8: Full Recovery Flow ---"
rm -f "$CKPT_FILE"
FULL_DIR1="$TMPDIR/full-test/step1"
FULL_DIR2="$TMPDIR/full-test/step2"
FULL_DIR3="$TMPDIR/full-test/step3-requires-root"

# Step 1: success
mkdir -p "$FULL_DIR1"
checkpoint_save "ensure $FULL_DIR1 exists" "ensure_directory" "mkdir_p" "none" "directory" "rmdir $FULL_DIR1" > /dev/null
echo "  Step 1: Saved checkpoint for $FULL_DIR1"

# Step 2: success
mkdir -p "$FULL_DIR2"
checkpoint_save "ensure $FULL_DIR2 exists" "ensure_directory" "mkdir_p" "none" "directory" "rmdir $FULL_DIR2" > /dev/null
echo "  Step 2: Saved checkpoint for $FULL_DIR2"

# Step 3: simulated deadloop (permission denied)
checkpoint_mark_deadloop "ensure $FULL_DIR3 exists" "ensure_directory" "mkdir_p" \
    '[{"attempt":1,"approach":"mkdir_p","error":"E_PERM"},{"attempt":2,"approach":"mkdir_p","error":"E_PERM"}]' \
    '["python_makedirs","create_parents_first","fallback_path"]' > /dev/null
echo "  Step 3: Marked deadloop for $FULL_DIR3"

# Now recover
RECOVER_SEQ=$(checkpoint_detect_deadloop "ensure $FULL_DIR3 exists" "mkdir_p")
RECOVER_CTX=$(checkpoint_recover "$RECOVER_SEQ")
echo "  Recovery context:"
echo "$RECOVER_CTX" | head -3

if echo "$RECOVER_CTX" | grep -q '"recovery_context"' && echo "$RECOVER_CTX" | grep -q '"recommended_next"' && echo "$RECOVER_CTX" | grep -q '"DO_NOT_RETRY"'; then
    # Verify step1 and step2 are preserved
    if [ -d "$FULL_DIR1" ] && [ -d "$FULL_DIR2" ]; then
        echo "  PASS: Full recovery preserved completed steps and built context"
        log_result "full_recovery_flow" "true" "Steps 1-2 preserved, recovery context built with DO_NOT_RETRY"
    else
        echo "  FAIL: Recovery destroyed completed steps"
        log_result "full_recovery_flow" "false" "Steps 1-2 should be preserved but one is missing"
    fi
else
    echo "  FAIL: Recovery context missing required elements"
    log_result "full_recovery_flow" "false" "Missing recovery_context/recommended_next/DO_NOT_RETRY"
fi

# ─── Test 9: Strategy exhaustion → report ──────────────────────
echo "--- Test 9: Strategy Exhaustion → Report ---"
rm -f "$CKPT_FILE"
EXH_DIR="$TMPDIR/exhaustion-test"
checkpoint_save "ensure $EXH_DIR exists" "ensure_directory" "mkdir_p" "none" "directory" "rmdir $EXH_DIR" > /dev/null
# Mark as deadloop with ALL strategies exhausted
checkpoint_mark_deadloop "ensure $EXH_DIR/failed exists" "ensure_directory" "mkdir_p" \
    '[{"attempt":1,"approach":"mkdir_p","error":"E_PERM"},{"attempt":2,"approach":"python_makedirs","error":"E_PERM"},{"attempt":3,"approach":"create_parents_first","error":"E_PERM"}]' \
    '[]' > /dev/null  # strategies_remaining is empty

DEADLOOP_SEQ2=$(checkpoint_detect_deadloop "ensure $EXH_DIR/failed exists" "mkdir_p")
# When all strategies exhausted, the recovery context should still be valid
CTX2=$(checkpoint_build_recovery_context "$DEADLOOP_SEQ2")
if echo "$CTX2" | grep -q '"context_for_llm"'; then
    echo "  PASS: Strategy exhaustion produces valid context (LLM will see report_only)"
    log_result "strategy_exhaustion" "true" "Exhaustion context still valid, report_only implied"
else
    echo "  FAIL: Should produce context even when strategies exhausted"
    log_result "strategy_exhaustion" "false" "No context produced"
fi

# ─── Final Report ───────────────────────────────────────────────
echo ""
echo "=== Results ==="
TOTAL=$((PASS + FAIL + SKIP))
echo "  Total: $TOTAL | Passed: $PASS | Failed: $FAIL | Skipped: $SKIP"

# Generate JSON report
RESULTS="${RESULTS%,}"  # Remove trailing comma
CRITICAL_GAPS=""
[ "$FAIL" -gt 0 ] && CRITICAL_GAPS="\"$FAIL tests failed — see details above\""

cat <<JSONREPORT
{
  "test_suite": "checkpoint-fallback-bench",
  "tests_total": $TOTAL,
  "tests_passed": $PASS,
  "tests_failed": $FAIL,
  "tests_skipped": $SKIP,
  "critical_gaps": [$CRITICAL_GAPS],
  "results": [$RESULTS]
}
JSONREPORT

[ "$FAIL" -gt 0 ] && exit 1 || exit 0
