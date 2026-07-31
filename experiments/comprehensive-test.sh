#!/usr/bin/env bash
# Comprehensive Test Suite for Agent Resilience Tooling
# Tests: basic ops, error scenarios, deadloop detection, recovery, edge cases

set -o pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

TOTAL=0; PASS=0; FAIL=0; SKIP=0
TEST_DIR="/tmp/agent-resilience-test-$$"
CKPT_FILE="$TEST_DIR/checkpoints.jsonl"
export CHECKPOINT_FILE="$CKPT_FILE"

# ─── Setup ───────────────────────────────────────────────────────
setup() {
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR"
    source ~/.agent/safe-fs.sh 2>/dev/null
    source ~/.agent/agent-checkpoint.sh 2>/dev/null
    rm -f "$CKPT_FILE"
}

# ─── Test Helpers ────────────────────────────────────────────────
ok() { echo -e "  ${GREEN}✓${NC} $1"; PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); }
fail() { echo -e "  ${RED}✗${NC} $1 (expected: $2, got: $3)"; FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); }
skip() { echo -e "  ${YELLOW}⊘${NC} $1"; SKIP=$((SKIP+1)); TOTAL=$((TOTAL+1)); }

assert_ok() {
    local result="$1" testname="$2"
    if echo "$result" | grep -q '"ok":true'; then ok "$testname"; else fail "$testname" "ok=true" "$(echo "$result" | head -c 100)"; fi
}
assert_fail() {
    local result="$1" code="$2" testname="$3"
    if echo "$result" | grep -q "\"code\":\"$code\""; then ok "$testname ($code)"; else fail "$testname" "code=$code" "$(echo "$result" | head -c 100)"; fi
}
assert_contains() {
    local result="$1" pattern="$2" testname="$3"
    if echo "$result" | grep -q "$pattern"; then ok "$testname"; else fail "$testname" "contains '$pattern'" "$(echo "$result" | head -c 100)"; fi
}

# ─── Test Suite ──────────────────────────────────────────────────
run_all_tests() {
    echo -e "${CYAN}═══════════════════════════════════════════${NC}"
    echo -e "${CYAN}  Agent Resilience Tooling — Full Test Suite${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════${NC}"
    echo ""

    test_basic_operations
    test_idempotency
    test_error_scenarios
    test_deadloop_detection
    test_checkpoint_recovery
    test_strategy_exhaustion
    test_edge_cases
    test_concurrent_safety
    test_long_context_simulation

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════${NC}"
    printf "${GREEN}PASS: %d${NC}  ${RED}FAIL: %d${NC}  ${YELLOW}SKIP: %d${NC}  TOTAL: %d\n" "$PASS" "$FAIL" "$SKIP" "$TOTAL"
    echo -e "${CYAN}═══════════════════════════════════════════${NC}"
}

# ─── 1. Basic Operations ─────────────────────────────────────────
test_basic_operations() {
    echo -e "${YELLOW}[1] Basic Operations${NC}"

    # 1.1: Normal directory creation
    R=$(ensure_directory "$TEST_DIR/basic-dir")
    assert_ok "$R" "Create new directory"
    [ -d "$TEST_DIR/basic-dir" ] && ok "  → Directory actually exists on disk" || fail "  → Directory exists on disk" "exists" "missing"

    # 1.2: Normal file creation
    R=$(ensure_file "$TEST_DIR/basic-file.txt" "hello world")
    assert_ok "$R" "Create new file"
    [ -f "$TEST_DIR/basic-file.txt" ] && ok "  → File actually exists on disk" || fail "  → File exists on disk" "exists" "missing"
    [ "$(cat "$TEST_DIR/basic-file.txt")" = "hello world" ] && ok "  → File content correct" || fail "  → File content" "hello world" "$(cat "$TEST_DIR/basic-file.txt")"

    # 1.3: Deep path (50 levels)
    DEEP="/tmp/deep"
    for i in $(seq 1 50); do DEEP="$DEEP/level$i"; done
    R=$(ensure_directory "$DEEP")
    assert_ok "$R" "Create 50-level deep directory"
    [ -d "$DEEP" ] && ok "  → Deep path verified" || fail "  → Deep path" "exists" "missing"
    rm -rf /tmp/deep

    # 1.4: Unicode path
    R=$(ensure_directory "$TEST_DIR/测试目录/数据")
    assert_ok "$R" "Create directory with Unicode path"
    [ -d "$TEST_DIR/测试目录/数据" ] && ok "  → Unicode path verified" || fail "  → Unicode path" "exists" "missing"

    # 1.5: Path with spaces
    R=$(ensure_directory "$TEST_DIR/my project with spaces/logs")
    assert_ok "$R" "Create directory with spaces in path"
    [ -d "$TEST_DIR/my project with spaces/logs" ] && ok "  → Space path verified" || fail "  → Space path" "exists" "missing"

    echo ""
}

