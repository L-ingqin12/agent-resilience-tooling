#!/usr/bin/env python3
"""
Python Safe File System Tools — LangChain / OpenAI / Claude SDK Adapter

Drop-in replacement for raw bash mkdir/rm/write operations.
Designed for agent frameworks that support Python function calling.

Usage:
  from python_safe_tools import ensure_directory, ensure_file, safe_remove

  result = ensure_directory("/tmp/app/logs")
  if result["ok"]:
      print(f"Directory ready: {result['path']}")
  elif not result["error"]["retryable"]:
      print(f"PERMANENT ERROR: {result['error']['suggestion']}")
      # DO NOT retry

All functions return StructuredResult dicts. None ever raise exceptions silently.
Compatible with: LangChain @tool, OpenAI function calling, Anthropic tool_runner
"""

import os
import errno
import json
import time
import shutil
import tempfile
import subprocess
from pathlib import Path
from typing import Optional, Dict, Any, List, Literal, TypedDict

# ─── Type Definitions ───────────────────────────────────────────
ErrorCode = Literal[
    "E_EXISTS", "E_PERM", "E_NOSPC", "E_IO", "E_OOM",
    "E_TIMEOUT", "E_PATH", "E_PATH_CONFLICT", "E_UNKNOWN",
    "E_SYSTEM_CATASTROPHE"
]
ErrorLayer = Literal["os", "fs", "permission", "resource", "logic"]

class StructuredError(TypedDict):
    code: ErrorCode
    layer: ErrorLayer
    retryable: bool
    suggestion: str
    diagnostics: Dict[str, Any]

class StructuredResult(TypedDict):
    ok: bool
    path: str
    error: Optional[StructuredError]

# ─── Error Classification ────────────────────────────────────────
ERRNO_MAP: Dict[int, tuple] = {
    errno.EACCES:      ("E_PERM", "permission", False),
    errno.EPERM:       ("E_PERM", "permission", False),
    errno.EEXIST:      ("E_EXISTS", "fs", False),
    errno.ENOENT:      ("E_PATH", "logic", False),
    errno.ENOSPC:      ("E_NOSPC", "resource", True),
    errno.ENOMEM:      ("E_OOM", "resource", False),
    errno.EIO:         ("E_IO", "os", False),
    errno.ETIMEDOUT:   ("E_TIMEOUT", "os", True),
    errno.ENOTDIR:     ("E_PATH_CONFLICT", "logic", False),
    errno.ELOOP:       ("E_PATH_CONFLICT", "logic", False),
}

def classify_error(exc: Exception) -> StructuredError:
    """Classify any Python exception into a structured error."""
    errno_val = getattr(exc, "errno", 0)

    if errno_val and errno_val in ERRNO_MAP:
        code, layer, retryable = ERRNO_MAP[errno_val]
        return {
            "code": code,
            "layer": layer,
            "retryable": retryable,
            "suggestion": str(exc),
            "diagnostics": {"errno": errno_val, "strerror": os.strerror(errno_val) if errno_val else ""}
        }

    if isinstance(exc, FileExistsError):
        return {"code": "E_EXISTS", "layer": "fs", "retryable": False,
                "suggestion": "Path already exists. This is success for creation operations.",
                "diagnostics": {"errno": errno.EEXIST}}
    if isinstance(exc, PermissionError):
        return {"code": "E_PERM", "layer": "permission", "retryable": False,
                "suggestion": "Permission denied. Use an alternative path.",
                "diagnostics": {"errno": errno.EACCES}}
    if isinstance(exc, FileNotFoundError):
        return {"code": "E_PATH", "layer": "logic", "retryable": False,
                "suggestion": "Parent directory does not exist. Create parents first.",
                "diagnostics": {"errno": errno.ENOENT}}
    if isinstance(exc, MemoryError):
        return {"code": "E_OOM", "layer": "resource", "retryable": False,
                "suggestion": "System out of memory. DO NOT retry.",
                "diagnostics": {}}
    if isinstance(exc, TimeoutError):
        return {"code": "E_TIMEOUT", "layer": "os", "retryable": True,
                "suggestion": "Operation timed out. Retry once with longer timeout.",
                "diagnostics": {}}

    # Unknown
    return {"code": "E_UNKNOWN", "layer": "os", "retryable": False,
            "suggestion": f"Unknown error: {exc}. Report and do NOT retry blindly.",
            "diagnostics": {"exception_type": type(exc).__name__}}

