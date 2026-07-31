#!/usr/bin/env bash
# platform-detect.sh — Cross-Platform Detection & Adaptation Layer
# Version: 1.0.0
#
# Detects the current platform and sets standardized variables for
# portable script usage. Source this before any operations.
#
# Best practices referenced:
#   - GNU Autotools (config.guess pattern)
#   - Python sysconfig.get_platform()
#   - Rust std::env::consts::OS
#   - POSIX.1-2017 uname

# ─── Platform Detection ──────────────────────────────────────────
detect_platform() {
    PLATFORM_OS="unknown"
    PLATFORM_ARCH="unknown"
    PLATFORM_KERNEL="unknown"
    PLATFORM_IS_LINUX=false
    PLATFORM_IS_MACOS=false
    PLATFORM_IS_BSD=false
    PLATFORM_IS_WINDOWS=false
    PLATFORM_IS_WSL=false
    PLATFORM_IS_BUSYBOX=false
    PLATFORM_HAS_PROC=false
    PLATFORM_HAS_TIMEOUT=false
    PLATFORM_COREUTILS="gnu"  # gnu, bsd, busybox

    local uname_s uname_m uname_r
    uname_s=$(uname -s 2>/dev/null || echo "unknown")
    uname_m=$(uname -m 2>/dev/null || echo "unknown")
    uname_r=$(uname -r 2>/dev/null || echo "unknown")

    case "$uname_s" in
        Linux)
            PLATFORM_OS="linux"
            PLATFORM_KERNEL="$uname_r"
            PLATFORM_IS_LINUX=true
            PLATFORM_HAS_PROC=true
            PLATFORM_HAS_TIMEOUT=true  # GNU coreutils timeout available

            # Check for WSL
            if grep -qi microsoft /proc/version 2>/dev/null; then
                PLATFORM_IS_WSL=true
            fi
            # Check for BusyBox
            if command -v busybox &>/dev/null && [ "$(readlink -f "$(which sh)" 2>/dev/null)" = "/bin/busybox" ]; then
                PLATFORM_IS_BUSYBOX=true
                PLATFORM_COREUTILS="busybox"
            fi
            ;;
        Darwin)
            PLATFORM_OS="macos"
            PLATFORM_KERNEL="$uname_r"
            PLATFORM_IS_MACOS=true
            PLATFORM_HAS_PROC=false         # No /proc on macOS
            PLATFORM_HAS_TIMEOUT=false       # No timeout by default (install coreutils)
            PLATFORM_COREUTILS="bsd"
            ;;
        FreeBSD|OpenBSD|NetBSD|DragonFly)
            PLATFORM_OS="bsd"
            PLATFORM_KERNEL="$uname_r"
            PLATFORM_IS_BSD=true
            PLATFORM_HAS_PROC=false
            PLATFORM_HAS_TIMEOUT=false
            PLATFORM_COREUTILS="bsd"
            ;;
        MINGW*|MSYS*|CYGWIN*)
            PLATFORM_OS="windows"
            PLATFORM_IS_WINDOWS=true
            PLATFORM_HAS_PROC=false
            PLATFORM_HAS_TIMEOUT=false  # Some Git Bash versions have it
            PLATFORM_COREUTILS="gnu"   # Git Bash ships GNU coreutils
            # Check for timeout
            command -v timeout &>/dev/null && PLATFORM_HAS_TIMEOUT=true
            ;;
        SunOS)
            PLATFORM_OS="solaris"
            PLATFORM_HAS_PROC=false
            PLATFORM_HAS_TIMEOUT=false
            PLATFORM_COREUTILS="bsd"
            ;;
        *)
            PLATFORM_OS="unknown"
            ;;
    esac

    PLATFORM_ARCH="$uname_m"

    # Detect timeout availability
    if command -v timeout &>/dev/null; then
        PLATFORM_HAS_TIMEOUT=true
    fi
}

# ─── Standardized Commands ───────────────────────────────────────
setup_platform_commands() {
    # After calling this, use the standardized variables instead of raw commands.

    # STAT: get file information
    if $PLATFORM_IS_MACOS || $PLATFORM_IS_BSD; then
        # BSD stat: stat -f <format> <file>
        STAT_TYPE='stat -f %HT'     # File type
        STAT_SIZE='stat -f %z'      # File size
        STAT_PERMS='stat -f %p'     # Permissions
    else
        # GNU stat: stat -c <format> <file>
        STAT_TYPE='stat -c %F'
        STAT_SIZE='stat -c %s'
        STAT_PERMS='stat -c %a'
    fi

    # SED: in-place editing
    if $PLATFORM_IS_MACOS; then
        SED_INPLACE='sed -i ""'     # macOS requires empty backup extension
    else
        SED_INPLACE='sed -i'        # GNU sed
    fi

    # GREP: extended regex flag
    if $PLATFORM_IS_MACOS || $PLATFORM_IS_BSD; then
        GREP_EXTENDED='grep -E'     # BSD grep uses -E for extended
    else
        GREP_EXTENDED='grep -E'     # GNU grep also uses -E (same, but documented)
    fi

    # READLINK: canonical path
    if $PLATFORM_IS_MACOS; then
        # macOS readlink doesn't have -f; use a combination or realpath if available
        if command -v realpath &>/dev/null; then
            READLINK_F='realpath'
        elif command -v grealpath &>/dev/null; then
            READLINK_F='grealpath'  # GNU realpath from coreutils
        else
            READLINK_F='readlink'   # Best effort (won't resolve relative paths)
        fi
    else
        READLINK_F='readlink -f'
    fi

    # MKTEMP: temp file creation
    if $PLATFORM_IS_MACOS; then
        # macOS mktemp doesn't require XXXXXX but accepts it
        MKTEMP='mktemp -t agent-safe'
    else
        MKTEMP='mktemp --tmpdir=/tmp'
    fi

    # TIMEOUT: command timeout
    if $PLATFORM_HAS_TIMEOUT; then
        TIMEOUT_CMD='timeout'
    else
        # Fallback: use perl or a custom implementation
        if command -v perl &>/dev/null; then
            TIMEOUT_CMD='_timeout_perl'
        else
            TIMEOUT_CMD='_timeout_builtin'
        fi
    fi

    # NUKE: secure file deletion (no /dev/null on some platforms)
    if [ -c /dev/null ]; then
        DEV_NULL='/dev/null'
    else
        DEV_NULL='NUL'  # Windows
    fi
}