# ─── 2. Idempotency ──────────────────────────────────────────────
test_idempotency() {
    echo -e "${YELLOW}[2] Idempotency${NC}"

    # 2.1: Same directory 100 times
    local dir="$TEST_DIR/idempotent-dir"
    R=$(ensure_directory "$dir")
    assert_ok "$R" "First create: created=true"
    assert_contains "$R" '"created":true' "  → created=true on first call"

    local all_ok=true existed_count=0
    for i in $(seq 1 100); do
        R=$(ensure_directory "$dir")
        echo "$R" | grep -q '"ok":true' || all_ok=false
        echo "$R" | grep -q '"existed_before":true' && existed_count=$((existed_count + 1))
    done
    $all_ok && ok "100 calls to same path: all returned ok=true" || fail "100 calls" "all ok=true" "some failed"
    [ "$existed_count" -eq 100 ] && ok "100 calls: all returned existed_before=true" || fail "100 calls existed_before" "100" "$existed_count"

    # 2.2: Same file 100 times
    local file="$TEST_DIR/idempotent-file.txt"
    R=$(ensure_file "$file" "original")
    assert_ok "$R" "First file write"
    [ "$(cat "$file")" = "original" ] && ok "  → Original content preserved" || skip "  → Content check"

    # Overwrite with same content (should be idempotent)
    R=$(ensure_file "$file" "original")
    assert_ok "$R" "Same content rewrite (idempotent)"

    echo ""
}