# ─── System Diagnostics ──────────────────────────────────────────
def _system_diagnostics() -> dict:
    """Gather system health data for error diagnostics."""
    diag = {}
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                if "MemAvailable" in line:
                    diag["mem_available_mb"] = int(line.split()[1]) // 1024
                    break
    except Exception:
        diag["mem_available_mb"] = "unknown"
    try:
        diag["load_1m"] = float(open("/proc/loadavg").read().split()[0])
    except Exception:
        diag["load_1m"] = "unknown"
    return diag

# ─── Pre-Flight Health Check ─────────────────────────────────────
def _preflight_check() -> Optional[StructuredResult]:
    """Check system health before executing. Returns error if unsafe to proceed."""
    diag = _system_diagnostics()
    mem = diag.get("mem_available_mb", "unknown")
    if isinstance(mem, int) and mem < 50:
        return {
            "ok": False,
            "path": "",
            "error": {
                "code": "E_OOM",
                "layer": "resource",
                "retryable": False,
                "suggestion": f"System memory critically low ({mem}MB). DO NOT proceed.",
                "diagnostics": diag
            }
        }
    return None

# ─── ensure_directory ────────────────────────────────────────────
def ensure_directory(path: str, mode: int = 0o755, create_parents: bool = True) -> StructuredResult:
    """
    Ensure a directory exists. Idempotent — safe to call repeatedly.

    Args:
        path: Absolute path to the directory
        mode: Permission bits (default: 0o755)
        create_parents: Create parent directories if needed (default: True)

    Returns:
        StructuredResult with ok, path, created, existed_before, error
    """
    path = os.path.normpath(path)

    # Input validation
    if not path or path == "/":
        return {"ok": False, "path": path,
                "error": {"code": "E_PATH", "layer": "logic", "retryable": False,
                          "suggestion": f"Refusing to operate on root or empty path: {path}",
                          "diagnostics": {}}}

    # Critical path protection
    for critical in ["/root", "/etc", "/boot", "/sys", "/proc", "/dev"]:
        if path == critical or path.startswith(critical + "/"):
            return {"ok": False, "path": path,
                    "error": {"code": "E_PERM", "layer": "permission", "retryable": False,
                              "suggestion": f"Refusing to operate on system path: {path}. Use a user-space path.",
                              "diagnostics": {}}}

    # Pre-flight
    preflight = _preflight_check()
    if preflight:
        preflight["path"] = path
        return preflight

    try:
        # Check current state
        if os.path.isdir(path):
            return {"ok": True, "path": path, "created": False, "existed_before": True, "error": None}

        if os.path.exists(path):
            ftype = "symlink" if os.path.islink(path) else "file"
            return {"ok": False, "path": path,
                    "error": {"code": "E_PATH_CONFLICT", "layer": "logic", "retryable": False,
                              "suggestion": f"Path exists as a {ftype}, not a directory.",
                              "diagnostics": {"existing_type": ftype}}}

        # Create
        if create_parents:
            os.makedirs(path, mode=mode, exist_ok=True)
        else:
            os.mkdir(path, mode=mode)

        # Verify
        if os.path.isdir(path):
            return {"ok": True, "path": path, "created": True, "existed_before": False, "error": None}

        return {"ok": False, "path": path,
                "error": {"code": "E_UNKNOWN", "layer": "os", "retryable": False,
                          "suggestion": "Directory creation reported success but verification failed.",
                          "diagnostics": _system_diagnostics()}}

    except Exception as e:
        return {"ok": False, "path": path, "error": classify_error(e),
                "diagnostics": _system_diagnostics()}

# ─── ensure_file ─────────────────────────────────────────────────
def ensure_file(path: str, content: str = "", mode: int = 0o644) -> StructuredResult:
    """
    Atomically write content to a file. Uses tempfile + rename for atomicity.

    Args:
        path: Absolute path to the file
        content: Content to write (default: empty)
        mode: Permission bits (default: 0o644)

    Returns:
        StructuredResult with ok, path, written, error
    """
    path = os.path.normpath(path)
    if not path:
        return {"ok": False, "path": "",
                "error": {"code": "E_PATH", "layer": "logic", "retryable": False,
                          "suggestion": "Path is empty.", "diagnostics": {}}}

    # Ensure parent exists
    parent = os.path.dirname(path)
    if parent and not os.path.isdir(parent):
        parent_result = ensure_directory(parent)
        if not parent_result["ok"]:
            return {"ok": False, "path": path,
                    "error": {"code": "E_PATH", "layer": "logic", "retryable": False,
                              "suggestion": f"Cannot create parent directory: {parent}",
                              "diagnostics": {"parent_result": parent_result}}}

    try:
        # Atomic write: tempfile → rename
        tmpdir = os.path.dirname(path) or "/tmp"
        fd, tmpname = tempfile.mkstemp(dir=tmpdir, prefix=".safe-write-")
        try:
            os.write(fd, content.encode() if isinstance(content, str) else content)
            os.fchmod(fd, mode)
        finally:
            os.close(fd)
        os.rename(tmpname, path)
        return {"ok": True, "path": path, "written": True}
    except Exception as e:
        # Cleanup tempfile
        try:
            os.unlink(tmpname)
        except Exception:
            pass
        return {"ok": False, "path": path, "error": classify_error(e)}

