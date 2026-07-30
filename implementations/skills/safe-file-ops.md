# Skill: safe-file-ops

## Trigger

When the agent needs to perform file operations that modify the filesystem:
create directories, write files, delete files, change permissions, move/rename files.

Trigger keywords: `mkdir`, `rm`, `touch`, `cat >`, `dd`, `chmod`, `chown`, `mv`, `install`, `truncate`, `fallocate`

## Pre-Operation Checklist (ALWAYS execute first)

### Path Validation Template

```python
# Validate the target path before any destructive operation
# Check: is the path inside an allowed working directory?
# Check: does the path reference a system directory (/etc, /usr, /boot, /dev)?
# Check: does the path contain symlink traversal that could escape the sandbox?

SAFE_PREFIXES = [
    "/root/workspace",
    "/tmp",
    "/home",
    "/var/tmp",
]
BLOCKED_PREFIXES = [
    "/etc",
    "/usr",
    "/boot",
    "/dev",
    "/proc",
    "/sys",
    "/lib",
    "/bin",
    "/sbin",
    "/opt",
]

def validate_path(path: str) -> str | None:
    """Returns None if safe, returns error message if blocked."""
    import os
    real = os.path.realpath(path)  # resolve symlinks
    for blocked in BLOCKED_PREFIXES:
        if real.startswith(blocked):
            return f"BLOCKED: path resolves to system directory {blocked}"
    for safe in SAFE_PREFIXES:
        if real.startswith(safe):
            return None
    return f"WARNING: path {real} is outside known safe prefixes, proceed with caution"
```

### State Check Template

```bash
# Before modifying a path, check its current state:
# 1. Does it exist?
if [ -e "/path/to/target" ]; then echo "EXISTS"; else echo "ABSENT"; fi
# 2. What type is it?
if [ -f "/path/to/target" ]; then echo "FILE"; elif [ -d "/path/to/target" ]; then echo "DIR"; elif [ -L "/path/to/target" ]; then echo "SYMLINK"; else echo "OTHER"; fi
# 3. What are its permissions?
stat -c "%a %A %u:%g" "/path/to/target" 2>/dev/null || echo "PERM_UNKNOWN"
# 4. Is it non-empty? (for files)
wc -c "/path/to/target" 2>/dev/null | awk '{print $1}'
```

### Resource Check Template

```bash
# Before writing, verify:
# 1. Available disk space on target filesystem
df -k "$(dirname "/path/to/target")" | tail -1 | awk '{print $4}'
# Expected: at least 2x the estimated write size in KB

# 2. Inode availability
df -i "$(dirname "/path/to/target")" | tail -1 | awk '{print $4}'
# Expected: at least 10 free inodes

# 3. Filesystem is not read-only
touch "$(dirname "/path/to/target")/.write_test_$$" 2>&1 && rm "$(dirname "/path/to/target")/.write_test_$$" || echo "READONLY_FS"
```

## Operation Templates

### Creating a Directory

```bash
# SAFE: create directory (parent-parent-parent ... -p)
mkdir -p "/path/to/new/directory" 2>&1; echo "EXIT:$?"
# The -p flag is mandatory: it creates parents and suppresses errors
# if the directory already exists.

# Capture both stdout and stderr, then check exit code.
# Do NOT use bare `mkdir /path` without -p — it will fail if parents
# are missing and produces a misleading error.
```

### Writing a File

```bash
# ATOMIC WRITE PATTERN: write to temp, then rename.
# This prevents partial reads by other processes.

# Step 1: Write to a temporary file
printf '%s' 'file content here' > "/path/to/target.tmp.$$" 2>&1; echo "WRITE_EXIT:$?"
# Step 2: Verify the temp file was written correctly
if [ -f "/path/to/target.tmp.$$" ]; then
    # Optional: validate content hash
    # sha256sum "/path/to/target.tmp.$$"
    # Step 3: Atomic rename
    mv "/path/to/target.tmp.$$" "/path/to/target" 2>&1; echo "RENAME_EXIT:$?"
else
    echo "ATOMIC_WRITE_FAILED: temp file not created"
fi
```

### Removing a File/Directory

```bash
# TRASH-STYLE REMOVAL PATTERN: move to a trash directory instead of deleting.
# This enables recovery if the deletion was in error.

TRASH_DIR="/tmp/.trash/$(date +%Y%m%d)/"
mkdir -p "$TRASH_DIR" 2>&1; echo "TRASH_INIT:$?"

# For a file:
mv "/path/to/target/file" "$TRASH_DIR" 2>&1; echo "TRASH_EXIT:$?"

# For a directory:
mv "/path/to/target/dir" "$TRASH_DIR" 2>&1; echo "TRASH_EXIT:$?"

# ONLY use rm after confirming the trash move succeeded and the
# operation was intentional:
# rm -rf "$TRASH_DIR/specific-file"  # explicit, confirmed

# Never use rm without first moving to trash.
# Never use rm -rf with '/' anywhere in the path without triple-checking.
```