# ─── Platform Fallback Implementations ───────────────────────────
_timeout_perl() {
    # Perl-based timeout fallback (portable to macOS, BSD, etc.)
    local timeout_sec="$1"; shift
    perl -e '
        eval {
            local $SIG{ALRM} = sub { die "timeout\n" };
            alarm '"$timeout_sec"';
            system(@ARGV);
            my $exit = $? >> 8;
            alarm(0);
            exit $exit;
        };
        if ($@ eq "timeout\n") { exit 124; }
        exit 1;
    ' -- "$@"
}

_timeout_builtin() {
    # Pure-bash timeout using background process + wait + kill
    # Limited but works on all platforms without perl or timeout
    local timeout_sec="$1"; shift
    local pid ret

    "$@" &
    pid=$!

    (
        sleep "$timeout_sec"
        kill -9 "$pid" 2>/dev/null
    ) &
    local watchdog=$!

    wait "$pid" 2>/dev/null
    ret=$?

    kill -9 "$watchdog" 2>/dev/null
    wait "$watchdog" 2>/dev/null

    if [ $ret -eq 137 ] 2>/dev/null; then
        return 124  # timeout exit code
    fi
    return $ret
}

# ─── System Diagnostics (Cross-Platform) ─────────────────────────
get_system_memory() {
    # Returns available memory in MB, or "unknown"
    if [ -r /proc/meminfo ]; then
        # Linux
        awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo "unknown"
    elif $PLATFORM_IS_MACOS; then
        # macOS: vm_stat + page size
        local page_size free_pages
        page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo "4096")
        free_pages=$(vm_stat 2>/dev/null | awk '/Pages free/{print $NF}' | tr -d '.')
        if [ -n "$free_pages" ]; then
            echo "$((page_size * free_pages / 1048576))"
        else
            echo "unknown"
        fi
    elif command -v free &>/dev/null; then
        # Generic: try free command
        free -m 2>/dev/null | awk '/Mem:/{print $7}' || echo "unknown"
    else
        echo "unknown"
    fi
}

get_system_load() {
    # Returns 1-minute load average, or "unknown"
    if [ -r /proc/loadavg ]; then
        cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo "unknown"
    elif command -v sysctl &>/dev/null && $PLATFORM_IS_MACOS; then
        sysctl -n vm.loadavg 2>/dev/null | grep -o '{[^}]*}' | tr -d '{}' || echo "unknown"
    elif command -v uptime &>/dev/null; then
        uptime 2>/dev/null | grep -o 'load average: [0-9.]*' | awk '{print $NF}' || echo "unknown"
    else
        echo "unknown"
    fi
}

get_dstate_processes() {
    # Returns count of D-state (uninterruptible sleep) processes, or "unknown"
    if [ -d /proc ]; then
        local count
        count=$(grep -c '^State:\s*D' /proc/*/status 2>/dev/null || echo "0")
        # Strip filenames from grep -c multi-file output
        echo "$count" | awk -F: '{sum += $NF} END {print sum+0}'
    else
        echo "unknown"  # Not available on macOS/BSD/Windows
    fi
}

# ─── Initialize on Source ────────────────────────────────────────
detect_platform
setup_platform_commands

# Export for use in other scripts
export PLATFORM_OS PLATFORM_ARCH PLATFORM_IS_MACOS PLATFORM_IS_LINUX
export PLATFORM_IS_BSD PLATFORM_IS_WINDOWS PLATFORM_IS_WSL
export PLATFORM_HAS_PROC PLATFORM_HAS_TIMEOUT PLATFORM_COREUTILS
export STAT_TYPE SED_INPLACE GREP_EXTENDED READLINK_F MKTEMP TIMEOUT_CMD

# ─── Print Info (if run directly, not sourced) ───────────────────
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    echo "Platform Detection Results:"
    echo "  OS:       $PLATFORM_OS"
    echo "  Arch:     $PLATFORM_ARCH"
    echo "  Kernel:   $PLATFORM_KERNEL"
    echo "  Coreutils: $PLATFORM_COREUTILS"
    echo "  /proc:    $PLATFORM_HAS_PROC"
    echo "  timeout:  $PLATFORM_HAS_TIMEOUT"
    echo "  Memory:   $(get_system_memory) MB"
    echo "  Load:     $(get_system_load)"
    echo "  D-state:  $(get_dstate_processes)"
fi