# ─── safe_remove ─────────────────────────────────────────────────
def safe_remove(path: str) -> StructuredResult:
    """
    Trash-style removal — moves to /tmp/.python-trash/ instead of permanent delete.

    Args:
        path: Absolute path to remove

    Returns:
        StructuredResult with ok, path, action, trash_location
    """
    path = os.path.normpath(path)
    if not path or path == "/":
        return {"ok": False, "path": path,
                "error": {"code": "E_PATH", "layer": "logic", "retryable": False,
                          "suggestion": "Refusing to delete root or empty path.",
                          "diagnostics": {}}}

    if not os.path.exists(path) and not os.path.islink(path):
        return {"ok": True, "path": path, "action": "nothing", "reason": "does_not_exist"}

    trash_dir = "/tmp/.python-trash"
    os.makedirs(trash_dir, exist_ok=True)

    basename = os.path.basename(path)
    ts = int(time.time())
    trash_name = os.path.join(trash_dir, f"{basename}.{ts}")

    try:
        shutil.move(path, trash_name)
        return {"ok": True, "path": path, "action": "trashed", "trash_location": trash_name}
    except Exception as e:
        return {"ok": False, "path": path, "error": classify_error(e)}

# ─── LangChain @tool Compatible Wrappers ─────────────────────────
# Usage:
#   from langchain.tools import tool
#
#   @tool
#   def ensure_directory_tool(path: str) -> str:
#       '''Ensure a directory exists. Idempotent.'''
#       return json.dumps(ensure_directory(path))
#
#   result = ensure_directory_tool.invoke({"path": "/tmp/myapp"})

# ─── OpenAI Function Calling Compatible Schema ───────────────────
ENSURE_DIRECTORY_SCHEMA = {
    "name": "ensure_directory",
    "description": "Ensure a directory exists. Idempotent — safe to call repeatedly. Returns structured JSON with 'ok' field.",
    "parameters": {
        "type": "object",
        "properties": {
            "path": {"type": "string", "description": "Absolute path to the directory"},
            "create_parents": {"type": "boolean", "description": "Create parent directories if needed (default: true)"}
        },
        "required": ["path"]
    }
}

ENSURE_FILE_SCHEMA = {
    "name": "ensure_file",
    "description": "Atomically write content to a file. Uses tempfile + rename. Returns structured JSON with 'ok' field.",
    "parameters": {
        "type": "object",
        "properties": {
            "path": {"type": "string", "description": "Absolute path to the file"},
            "content": {"type": "string", "description": "Content to write"}
        },
        "required": ["path", "content"]
    }
}

SAFE_REMOVE_SCHEMA = {
    "name": "safe_remove",
    "description": "Safely remove a file or directory by moving to trash. Returns structured JSON with 'ok' field.",
    "parameters": {
        "type": "object",
        "properties": {
            "path": {"type": "string", "description": "Absolute path to remove"}
        },
        "required": ["path"]
    }
}

# ─── Self-Test ───────────────────────────────────────────────────
def self_test():
    """Run quick self-test to verify the library works."""
    import tempfile
    test_dir = os.path.join(tempfile.gettempdir(), f"python-safe-test-{os.getpid()}")

    results = []

    # Test 1: Create directory
    r = ensure_directory(test_dir)
    results.append(("ensure_directory_create", r["ok"]))

    # Test 2: Idempotent
    r = ensure_directory(test_dir)
    results.append(("ensure_directory_idempotent", r["ok"] and not r.get("created")))

    # Test 3: Classify EEXIST
    r = classify_error(FileExistsError("test"))
    results.append(("classify_EEXIST", r["code"] == "E_EXISTS"))

    # Test 4: Classify EACCES
    r = classify_error(PermissionError("test"))
    results.append(("classify_EACCES", r["code"] == "E_PERM"))

    # Cleanup
    shutil.rmtree(test_dir, ignore_errors=True)

    passed = sum(1 for _, ok in results if ok)
    print(f"Self-test: {passed}/{len(results)} passed")
    for name, ok in results:
        print(f"  {'PASS' if ok else 'FAIL'}: {name}")

    return passed == len(results)


if __name__ == "__main__":
    self_test()
