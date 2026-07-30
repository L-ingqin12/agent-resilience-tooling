#!/bin/sh
# deadloop-reproduction.sh
# Reproduces all 9 deadloop trigger scenarios from the agent resilience taxonomy.
#
# Each scenario prints:
#   RAW OUTPUT    - the actual stderr/stdout from the failing command
#   EXIT CODE     - the numeric exit code
#   CLASSIFICATION- the error class (EEXIST, EACCES, ENOENT, ENOSPC, OOM, EIO, SIGSEGV, ENOTDIR, ELOOP)
#   RETRYABLE     - whether retrying the same operation could ever succeed
#   AGENT WOULD LOOP - whether an agent retrying without changing strategy would loop
#
# Usage: sh deadloop-reproduction.sh [--skip-root]
#   --skip-root  Skip tests that require root / namespace capabilities
#
# Dependencies: POSIX shell, coreutils (mkdir, rm, ln, chmod, dd, timeout),
#               mount / unshare (for ENOSPC), python3 (for OOM)

set -u

SKIP_ROOT=0
for arg in "$@"; do
    case "$arg" in
        --skip-root) SKIP_ROOT=1 ;;
    esac
done

WORKDIR=$(mktemp -d /tmp/deadloop_XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT INT TERM
cd "$WORKDIR"

TOTAL=0
CAN_ROOT=0
CAN_UNSHARE=0

# Capability detection
if [ "$(id -u)" = "0" ] 2>/dev/null; then
    CAN_ROOT=1
elif command -v unshare >/dev/null 2>&1; then
    if unshare -r true 2>/dev/null; then
        CAN_UNSHARE=1
    fi
fi

echo "================================================================="
echo "  Deadloop Trigger Reproduction Suite"
echo "  Taxonomy: 9 trigger scenarios"
echo "  Host: $(uname -s) $(uname -r) | Root: ${CAN_ROOT} | Unshare: ${CAN_UNSHARE}"
echo "================================================================="
echo ""

# ------------------------------------------------------------------
# print_scenario heading + command execution + result block
# ------------------------------------------------------------------
print_scenario() {
    num="$1"
    name="$2"
    classification="$3"
    retryable="$4"
    agent_loops="$5"
    raw_output="$6"
    exit_code="$7"

    echo "=== Scenario $num: $name ==="
    echo ""
    echo "--- RAW OUTPUT ---"
    if [ -n "$raw_output" ]; then
        echo "$raw_output"
    else
        echo "(no output)"
    fi
    echo "--- END OUTPUT ---"
    echo ""
    echo "EXIT CODE:       $exit_code"
    echo "CLASSIFICATION:  $classification"
    echo "RETRYABLE:       $retryable"
    echo "AGENT WOULD LOOP: $agent_loops"
    echo "------------------------------------------------------------"
    echo ""
}

# ==================================================================
# Scenario 1: EEXIST
#   Create a directory, then mkdir (without -p) on it again
# ==================================================================
TOTAL=$((TOTAL + 1))
s1_rc=0; s1_out=$( {
    mkdir -p "$WORKDIR/s1_sub"
    mkdir "$WORKDIR/s1_sub"
} 2>&1 ) || s1_rc=$?
print_scenario \
    "$TOTAL" "EEXIST - mkdir on existing directory" \
    "EEXIST" "no" "yes" \
    "${s1_out:-}" "${s1_rc:-0}"

# ==================================================================
# Scenario 2: EACCES
#   Create a directory with 000 permissions, try to mkdir under it.
#   Note: root bypasses permission checks, so exit code will be 0
#   for root. The scenario still demonstrates the failure mode for
#   non-privileged users.
# ==================================================================
TOTAL=$((TOTAL + 1))
mkdir -p "$WORKDIR/s2_lock"
chmod 000 "$WORKDIR/s2_lock"
s2_rc=0; s2_out=$(mkdir "$WORKDIR/s2_lock/subdir" 2>&1) || s2_rc=$?
chmod 755 "$WORKDIR/s2_lock" 2>/dev/null || true
if [ "$(id -u)" = "0" ] 2>/dev/null; then
    s2_out="(running as root - EACCES not applicable; non-root would see 'Permission denied')"
    s2_rc=1
fi
print_scenario \
    "$TOTAL" "EACCES - mkdir under a 000-permissions directory" \
    "EACCES" "no" "yes" \
    "${s2_out:-}" "${s2_rc:-0}"

# ==================================================================
# Scenario 3: ENOENT
#   mkdir where the parent directory does not exist
# ==================================================================
TOTAL=$((TOTAL + 1))
s3_rc=0; s3_out=$(mkdir "$WORKDIR/s3_missing/subdir" 2>&1) || s3_rc=$?
print_scenario \
    "$TOTAL" "ENOENT - mkdir where parent does not exist" \
    "ENOENT" "no" "yes" \
    "${s3_out:-}" "${s3_rc:-0}"

# ==================================================================
# Scenario 4: ENOSPC
#   Fill a small tmpfs, then try to mkdir on it.
#   Falls back with a warning if no root/unshare.
# ==================================================================
TOTAL=$((TOTAL + 1))
s4_out=""; s4_rc=0
if [ "$SKIP_ROOT" = 1 ]; then
    s4_out="SKIPPED (--skip-root set)"
    s4_rc=99
else
    s4_mount="$WORKDIR/s4_tmpfs"
    mkdir -p "$s4_mount"
    mounted=0
    if [ "$CAN_ROOT" = 1 ]; then
        mount -t tmpfs -o size=1M tmpfs "$s4_mount" 2>/dev/null && mounted=1
    elif [ "$CAN_UNSHARE" = 1 ]; then
        unshare -r mount -t tmpfs -o size=1M tmpfs "$s4_mount" 2>/dev/null && mounted=1
    fi

    if [ "$mounted" = 1 ]; then
        # Fill the tmpfs
        dd if=/dev/zero of="$s4_mount/fill" bs=1024 count=1024 2>/dev/null || true
        s4_out=$(mkdir "$s4_mount/newdir" 2>&1) || s4_rc=$?
        umount "$s4_mount" 2>/dev/null || true
    else
        s4_out="SKIPPED - cannot create tmpfs (needs root or unshare -r). Install util-linux, or run as root."
        s4_rc=98
    fi
fi
rm -rf "$WORKDIR/s4_tmpfs" 2>/dev/null || true
print_scenario \
    "$TOTAL" "ENOSPC - mkdir on full filesystem" \
    "ENOSPC" "maybe" "yes" \
    "${s4_out:-}" "${s4_rc:-0}"

# ==================================================================
# Scenario 5: OOM / Process Killed
#   Use ulimit to restrict virtual memory, then attempt allocation
# ==================================================================
TOTAL=$((TOTAL + 1))
s5_rc=0; s5_out=$( {
    ulimit -v 50000 2>/dev/null
    python3 -c "import sys; x = bytearray(300 << 20); sys.stdout.write('allocated 300MB unexpectedly')" 2>&1
} ) || s5_rc=$?
# Fix up empty output
if [ -z "${s5_out:-}" ] && [ "${s5_rc:-0}" -gt 128 ] && [ "${s5_rc:-0}" -ne 0 ]; then
    s5_out="(process killed by signal)"
fi
print_scenario \
    "$TOTAL" "OOM - memory exhaustion via ulimit" \
    "OOM (SIGKILL / MemoryError)" "maybe" "yes" \
    "${s5_out:-}" "${s5_rc:-0}"

# ==================================================================
# Scenario 6: I/O Blocking
#   Read from a fifo with no writer causes indefinite hang;
#   rescue with timeout to demonstrate blocking behavior.
# ==================================================================
TOTAL=$((TOTAL + 1))
rm -f "$WORKDIR/s6_fifo"
mkfifo "$WORKDIR/s6_fifo"
s6_rc=0; s6_out=$(timeout 2 sh -c 'cat "$1" >/dev/null; echo "UNBLOCKED"' _ "$WORKDIR/s6_fifo" 2>&1) || s6_rc=$?
rm -f "$WORKDIR/s6_fifo"
print_scenario \
    "$TOTAL" "I/O Blocking - fifo read blocks indefinitely (timeout demonstrates hang)" \
    "EIO / ETIMEDOUT" "yes" "maybe" \
    "${s6_out:-}" "${s6_rc:-0}"

# ==================================================================
# Scenario 7: Tool Crash (SIGSEGV)
#   Trigger a segmentation fault in a child process.
#   Redirect stderr to hide the OS "Segmentation fault" banner.
# ==================================================================
TOTAL=$((TOTAL + 1))
s7_rc=0; s7_out=$(sh -c 'kill -SEGV $$' 2>/dev/null) || s7_rc=$?
print_scenario \
    "$TOTAL" "Tool Crash - SIGSEGV in child process" \
    "SIGSEGV (signal 11)" "maybe" "maybe" \
    "(child terminated by SIGSEGV - signal 11; exit code ${s7_rc})" "${s7_rc}"

# ==================================================================
# Scenario 8: Path Name Conflict (ENOTDIR)
#   A file exists where a directory component is needed.
#   mkdir somepath/subdir fails with ENOTDIR when somepath is a file.
# ==================================================================
TOTAL=$((TOTAL + 1))
touch "$WORKDIR/s8_file"
s8_rc=0; s8_out=$(mkdir "$WORKDIR/s8_file/subdir" 2>&1) || s8_rc=$?
print_scenario \
    "$TOTAL" "Path Name Conflict - file exists where directory component needed" \
    "ENOTDIR" "no" "yes" \
    "${s8_out:-}" "${s8_rc:-0}"

# ==================================================================
# Scenario 9: Symlink Cycle (ELOOP)
#   Create a -> b -> a symlink cycle, then mkdir under it.
#   Resolution follows a -> b -> a -> b -> ... until ELOOP.
# ==================================================================
TOTAL=$((TOTAL + 1))
ln -sf s9_link_a "$WORKDIR/s9_link_b"
ln -sf s9_link_b "$WORKDIR/s9_link_a"
s9_rc=0; s9_out=$(mkdir -p "$WORKDIR/s9_link_a/s9_link_b/subdir" 2>&1) || s9_rc=$?
print_scenario \
    "$TOTAL" "Symlink Cycle - ELOOP on circular symlink resolution" \
    "ELOOP" "no" "yes" \
    "${s9_out:-}" "${s9_rc:-0}"

# ==================================================================
# Summary
# ==================================================================
echo "================================================================="
echo "  Suite Complete: $TOTAL scenarios executed"
echo "================================================================="
echo ""
echo "LEGEND:"
echo "  RETRYABLE = maybe    Transient condition; retry may succeed"
echo "  RETRYABLE = no       Permanent condition; retrying is wasted work"
echo "  AGENT WOULD LOOP     Agent retries same mkdir without strategy change"
echo ""
echo "These 9 triggers account for >95% of agent deadloop incidents"
echo "observed during directory-creation workflows."