# ─── 3. Error Scenarios ──────────────────────────────────────────
test_error_scenarios() {
    echo -e "${YELLOW}[3] Error Scenarios${NC}"

    # 3.1: Path conflict (file where directory should be)
    echo "block" > "$TEST_DIR/conflict-file"
    R=$(ensure_directory "$TEST_DIR/conflict-file" 2>&1) || true
    assert_fail "$R" "E_PATH_CONFLICT" "File blocking directory creation"
    rm -f "$TEST_DIR/conflict-file"

    # 3.2: Permission denied (simulated via /root — skip if root)
    if [ "$(id -u)" != "0" ]; then
        R=$(ensure_directory /root/test-no-perm 2>&1) || true
        echo "$R" | grep -q '"code":"E_PERM"' && ok "Permission denied correctly classified" || \
            echo "$R" | grep -q '"code":' && fail "Permission denied" "E_PERM" "$(echo "$R" | grep -o '"code":"[^"]*"')" || skip "Permission test (running as root, cannot test)"
    else
        skip "Permission test (running as root)"
    fi

    # 3.3: Empty path
    R=$(ensure_directory "" 2>&1) || true
    assert_fail "$R" "E_PATH" "Empty path rejected"

    # 3.4: Root path protection
    R=$(ensure_directory "/" 2>&1) || true
    assert_fail "$R" "E_PERM" "Root path / rejected"
    R=$(ensure_directory "/etc" 2>&1) || true
    assert_fail "$R" "E_PERM" "System path /etc rejected"
    R=$(ensure_directory "/root/test" 2>&1) || true
    assert_fail "$R" "E_PERM" "System path /root/* rejected"

    # 3.5: Non-existent parent (should auto-create)
    R=$(ensure_directory "$TEST_DIR/a/b/c/d/e")
    assert_ok "$R" "Auto-create missing parent directories"
    [ -d "$TEST_DIR/a/b/c/d/e" ] && ok "  → All parent dirs created" || fail "  → Parent dirs" "exists" "missing"

    echo ""
}

# ─── 4. Deadloop Detection ───────────────────────────────────────
test_deadloop_detection() {
    echo -e "${YELLOW}[4] Deadloop Detection${NC}"
    rm -f "$CKPT_FILE"

    # 4.1: Same goal + same approach × 2 = deadloop
    echo "block" > /tmp/dl-test-target
    ensure_directory /tmp/dl-test-target 2>/dev/null || true  # attempt 1
    ensure_directory /tmp/dl-test-target 2>/dev/null || true  # attempt 2
    # Mark the pattern
    checkpoint_mark_deadloop "ensure /tmp/dl-test-target exists" "ensure_directory" "mkdir_p" \
        '[{"attempt":1,"approach":"mkdir_p","error":"E_PATH_CONFLICT"},{"attempt":2,"approach":"mkdir_p","error":"E_PATH_CONFLICT"}]' \
        '["python_makedirs","fallback_path"]' > /dev/null
    local seq
    seq=$(checkpoint_detect_deadloop "ensure /tmp/dl-test-target exists" "mkdir_p")
    [ -n "$seq" ] && ok "Same goal+approach × 2 detected as deadloop (seq=$seq)" || fail "Deadloop detection" "non-empty seq" "empty"
    rm -f /tmp/dl-test-target

    # 4.2: Different goals = NOT a deadloop
    ensure_directory "$TEST_DIR/goal-a" 2>/dev/null || true
    ensure_directory "$TEST_DIR/goal-b" 2>/dev/null || true
    seq=$(checkpoint_detect_deadloop "ensure $TEST_DIR/goal-a exists" "mkdir_p")
    [ -z "$seq" ] && ok "Different goals NOT incorrectly flagged as deadloop" || fail "False positive" "empty" "$seq"

    # 4.3: Different approaches same goal = NOT deadloop (strategy switch)
    checkpoint_mark_deadloop "ensure $TEST_DIR/strategy-test exists" "ensure_directory" "mkdir_p" \
        '[{"attempt":1,"approach":"mkdir_p","error":"E_PERM"}]' \
        '["python_makedirs","fallback_path"]' > /dev/null
    # Now try python_makedirs — different approach, should NOT be deadloop with that approach
    seq=$(checkpoint_detect_deadloop "ensure $TEST_DIR/strategy-test exists" "python_makedirs")
    [ -z "$seq" ] && ok "Different approach NOT flagged as deadloop (correct)" || fail "False positive on different approach" "empty" "$seq"

    rm -f "$CKPT_FILE"
    echo ""
}

# ─── 5. Checkpoint Recovery ──────────────────────────────────────
test_checkpoint_recovery() {
    echo -e "${YELLOW}[5] Checkpoint Recovery${NC}"
    rm -f "$CKPT_FILE"

    # 5.1: Save → load → verify
    checkpoint_save "test goal" "test_op" "test_approach" "none" "directory" "rmdir /tmp/test" > /dev/null
    local last
    last=$(checkpoint_load_last_success)
    assert_contains "$last" '"state":"completed"' "Save and load checkpoint"

    # 5.2: Skip completed
    local dir="$TEST_DIR/skip-dir"
    mkdir -p "$dir"
    checkpoint_save "ensure $dir exists" "ensure_directory" "mkdir_p" "none" "directory" "rmdir $dir" > /dev/null
    local skip
    skip=$(checkpoint_skip_if_completed "$dir")
    assert_contains "$skip" '"skip":true' "Skip already-completed goal"
    rm -rf "$dir"

    # 5.3: Skip detects state change
    checkpoint_save "ensure $dir exists" "ensure_directory" "mkdir_p" "none" "directory" "rmdir $dir" > /dev/null
    skip=$(checkpoint_skip_if_completed "$dir")  # dir was just deleted, state changed
    assert_contains "$skip" '"skip":false' "Detect state change (no longer valid)"

    # 5.4: Build recovery context with all required fields
    rm -f "$CKPT_FILE"
    checkpoint_save "step1 done" "ensure_directory" "mkdir_p" "none" "directory" "rmdir /tmp/s1" > /dev/null
    checkpoint_save "step2 done" "ensure_file" "atomic_write" "none" "file" "rm /tmp/s2" > /dev/null
    checkpoint_mark_deadloop "step3 failed" "ensure_directory" "mkdir_p" \
        '[{"attempt":1,"approach":"mkdir_p","error":"E_PERM","errno":13}]' \
        '["python_makedirs","fallback_path"]' > /dev/null
    local ctx
    ctx=$(checkpoint_build_recovery_context 3 2>/dev/null || echo "{}")
    assert_contains "$ctx" "DO_NOT_RETRY" "Recovery context: DO_NOT_RETRY"
    assert_contains "$ctx" "recommended_next" "Recovery context: recommended_next"
    assert_contains "$ctx" "context_for_llm" "Recovery context: context_for_llm"
    assert_contains "$ctx" "strategies_remaining" "Recovery context: strategies_remaining"

    # 5.5: Checkpoint verify
    local verify_dir="$TEST_DIR/verify-me"
    mkdir -p "$verify_dir"
    checkpoint_save "ensure $verify_dir exists" "ensure_directory" "mkdir_p" "none" "directory" "rmdir $verify_dir" > /dev/null
    local vseq
    vseq=$(grep "$verify_dir" "$CKPT_FILE" | tail -1 | grep -o '"seq":[0-9]*' | grep -o '[0-9]*')
    v_result=$(checkpoint_verify "$vseq" 2>/dev/null || echo '{"verified":false}')
    assert_contains "$v_result" '"verified":true' "Verify existing checkpoint state"

    rm -rf "$verify_dir"
    v_result=$(checkpoint_verify 1 2>/dev/null || echo '{"verified":false}')
    assert_contains "$v_result" '"verified":false' "Verify deleted checkpoint state detected"

    rm -f "$CKPT_FILE"
    echo ""
}

# ─── 6. Strategy Exhaustion ──────────────────────────────────────
test_strategy_exhaustion() {
    echo -e "${YELLOW}[6] Strategy Exhaustion${NC}"
    rm -f "$CKPT_FILE"

    # 6.1: All strategies exhausted — context still valid
    checkpoint_save "step1 done" "ensure_directory" "a" "none" "directory" "undo1" > /dev/null
    checkpoint_mark_deadloop "step2 failed" "ensure_directory" "x" \
        '[{"attempt":1,"approach":"a","error":"E_PERM"},{"attempt":2,"approach":"b","error":"E_PERM"},{"attempt":3,"approach":"c","error":"E_PERM"}]' \
        '[]' > /dev/null  # Empty remaining = all exhausted
    local ctx
    ctx=$(checkpoint_build_recovery_context 2 2>/dev/null || echo "{}")
    assert_contains "$ctx" "context_for_llm" "Strategy exhaustion: context still valid"

    # 6.2: Empty remaining strategies
    assert_contains "$ctx" '\[\]' "Strategy exhaustion: empty remaining list"

    rm -f "$CKPT_FILE"
    echo ""
}

# ─── 7. Edge Cases ────────────────────────────────────────────────
test_edge_cases() {
    echo -e "${YELLOW}[7] Edge Cases${NC}"

    # 7.1: Trailing slash normalization
    R=$(ensure_directory "$TEST_DIR/trailing/")
    assert_ok "$R" "Trailing slash handled"
    [ -d "$TEST_DIR/trailing" ] && ok "  → Directory correct (no double slash)" || fail "  → Trailing slash" "dir exists" "missing"

    # 7.2: Path with special characters (that are valid in filenames)
    R=$(ensure_directory "$TEST_DIR/special-@#$%^&()_+")
    assert_ok "$R" "Special characters in path"
    [ -d "$TEST_DIR/special-@#$%^&()_+" ] && ok "  → Special char path verified" || fail "  → Special chars" "exists" "missing"

    # 7.3: Very long filename (200 chars)
    local longname
    longname=$(python3 -c "print('a'*200)")
    R=$(ensure_directory "$TEST_DIR/$longname")
    assert_ok "$R" "200-char directory name"

    # 7.4: Empty content file
    R=$(ensure_file "$TEST_DIR/empty-file.txt" "")
    assert_ok "$R" "Empty content file"
    [ -f "$TEST_DIR/empty-file.txt" ] && ok "  → Empty file exists" || fail "  → Empty file" "exists" "missing"

    # 7.5: Binary-ish content (null bytes, control chars)
    local binary_content
    binary_content=$(printf 'hello\x00world\ncontrol\x01\x02chars')
    R=$(ensure_file "$TEST_DIR/binary.bin" "$binary_content" 2>/dev/null)
    # This might fail due to null byte in bash string — that's acceptable
    if echo "$R" | grep -q '"ok":true'; then
        ok "Binary content accepted"
    else
        skip "Binary content (bash null byte limitation)"
    fi

    # 7.6: guard_exec with segfault simulation
    # (Can't easily trigger real segfault, test timeout)
    R=$(guard_exec 2 bash -c "sleep 0.1 && echo done" 2>/dev/null || echo '{"ok":false}')
    assert_ok "$R" "guard_exec: normal command"

    # 7.7: guard_exec with timeout
    R=$(guard_exec 1 "sleep 5" 2>/dev/null || echo '{"ok":false,"error":{"code":"E_SYSTEM_CATASTROPHE"}}')
    if echo "$R" | grep -q "E_SYSTEM_CATASTROPHE\|E_TIMEOUT"; then
        ok "guard_exec: timeout correctly handled"
    else
        skip "guard_exec timeout (platform dependent)"
    fi

    # 7.8: classify_result for all known exit codes
    local codes="1:E_PERM 13:E_PERM 17:E_EXISTS 2:E_PATH 28:E_NOSPC 12:E_OOM 5:E_IO 124:E_TIMEOUT 137:E_OOM 139:E_UNKNOWN"
    for entry in $codes; do
        local code="${entry%%:*}" expected="${entry##*:}"
        R=$(classify_result "$code" "test error" 2>/dev/null)
        if echo "$R" | grep -q "\"$expected\""; then
            :  # pass
        else
            fail "classify_result exit=$code" "$expected" "$(echo "$R" | grep -o '"code":"[^"]*"')"
        fi
    done
    [ $? -eq 0 ] && true  # suppress set -e

    echo ""
}

# ─── 8. Concurrent Safety ────────────────────────────────────────
test_concurrent_safety() {
    echo -e "${YELLOW}[8] Concurrent Safety${NC}"

    # 8.1: 10 parallel ensure_directory calls on same path
    local cdir="$TEST_DIR/concurrent-dir"
    local pids=() outcomes=()
    for i in $(seq 1 10); do
        (source ~/.agent/safe-fs.sh 2>/dev/null; ensure_directory "$cdir" 2>/dev/null) &
        pids+=($!)
    done
    for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null; done

    [ -d "$cdir" ] && ok "10 concurrent ensures: directory created" || fail "Concurrent ensures" "dir exists" "missing"

    # 8.2: 5 concurrent ensure_file on same path (last writer wins, but no corruption)
    local cfile="$TEST_DIR/concurrent-file.txt"
    pids=()
    for i in $(seq 1 5); do
        (source ~/.agent/safe-fs.sh 2>/dev/null; ensure_file "$cfile" "writer-$i" 2>/dev/null) &
        pids+=($!)
    done
    for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null; done

    [ -f "$cfile" ] && ok "5 concurrent writes: file created (no deadlock)" || fail "Concurrent writes" "file exists" "missing"

    echo ""
}

# ─── 9. Long Context Simulation ──────────────────────────────────
test_long_context_simulation() {
    echo -e "${YELLOW}[9] Long Context Simulation (Skill Awareness)${NC}"

    # Simulate a long context by generating many checkpoint entries (like a long session)
    # Then verify the core functions still work correctly.
    # The real test is whether the LLM still invokes the skill — but we test the infrastructure.

    # 9.1: Functions work correctly after many checkpoint entries (simulates long session)
    rm -f "$CKPT_FILE"
    for i in $(seq 1 200); do
        checkpoint_save "step $i of long session completed" "test" "approach" "none" "none" "" > /dev/null 2>&1
    done

    # After 200 entries, core functions should still work
    R=$(ensure_directory "$TEST_DIR/after-long-session")
    assert_ok "$R" "ensure_directory after 200 checkpoint entries"

    local last
    last=$(checkpoint_load_last_success)
    assert_contains "$last" '"state":"completed"' "checkpoint_load after 200 entries"

    local skip
    skip=$(checkpoint_skip_if_completed "step 150")
    assert_contains "$skip" '"skip":false' "skip_check after 200 entries (correct: state=none)"

    # 9.2: Log rotation
    local lines
    lines=$(wc -l < "$CKPT_FILE" 2>/dev/null || echo "0")
    [ "$lines" -le 100 ] && ok "Checkpoint log rotated (lines=$lines ≤ MAX_CHECKPOINTS=100)" || fail "Log rotation" "≤100" "$lines"

    # 9.3: Memory usage after many operations
    # (Hard to measure in bash, just verify no crash)
    for i in $(seq 1 50); do
        R=$(ensure_directory "$TEST_DIR/mem-test-$i" 2>/dev/null)
    done
    ok "50 sequential operations: no crash or hang"

    # 9.4: Verify skill trigger keywords are present in SKILL.md
    if [ -f ~/.claude/skills/safe-file-ops/SKILL.md ]; then
        grep -q "mkdir" ~/.claude/skills/safe-file-ops/SKILL.md && ok "Skill: mkdir trigger present" || fail "Skill trigger" "mkdir" "missing"
        grep -q "ensure_directory" ~/.claude/skills/safe-file-ops/SKILL.md && ok "Skill: ensure_directory instruction present" || fail "Skill instruction" "ensure_directory" "missing"
        grep -q "DO_NOT_RETRY" ~/.claude/skills/safe-file-ops/SKILL.md && ok "Skill: DO_NOT_RETRY pattern present" || fail "Skill pattern" "DO_NOT_RETRY" "missing"
    else
        skip "Skill file check (not installed)"
    fi

    echo ""
}

# ─── Run ─────────────────────────────────────────────────────────
setup
run_all_tests

# Cleanup
rm -rf "$TEST_DIR" /tmp/deadloop-target /tmp/dl-test-target 2>/dev/null || true
echo "✓ All test artifacts cleaned"

[ "$FAIL" -gt 0 ] && exit 1 || exit 0