## Error Classification Quick Reference

| Exit Code | Meaning | Recommended Action |
|-----------|---------|-------------------|
| 0 | Success | Proceed |
| 1 | General error | Inspect stderr output |
| 2 | Misuse of shell builtin | Fix command syntax |
| 126 | Command not executable | Check permissions |
| 127 | Command not found | Check PATH / install tool |
| 128 | Invalid exit argument | Internal error |
| 130 | Terminated by Ctrl+C | Retry or skip |
| 137 | Killed (SIGKILL) | Check OOM / resource limits |
| 139 | Segmentation fault (SIGSEGV) | STOP — possible corruption |
| 1-255 (other) | Various | Check stderr, classify below |

### Error Classification Patterns

| Error Message Pattern | Classification | Action |
|-----------------------|---------------|--------|
| `Permission denied` | Permissions | Check ownership/ACL, use sudo if scoped |
| `No such file or directory` | Missing parent | Ensure parents exist with mkdir -p |
| `File exists` | Already exists | Add -f flag or remove first if intentional |
| `Read-only file system` | FS mount | Remount rw or change target |
| `Disk quota exceeded` | Space | Free space or change target |
| `Text file busy` | Locked | Close other handles, retry |
| `Device or resource busy` | Mounted | Unmount before rm |
| `Argument list too long` | Too many files | Use find -exec or xargs |
| `Is a directory` | Wrong op | Use rm -rf or rmdir for directories |
| `Not a directory` | Wrong op | Check path, use correct flags |
| `Invalid argument` | Bad flag/path | Check syntax and path characters |

## Post-Operation Rules

1. **Classify before retry**: Always capture and classify the error before deciding whether to retry. Do not blindly retry the same command.

2. **Stop conditions**: Do NOT retry if any of the following appear:
   - `Segmentation fault` (exit 139) — possible memory corruption or filesystem issue
   - `Killed` (exit 137) — system OOM, retry will likely also be killed
   - `Read-only file system` — retry will fail identically
   - `Disk quota exceeded` — retry will fail until space is freed
   - Path resolves to a blocked system directory

3. **Escalate after N retries**: After 3 consecutive failures for the same operation, stop and report the full error context. Do not silently retry more than 3 times.

4. **Validate after write**: After creating or modifying a file, verify:
   ```bash
   # File exists and is non-empty (if expected)
   [ -s "/path/to/target" ] && echo "WRITE_OK" || echo "WRITE_FAILED_EMPTY"
   # Permissions match expectation
   stat -c "%a" "/path/to/target" | grep -qE "^6[0-9][0-9]$" && echo "PERM_OK" || echo "PERM_UNEXPECTED"
   ```

5. **Log the operation**: Record what was done, the exit code, and any errors for audit.

## Anti-Patterns (what NOT to do)

### Deadloop 1: mkdir without -p followed by error, then mkdir again without -p

```bash
# BAD — creates an infinite loop of failure:
mkdir /some/deep/path       # fails because /some/deep doesn't exist
# "oh it failed let me retry"
mkdir /some/deep/path       # fails again, same reason
# "retry again..."
mkdir /some/deep/path       # still fails

# GOOD — use -p once:
mkdir -p /some/deep/path    # succeeds, creates parents
```

### Deadloop 2: rm of non-existent file with retry

```bash
# BAD — retrying an operation that will never succeed:
rm /tmp/log.txt             # fails because file doesn't exist
rm /tmp/log.txt             # fails again
rm /tmp/log.txt             # still fails

# GOOD — check existence first, or use -f to suppress error:
[ -f /tmp/log.txt ] && rm /tmp/log.txt
# OR
rm -f /tmp/log.txt          # exits 0 even if file absent
```

### Deadloop 3: chmod without check, retrying same permissions

```bash
# BAD — retrying a permission that already matches:
chmod 644 /etc/config       # fails because you don't have permission
chmod 644 /etc/config       # fails again (still don't have permission)
chmod 644 /etc/config       # still fails

# GOOD — check current state, only act if needed, report if blocked:
CURRENT=$(stat -c "%a" /etc/config 2>/dev/null)
if [ "$CURRENT" = "644" ]; then
    echo "ALREADY_SET: skipping"
elif [ -w /etc/config ]; then
    chmod 644 /etc/config
else
    echo "BLOCKED: no write permission on /etc/config"
fi
```
