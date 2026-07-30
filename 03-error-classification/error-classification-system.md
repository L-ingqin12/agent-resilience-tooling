# 错误分类系统 (Error Classification System)

> 终结 AI Agent 死循环的第一步：让 Agent 能读懂错误的"方言"。
>
> 参考：死循环根因分类学 (01-root-cause-analysis/deadloop-taxonomy.md) 第 4 节 —
> 真正的问题是 Agent 工具调用模型中缺少**失败分类**这个信息维度。

---

## 1. ErrorCode 枚举

系统识别 8 种标准化错误码。每个错误码映射到 POSIX errno，携带人类可读描述和典型触发场景。

| 错误码 | POSIX errno | 描述 | 典型触发场景 |
|--------|-------------|------|-------------|
| `E_EXISTS` | `EEXIST` (17) | 路径已存在但无法完成操作 | `mkdir /existing-dir` 时目标已存在 |
| `E_PERM` | `EACCES` (13) / `EPERM` (1) | 权限不足，无法访问或修改路径 | `mkdir /root/foo` 以非 root 用户执行 |
| `E_NOSPC` | `ENOSPC` (28) | 磁盘空间或 inode 耗尽 | `mkdir` 在满盘文件系统上失败 |
| `E_IO` | `EIO` (5) | 底层 I/O 错误，存储不可靠 | NFS 挂载点超时、磁盘坏道、FUSE 崩溃 |
| `E_OOM` | `ENOMEM` (12) 或进程被 SIGKILL | 系统内存不足，无法完成操作 | `fork()` 返回 `EAGAIN` 或 OOM-killer 介入 |
| `E_TIMEOUT` | 框架超时 (无直接 POSIX 映射) | 操作超过时间预算，结果不确定 | 挂载点卡死 (D 状态)、大文件 I/O 阻塞 |
| `E_PATH_CONFLICT` | `ENOTDIR` (20) 或 `EISDIR` (21) | 路径名语义冲突，非预期类型 | 期望目录但普通文件占位，反之亦然 |
| `E_UNKNOWN` | 其他所有 | 未归类或不可识别的错误 | 工具 segfault、bash 退出码 255、空响应 |

### 1.1 POSIX errno 快速参考

```c
// 与文件操作最相关的 errno 值
#define EPERM    1  /* Operation not permitted */
#define EIO      5  /* I/O error */
#define ENOMEM  12  /* Out of memory */
#define EACCES  13  /* Permission denied */
#define EEXIST  17  /* File exists */
#define ENOTDIR 20  /* Not a directory */
#define EISDIR  21  /* Is a directory */
#define ENOSPC  28  /* No space left on device */
#define EROFS   30  /* Read-only filesystem */
#define ENAMETOOLONG 36  /* File name too long */
#define ELOOP   40  /* Too many symbolic links encountered */
```

> **设计决策**: 不直接暴露 POSIX errno 给 Agent，而是映射为语义错误码。LLM 对 `EACCES` 的理解深度不如 `E_PERM`，对 `EEXIST` 的推理不如 `E_EXISTS` 直接。

---

## 2. 错误层分类 (Layer Classification)

将错误划分为 5 个语义层。层分类决定了 Agent 的**推理逻辑**和**重试策略**。

### 层定义

| 层 | 层名 | 覆盖范围 | 对 Agent 的决策意义 |
|----|------|---------|-------------------|
| `os` | 操作系统层 | 内核级错误：OOM、进程被杀、系统调用阻塞、信号中断 | **必须上报**，Agent 无法自行修复系统级问题 |
| `fs` | 文件系统层 | 存储级错误：磁盘满、I/O 错误、文件系统只读、inode 耗尽 | **尝试清理后重试**，若仍失败则需上报 |
| `permission` | 权限层 | 访问控制错误：权限不足、归属错误、 capabilities 缺失 | **请求升级或修改目标路径**，单纯重试无意义 |
| `resource` | 资源层 | 资源冲突错误：路径已存在、文件类型冲突、命名冲突 | **直接处理冲突**，幂等检查后即可恢复 |
| `logic` | 逻辑层 | Agent 推理错误：错误的目标规格、语义矛盾、目标不可达 | **纠正推理**，不是技术问题而是设计问题 |

### 2.1 错误码 → 层映射

| 错误码 | 默认层 | 层选择依据 |
|--------|--------|-----------|
| `E_EXISTS` | `resource` | 路径已存在是资源状态冲突，不是系统故障 |
| `E_PERM` | `permission` | 权限问题需要升级或变更路径，重试不能解决 |
| `E_NOSPC` | `fs` | 磁盘满可尝试清理，但本质是存储资源问题 |
| `E_IO` | `fs` | I/O 错误可能是瞬时的，但根源在存储层 |
| `E_OOM` | `os` | 内存耗尽影响整个进程，Agent 无法根治 |
| `E_TIMEOUT` | `os` | 超时可能意味着 I/O 阻塞或负载过重 |
| `E_PATH_CONFLICT` | `logic` | 路径类型冲突表明 Agent 的路径推理出错 |
| `E_UNKNOWN` | `os` | 未知错误保守归入操作系统层 |

> **为什么层分类对决策重要**:
>
> - `os` 层 → Agent 应立刻止损，不要重试。重试只会加剧 OOM、堆积 D 状态进程。
> - `fs` 层 → 可尝试一次清理+重试（如删除临时文件释放空间），但若仍失败则上报。
> - `permission` 层 → 重试永远无效。Agent 应改变策略（换路径、请求 sudo、切换用户）。
> - `resource` 层 → 幂等检查即可解决。这是最常见且最容易处理的错误类型。
> - `logic` 层 → 需要 Agent 反思自己的推理链，修正目标后再重试。

### 2.2 层叠检测 (Layered Detection)

某些错误场景会被上层捕获掩盖下层问题：

```
工具执行失败
  │
  ├─ 捕捉到 PermissionError
  │    └─ 层: permission
  │    └─ 但根本原因可能是: fs (文件系统只读) ← 需要额外探测
  │
  ├─ 捕捉到 OSError (ENOSPC)
  │    └─ 层: fs
  │    └─ 但根本原因可能是: os (后台进程泄漏文件描述符)
  │
  └─ 捕捉到 TimeoutError
       └─ 层: os
       └─ 但根本原因可能是: resource (NFS 挂载点卡死) ← 需要上下文
```

**应对**: 分类函数在归类后不停止探测。建议在返回 `StructuredError` 后，Agent 调用一个 `probe_root_cause()` 工具做深层诊断。

---

## 3. 可重试性矩阵 (Retryability Matrix)

| 错误码 | 可重试 | 建议动作 | 最大重试次数 | 冷却秒数 | 说明 |
|--------|--------|---------|-------------|---------|------|
| `E_EXISTS` | once | `modify_params` | 1 | 0 | 改为幂等模式（加 `exist_ok=True`）后一次成功 |
| `E_PERM` | no | `report_to_user` | 0 | 0 | 重试无用，需要权限升级 |
| `E_NOSPC` | yes | `retry_with_backoff` | 3 | 5 | 清理空间后重试，三次仍失败则上报 |
| `E_IO` | yes | `retry_with_backoff` | 2 | 10 | I/O 错误可能是瞬时的，但背压间隔要长 |
| `E_OOM` | no | `circuit_break` | 0 | 60 | 立刻熔断，等待系统恢复，至少 60 秒 |
| `E_TIMEOUT` | once | `modify_params` | 1 | 30 | 延长超时时间后重试一次，仍超时则上报 |
| `E_PATH_CONFLICT` | no | `report_to_user` | 0 | 0 | Agent 推理错误，需要纠正目标 |
| `E_UNKNOWN` | no | `escalate` | 0 | 0 | 未知错误需要人工诊断 |

### 3.1 重试策略详解

**`report_to_user`**: Agent 停止操作，将结构化错误返回给用户，附带可操作建议。适用于权限问题和路径冲突。

**`retry_with_backoff`**: 指数退避重试。公式：
```
sleep = min(cooldown_seconds * 2^attempt, max_backoff)
```
尝试次数超过 `max_retries` 后，状态自动转为 `escalate`。

**`modify_params`**: Agent 修改调用参数后立即重试（不计入退避）。例如 `mkdir` → `mkdir -p`，或延长超时参数。

**`circuit_break`**: 立即停止当前任务的所有文件操作。等待 `cooldown_seconds` 后，仅允许一次探测（probe）操作来确认系统状态是否恢复。探测通过后逐步恢复操作。此策略专门防止 E_OOM 场景下的重试风暴（死循环分类学 2.4：无代价意识）。

**`escalate`**: 递交给上层系统或人工。Agent 附上完整的错误上下文（错误码、层、调用链、系统状态快照）。

### 3.2 重试安全护栏

```python
# 全局重试限制 — 不可被 Agent 逻辑绕过
GLOBAL_RETRY_LIMITS = {
    "max_total_retries": 10,       # 单个任务生命周期内总重试上限
    "max_consecutive_retries": 5,  # 连续重试上限（无 success 插入）
    "circuit_break_threshold": 3,  # 熔断阈值：连续 3 次不可重试错误
}
```

---

## 4. Python 参考实现

```python
"""
error_classifier.py — 错误分类与结构化输出

用法:
    from error_classifier import classify_error, StructuredError
    
    try:
        os.makedirs(path)
    except Exception as e:
        err = classify_error(e, path=path, operation="mkdir")
        if err["retryable"]:
            # 执行重试逻辑
        else:
            logger.error(f"Unrecoverable: {err}")
```

### 4.1 StructuredError 类型定义

```python
from typing import Optional, Literal, TypedDict

ErrorCode = Literal[
    "E_EXISTS", "E_PERM", "E_NOSPC", "E_IO",
    "E_OOM", "E_TIMEOUT", "E_PATH_CONFLICT", "E_UNKNOWN"
]

ErrorLayer = Literal["os", "fs", "permission", "resource", "logic"]

ActionSuggestion = Literal[
    "report_to_user", "retry_with_backoff",
    "modify_params", "circuit_break", "escalate"
]

class StructuredError(TypedDict):
    code: ErrorCode
    layer: ErrorLayer
    retryable: bool
    suggestion: ActionSuggestion
    max_retries: int
    cooldown_seconds: int
    severity: int                     # 1-5, 5 最严重
    message: str                      # 人类可读描述
    errno: Optional[int]              # 原始 POSIX errno (如果有)
    path: Optional[str]               # 相关路径 (如果有)
    raw_exception: Optional[str]      # 原始异常字符串，用于调试
```

### 4.2 可重试性表 (内部查找)

```python
_RETRY_TABLE: dict[ErrorCode, tuple] = {
    "E_EXISTS":       (True,  "modify_params",     1, 0),
    "E_PERM":         (False, "report_to_user",     0, 0),
    "E_NOSPC":        (True,  "retry_with_backoff", 3, 5),
    "E_IO":           (True,  "retry_with_backoff", 2, 10),
    "E_OOM":          (False, "circuit_break",      0, 60),
    "E_TIMEOUT":      (True,  "modify_params",      1, 30),
    "E_PATH_CONFLICT":(False, "report_to_user",     0, 0),
    "E_UNKNOWN":      (False, "escalate",           0, 0),
}
```

### 4.3 classify_error 实现

```python
import errno
import os
from typing import Union


def _errno_to_code(e: OSError) -> ErrorCode:
    """Map POSIX errno to our ErrorCode."""
    mapping = {
        errno.EEXIST:      "E_EXISTS",
        errno.EACCES:      "E_PERM",
        errno.EPERM:       "E_PERM",
        errno.ENOSPC:      "E_NOSPC",
        errno.ENOMEM:      "E_OOM",
        errno.EIO:         "E_IO",
        errno.ENOTDIR:     "E_PATH_CONFLICT",
        errno.EISDIR:      "E_PATH_CONFLICT",
        errno.EROFS:       "E_PERM",    # Read-only fs → permission-like
        errno.ENAMETOOLONG:"E_PATH_CONFLICT",
        errno.ELOOP:       "E_PATH_CONFLICT",
        errno.ETIMEDOUT:   "E_TIMEOUT",
    }
    return mapping.get(e.errno, "E_UNKNOWN")


def _code_to_severity(code: ErrorCode) -> int:
    """Severity 1-5. 5 = system-level, unrecoverable."""
    return {
        "E_EXISTS":        1,
        "E_PERM":          3,
        "E_NOSPC":         4,
        "E_IO":            4,
        "E_OOM":           5,
        "E_TIMEOUT":       3,
        "E_PATH_CONFLICT": 2,
        "E_UNKNOWN":       5,
    }.get(code, 5)


def classify_error(
    exception: Union[Exception, int],
    path: Optional[str] = None,
    operation: Optional[str] = None,
) -> StructuredError:
    """
    将 Python 异常或 errno 整数分类为结构化错误。

    Args:
        exception: Python Exception 对象，或 POSIX errno 整数。
        path: 引发错误的文件路径（可选，用于丰富输出）。
        operation: 正在执行的操作名（可选，用于丰富输出）。

    Returns:
        完整的 StructuredError 字典。
    """
    # --- 处理裸 errno 整数 ---
    if isinstance(exception, int):
        code = _ERRNO_TO_CODE.get(exception, "E_UNKNOWN")
        return _build_error(code, path=path, errno=exception)

    # --- 处理 Python 异常 ---
    exc = exception

    # 常见内置异常
    if isinstance(exc, FileExistsError):
        code = "E_EXISTS"
    elif isinstance(exc, FileNotFoundError):
        # 注意: FileNotFoundError 在某些版本中是 OSError 的子类
        # 分类为 E_PERM + logic 层：需要创建父目录
        # 实际上 ENOENT 意味着 "存在性错误" — Agent 应先确保父目录存在
        code = "E_EXISTS"
    elif isinstance(exc, PermissionError):
        code = "E_PERM"
    elif isinstance(exc, MemoryError):
        code = "E_OOM"
    elif isinstance(exc, TimeoutError):
        code = "E_TIMEOUT"
    elif isinstance(exc, OSError):
        code = _errno_to_code(exc)
    else:
        code = "E_UNKNOWN"

    errno_val = exc.errno if isinstance(exc, OSError) else None
    return _build_error(
        code,
        path=path,
        errno=errno_val,
        raw_exception=f"{type(exc).__name__}: {exc}",
    )


def _build_error(
    code: ErrorCode,
    path: Optional[str] = None,
    errno: Optional[int] = None,
    raw_exception: Optional[str] = None,
) -> StructuredError:
    """Construct a StructuredError from a code and optional context."""
    retryable, suggestion, max_retries, cooldown = _RETRY_TABLE[code]

    layer: ErrorLayer = {
        "E_EXISTS":        "resource",
        "E_PERM":          "permission",
        "E_NOSPC":         "fs",
        "E_IO":            "fs",
        "E_OOM":           "os",
        "E_TIMEOUT":       "os",
        "E_PATH_CONFLICT": "logic",
        "E_UNKNOWN":       "os",
    }[code]

    severity = _code_to_severity(code)

    messages = {
        "E_EXISTS":        "路径已存在，使用幂等模式可解决",
        "E_PERM":          "权限不足，需要更高权限或更换路径",
        "E_NOSPC":         "磁盘空间不足，尝试清理后重试",
        "E_IO":            "存储 I/O 错误，可能是瞬时故障",
        "E_OOM":           "系统内存不足，需要熔断等待恢复",
        "E_TIMEOUT":       "操作超时，结果不确定",
        "E_PATH_CONFLICT": "路径类型冲突，Agent 推理需要纠正",
        "E_UNKNOWN":       "未识别的错误，需人工介入",
    }

    return StructuredError(
        code=code,
        layer=layer,
        retryable=retryable,
        suggestion=suggestion,
        max_retries=max_retries,
        cooldown_seconds=cooldown,
        severity=severity,
        message=messages[code],
        errno=errno,
        path=path,
        raw_exception=raw_exception,
    )
```

### 4.4 使用示例

```python
# === 示例 1: PermissionError ===
try:
    os.makedirs("/root/secret")
except Exception as e:
    err = classify_error(e, path="/root/secret", operation="mkdir")
    assert err == {
        "code": "E_PERM",
        "layer": "permission",
        "retryable": False,
        "suggestion": "report_to_user",
        "max_retries": 0,
        "cooldown_seconds": 0,
        "severity": 3,
        "message": "权限不足，需要更高权限或更换路径",
        "errno": 13,
        "path": "/root/secret",
        "raw_exception": "PermissionError: [Errno 13] Permission denied: '/root/secret'",
    }

# === 示例 2: 裸 errno ===
err = classify_error(28, path="/data/logs", operation="mkdir")
assert err["code"] == "E_NOSPC"
assert err["retryable"] == True
assert err["suggestion"] == "retry_with_backoff"
assert err["max_retries"] == 3

# === 示例 3: 未知异常 ===
err = classify_error(RuntimeError("something weird"))
assert err["code"] == "E_UNKNOWN"
assert err["retryable"] == False
assert err["suggestion"] == "escalate"
```

---

## 5. 决策流图 (Decision Flow Diagram)

```
                     ┌─────────────────────┐
                     │    Tool Error 发生    │
                     │  (返回码 ≠ 0 / 异常)  │
                     └──────────┬──────────┘
                                │
                                ▼
                     ┌─────────────────────┐
                     │   classify_error()   │
                     │  exception → struct  │
                     └──────────┬──────────┘
                                │
                     ┌──────────┴──────────┐
                     │                     │
                     ▼                     ▼
              ┌─────────────┐    ┌──────────────────┐
              │  retryable?  │    │  non-retryable    │
              │  (yes/once)  │    │  (no)             │
              └──────┬──────┘    └────────┬─────────┘
                     │                    │
                     ▼                    ├──────────────┬──────────────┐
          ┌────────────────────┐         ▼              ▼              ▼
          │  Apply suggestion  │   report_to_user  escalate   circuit_break
          │  + backoff logic   │         │              │              │
          └────────┬───────────┘    ┌────┴────┐   ┌────┴────┐   ┌────┴────┐
                   │                │  Return  │   │  Escalate│   │  Freeze │
                   ▼                │  to user │   │  to      │   │  all    │
          ┌─────────────────┐      │  + rec   │   │  human   │   │  ops    │
          │  decrement       │      └─────────┘   └─────────┘   │  for N  │
          │  max_retries     │                                   │  secs   │
          └────────┬────────┘                                   └─────────┘
                   │
          ┌────────┴────────┐
          │                 │
          ▼                 ▼
   ┌────────────┐   ┌──────────────┐
   │ retries > 0│   │ retries == 0 │
   └──────┬─────┘   └──────┬───────┘
          │                 │
          ▼                 ▼
   ┌──────────────┐  ┌──────────────┐
   │  Sleep(cool- │  │  Convert to  │
   │  down * 2^N) │  │  escalate    │
   └──────┬───────┘  └──────┬───────┘
          │                 │
          ▼                 ▼
   ┌──────────────┐  ┌──────────────┐
   │  Retry tool  │  │  Return to   │
   │  call        │  │  user/human  │
   └──────┬───────┘  └──────────────┘
          │
          ▼
   ┌──────────────────┐
   │  New result       │
   │  ┌─ success → ok  │
   │  └─ error → loop │
   └──────────────────┘
```

### 5.1 熔断状态机

```
                    ┌──────────┐
         start ──▶  │  CLOSED  │  ← 正常操作状态
                    └────┬─────┘
                         │ 连续 3 次不可重试错误
                         │ (E_PERM / E_OOM / E_UNKNOWN)
                         ▼
                    ┌──────────┐
                    │   OPEN   │  ← 拒绝所有文件操作
                    └────┬─────┘
                         │ cooldown_seconds 后
                         │ 允许一次 probe 操作
                         ▼
                    ┌──────────┐
                    │  HALF-   │  ← 探针操作
                    │  OPEN    │     成功 → CLOSED
                    └────┬─────┘     失败 → OPEN (重置冷却)
                         │
                         ▼
                    ┌──────────┐
                    │  CLOSED  │
                    └──────────┘
```

---

## 6. 与 ensure_directory 集成

错误分类系统是安全工具抽象层的诊断子系统。以下是 `ensure_directory` 如何调用分类器的完整集成。

### 6.1 集成后的 ensure_directory 实现

```python
import os
import stat as stat_module

def ensure_directory(path, mode=0o755, create_parents=True):
    """
    确保目录存在。幂等、安全、永远返回结构化结果。
    
    返回 EnsureDirectoryOutput (见 02-safe-tool-abstraction 规范)。
    """
    normalized = os.path.abspath(os.path.normpath(path))
    
    # === 阶段 1: 前置检查 ===
    try:
        existing_stat = os.lstat(normalized)
        if stat_module.S_ISDIR(existing_stat.st_mode):
            return {
                "ok": True,
                "path": normalized,
                "created": False,
                "existed_before": True,
                "error": None,
            }
        # 路径存在但不是目录 → E_PATH_CONFLICT
        return {
            "ok": False,
            "path": normalized,
            "created": False,
            "existed_before": True,
            "error": classify_error(
                OSError(errno.ENOTDIR, "Not a directory"),
                path=normalized,
                operation="ensure_directory",
            ),
        }
    except FileNotFoundError:
        pass  # 路径不存在，继续创建
    except PermissionError:
        return {
            "ok": False,
            "path": normalized,
            "created": False,
            "existed_before": False,
            "error": classify_error(
                PermissionError(errno.EACCES, "Permission denied"),
                path=normalized,
                operation="ensure_directory",
            ),
        }
    
    # === 阶段 2: 创建 ===
    try:
        if create_parents:
            os.makedirs(normalized, mode=mode, exist_ok=True)
        else:
            os.mkdir(normalized, mode=mode)
    except FileExistsError:
        # 竞态条件：检查后创建前其他进程创建了目录
        # 幂等确认
        if os.path.isdir(normalized):
            return {
                "ok": True,
                "path": normalized,
                "created": False,  # 不是本次创建的
                "existed_before": True,
                "error": None,
            }
    except PermissionError as e:
        err = classify_error(e, path=normalized, operation="ensure_directory")
        return {"ok": False, "path": normalized, "created": False,
                "existed_before": False, "error": err}
    except OSError as e:
        err = classify_error(e, path=normalized, operation="ensure_directory")
        return {"ok": False, "path": normalized, "created": False,
                "existed_before": False, "error": err}
    except MemoryError as e:
        err = classify_error(e, path=normalized, operation="ensure_directory")
        return {"ok": False, "path": normalized, "created": False,
                "existed_before": False, "error": err}
    except Exception as e:
        err = classify_error(e, path=normalized, operation="ensure_directory")
        return {"ok": False, "path": normalized, "created": False,
                "existed_before": False, "error": err}
    
    # === 阶段 3: 后置验证 ===
    try:
        final_stat = os.stat(normalized)
        if not stat_module.S_ISDIR(final_stat.st_mode):
            return {
                "ok": False,
                "path": normalized,
                "created": True,
                "existed_before": False,
                "error": {
                    "code": "E_PATH_CONFLICT",
                    "layer": "logic",
                    "retryable": False,
                    "suggestion": "report_to_user",
                    "message": f"Created path is not a directory: {normalized}",
                    # ... 其他字段 ...
                },
            }
        return {
            "ok": True,
            "path": normalized,
            "created": True,
            "existed_before": False,
            "error": None,
        }
    except Exception as e:
        return {
            "ok": False,
            "path": normalized,
            "created": True,
            "existed_before": False,
            "error": classify_error(e, path=normalized),
        }
```

### 6.2 Agent 侧的决策逻辑

```python
def agent_handle_ensure_directory_result(result):
    """
    Agent 处理 ensure_directory 返回结果的标准逻辑。
    适合注入到系统提示词或工具调用中间件。
    """
    if result["ok"]:
        return OPERATION_COMPLETE
    
    error = result["error"]
    
    if error["retryable"]:
        # --- 可重试错误的处理 ---
        if error["suggestion"] == "modify_params":
            if error["code"] == "E_EXISTS":
                # 重试调用，带 exist_ok=True (already done in makedirs)
                pass
            if error["code"] == "E_TIMEOUT":
                # 以更长超时重试
                return retry_with_timeout(result["path"], timeout=60)
        
        if error["suggestion"] == "retry_with_backoff":
            if error["max_retries"] > 0:
                wait = min(error["cooldown_seconds"] * 2**attempt, 60)
                sleep(wait)
                return retry_ensure_directory(result["path"])
        
        # 重试耗尽 → 转为 escalate
        return escalate_to_user(result, "重试耗尽")
    
    else:
        # --- 不可重试错误的处理 ---
        if error["suggestion"] == "report_to_user":
            return report_to_user(result)
        
        if error["suggestion"] == "circuit_break":
            circuit_breaker.trip()
            wait(error["cooldown_seconds"])
            probe_and_recover()
            return
        
        if error["suggestion"] == "escalate":
            return escalate_to_human(result)
```

### 6.3 集成架构总览

```
Agent (LLM)
  │
  │  调用 ensure_directory (Level 3 工具)
  ▼
┌─────────────────────────────────────┐
│  Safe Tool Abstraction Layer        │
│                                     │
│  ensure_directory()                 │
│    │                                │
│    ├─ 前置检查 (check state)        │
│    ├─ 执行操作 (os.makedirs)        │
│    ├─ 后置验证 (verify state)       │
│    │                                │
│    └─ 错误时 → classify_error()     │
│                  │                  │
│                  ├─ 映射 ErrorCode  │
│                  ├─ 分配 Layer      │
│                  ├─ 查 Retry Matrix │
│                  └─ 输出结构化      │
│                     StructuredError │
└──────────┬──────────────────────────┘
           │
           ▼
Agent (LLM) 收到结构化的 EnsureDirectoryOutput
  │
  ├─ error == None → Task done ✓
  │
  └─ error != None →
       ├─ retryable == true  → 按 suggestion 策略重试
       └─ retryable == false → 按 suggestion 策略上报/熔断
```

---

## 7. Bash/POSIX 映射

Pi Agent 等裸 bash 环境没有 Python 的分类能力。提供等价的 shell 函数，通过 `$?` 和 `errno` 实现相同分类。

### 7.1 classify_errno shell 函数

```bash
#!/bin/bash
# ============================================================
# classify_errno — 将 POSIX errno 分类为结构化 JSON 输出
#
# 用法:
#   mkdir /some/path 2>/dev/null
#   classify_errno $? "/some/path" "mkdir"
#
# 输出: JSON 对象 (与 Python StructuredError 兼容)
# ============================================================

classify_errno() {
    local exit_code="$1"
    local target_path="${2:-null}"
    local operation="${3:-null}"

    # 退出码 0 → 无错误
    if [ "$exit_code" -eq 0 ]; then
        printf '{"code":null,"retryable":false,"severity":0,"message":"success"}\n'
        return 0
    fi

    # bash 退出码 → errno 映射
    # bash 不会透传 errno，但常见退出码有约定:
    #   1  = EPERM (catch-all for "not permitted")
    #   2  = ENOENT (bash built-in convention)
    #   13 = EACCES
    #   17 = EEXIST
    #   28 = ENOSPC
    #   126 = Command invoked cannot execute (permission)
    #   127 = Command not found
    #   137 = SIGKILL (128 + 9) → OOM
    #   143 = SIGTERM (128 + 15)
    #   255 = Exit status out of range / tool crash

    local errno_val="null"
    local code=""
    local layer=""
    local retryable=""
    local suggestion=""
    local max_retries=0
    local cooldown=0

    case "$exit_code" in
        1)
            code="E_PERM"
            layer="permission"
            retryable="false"
            suggestion="report_to_user"
            max_retries=0
            cooldown=0
            ;;
        13)
            code="E_PERM"
            layer="permission"
            retryable="false"
            suggestion="report_to_user"
            max_retries=0
            cooldown=0
            ;;
        17)
            code="E_EXISTS"
            layer="resource"
            retryable="true"
            suggestion="modify_params"
            max_retries=1
            cooldown=0
            ;;
        20)
            code="E_PATH_CONFLICT"
            layer="logic"
            retryable="false"
            suggestion="report_to_user"
            max_retries=0
            cooldown=0
            ;;
        21)
            code="E_PATH_CONFLICT"
            layer="logic"
            retryable="false"
            suggestion="report_to_user"
            max_retries=0
            cooldown=0
            ;;
        28)
            code="E_NOSPC"
            layer="fs"
            retryable="true"
            suggestion="retry_with_backoff"
            max_retries=3
            cooldown=5
            ;;
        5)
            code="E_IO"
            layer="fs"
            retryable="true"
            suggestion="retry_with_backoff"
            max_retries=2
            cooldown=10
            ;;
        12)
            code="E_OOM"
            layer="os"
            retryable="false"
            suggestion="circuit_break"
            max_retries=0
            cooldown=60
            ;;
        124)  # timeout command exit code
            code="E_TIMEOUT"
            layer="os"
            retryable="true"
            suggestion="modify_params"
            max_retries=1
            cooldown=30
            ;;
        137)
            code="E_OOM"
            layer="os"
            retryable="false"
            suggestion="circuit_break"
            max_retries=0
            cooldown=60
            ;;
        126|127)
            code="E_PERM"
            layer="permission"
            retryable="false"
            suggestion="report_to_user"
            max_retries=0
            cooldown=0
            ;;
        255)
            code="E_UNKNOWN"
            layer="os"
            retryable="false"
            suggestion="escalate"
            max_retries=0
            cooldown=0
            ;;
        *)
            code="E_UNKNOWN"
            layer="os"
            retryable="false"
            suggestion="escalate"
            max_retries=0
            cooldown=0
            ;;
    esac

    # 构建描述消息
    local message=""
    case "$code" in
        "E_EXISTS")        message="路径已存在，使用幂等模式可解决";;
        "E_PERM")          message="权限不足，需要更高权限或更换路径";;
        "E_NOSPC")         message="磁盘空间不足，尝试清理后重试";;
        "E_IO")            message="存储 I/O 错误，可能是瞬时故障";;
        "E_OOM")           message="系统内存不足，需要熔断等待恢复";;
        "E_TIMEOUT")       message="操作超时，结果不确定";;
        "E_PATH_CONFLICT") message="路径类型冲突，Agent 推理需要纠正";;
        "E_UNKNOWN")       message="未识别的错误，需人工介入";;
    esac

    # 严重性
    local severity=1
    case "$code" in
        "E_EXISTS")        severity=1;;
        "E_PERM")          severity=3;;
        "E_NOSPC")         severity=4;;
        "E_IO")            severity=4;;
        "E_OOM")           severity=5;;
        "E_TIMEOUT")       severity=3;;
        "E_PATH_CONFLICT") severity=2;;
        "E_UNKNOWN")       severity=5;;
    esac

    # 输出 JSON (无外部依赖)
    printf '{\n'
    printf '  "code": "%s",\n' "$code"
    printf '  "layer": "%s",\n' "$layer"
    printf '  "retryable": %s,\n' "$retryable"
    printf '  "suggestion": "%s",\n' "$suggestion"
    printf '  "max_retries": %d,\n' "$max_retries"
    printf '  "cooldown_seconds": %d,\n' "$cooldown"
    printf '  "severity": %d,\n' "$severity"
    printf '  "message": "%s",\n' "$message"
    printf '  "errno": %s,\n' "$errno_val"
    printf '  "path": "%s",\n' "$target_path"
    printf '  "exit_code": %d\n' "$exit_code"
    printf '}\n'
}

# ============================================================
# ensure_directory — 幂等目录创建 (Bash 版)
# ============================================================
ensure_directory() {
    local path="$1"
    local mode="${2:-755}"
    local create_parents="${3:-true}"

    # 前置检查
    if [ -d "$path" ]; then
        printf '{"ok":true,"created":false,"existed_before":true,"error":null}\n'
        return 0
    fi

    # 路径存在但不是目录
    if [ -e "$path" ]; then
        local err
        err=$(classify_errno 21 "$path" "ensure_directory")
        printf '{"ok":false,"created":false,"existed_before":true,"error":%s}\n' "$err"
        return 1
    fi

    # 执行创建
    if [ "$create_parents" = "true" ]; then
        mkdir -p "$path" 2>/dev/null
    else
        mkdir "$path" 2>/dev/null
    fi
    local rc=$?

    if [ $rc -eq 0 ]; then
        printf '{"ok":true,"created":true,"existed_before":false,"error":null}\n'
        return 0
    fi

    # 分类错误
    local err
    err=$(classify_errno $rc "$path" "ensure_directory")
    printf '{"ok":false,"created":false,"existed_before":false,"error":%s}\n' "$err"
    return $rc
}
```

### 7.2 在 Pi Agent 提示词中使用

对于 Pi Agent 这种仅有 4 个工具的极致受限环境，在系统提示词中注入以下内容：

```
## 文件操作协议

每次执行 bash 命令后，必须执行:

    classify_errno $? "<path>" "<operation>"

并根据 JSON 输出的以下字段做决策:

1. 如果 "retryable": true 且 "max_retries" > 0:
   - 按照 "suggestion" 策略重试
   - 每次重试间隔 "cooldown_seconds" 秒
   - 重试次数不超过 "max_retries"
   - 重试耗尽后按 "suggestion" = "escalate" 处理

2. 如果 "retryable": false:
   - "suggestion": "report_to_user" → 向用户报告错误和建议
   - "suggestion": "circuit_break" → 停止所有操作，等待 cooldown_seconds
   - "suggestion": "escalate"      → 请求人工介入

3. 特殊规则:
   - E_EXISTS: 使用 mkdir -p 代替 mkdir (幂等模式)
   - E_PERM:   不要重试，不要尝试 sudo，向用户报告
   - E_OOM:    立刻停止，wait 60 秒后只执行一次 ls/probe
   - E_UNKNOWN: 不要重试，不要猜测，请求帮助
```

### 7.3 errno 获取技巧

在 bash 中获取准确的 errno 需要特殊处理，因为 shell 仅暴露退出码：

```bash
# 方法 1: 使用 strace (最准确，但开销大)
strace -e trace=mkdir mkdir /path 2>&1 | grep mkdir | grep -oP 'errno = \K\d+'

# 方法 2: 使用 python -c (推荐，Pi Agent 可见)
errno=$(python3 -c "
import os, sys
try:
    os.makedirs('$1')
except OSError as e:
    print(e.errno)
    sys.exit(0)
print(0)
")

# 方法 3: 使用 test 命令预检 (无 errno 但有状态)
# 适用于常见的 E_EXISTS 和 E_PERM
if [ -d "$path" ]; then echo "E_EXISTS"; exit 17; fi
if [ ! -w "$(dirname "$path")" ]; then echo "E_PERM"; exit 13; fi
```

**推荐**: 在 Pi Agent 环境下，使用方法 2 (python3 -c) 作为回退，因为 `$?` 的退出码值在不同 shell 和 distro 间不一致，而 Python 的 `errno` 属性是标准的。

---

## 8. 测试与验证

### 8.1 单元测试 (Python)

```python
import errno
import pytest
from error_classifier import classify_error, StructuredError

class TestClassifyError:
    def test_file_exists_error(self):
        e = FileExistsError(errno.EEXIST, "File exists: '/tmp/foo'")
        err = classify_error(e, path="/tmp/foo")
        assert err["code"] == "E_EXISTS"
        assert err["layer"] == "resource"
        assert err["retryable"] == True
        assert err["suggestion"] == "modify_params"

    def test_permission_error(self):
        e = PermissionError(errno.EACCES, "Permission denied")
        err = classify_error(e)
        assert err["code"] == "E_PERM"
        assert err["retryable"] == False

    def test_os_error_enospc(self):
        e = OSError(errno.ENOSPC, "No space left on device")
        err = classify_error(e)
        assert err["code"] == "E_NOSPC"
        assert err["retryable"] == True

    def test_memory_error(self):
        err = classify_error(MemoryError("Out of memory"))
        assert err["code"] == "E_OOM"
        assert err["retryable"] == False
        assert err["suggestion"] == "circuit_break"
        assert err["cooldown_seconds"] == 60

    def test_timeout_error(self):
        err = classify_error(TimeoutError("timed out"))
        assert err["code"] == "E_TIMEOUT"
        assert err["retryable"] == True

    def test_raw_errno(self):
        err = classify_error(28)  # ENOSPC
        assert err["code"] == "E_NOSPC"

    def test_unknown_exception(self):
        err = classify_error(RuntimeError("weird"))
        assert err["code"] == "E_UNKNOWN"
        assert err["retryable"] == False
        assert err["suggestion"] == "escalate"

    def test_severity_ranking(self):
        def severity(code):
            return classify_error(OSError(getattr(errno, code[2:]), ""))["severity"]
        # OOM 最严重
        assert severity("E_OOM") > severity("E_NOSPC")
        assert severity("E_NOSPC") > severity("E_PERM")
        assert severity("E_PERM") > severity("E_EXISTS")
```

### 8.2 集成测试 (Bash)

```bash
#!/bin/bash
# test_classify_errno.sh

source ./classify_errno.sh

# 测试: 退出码 0 → success
result=$(classify_errno 0)
echo "$result" | grep -q '"code": null' && echo "PASS: exit 0" || echo "FAIL: exit 0"

# 测试: 退出码 17 (EEXIST)
result=$(classify_errno 17 "/tmp/existing")
echo "$result" | grep -q '"code": "E_EXISTS"' && echo "PASS: exit 17" || echo "FAIL: exit 17"
echo "$result" | grep -q '"retryable": true' && echo "PASS: E_EXISTS retryable" || echo "FAIL: E_EXISTS retryable"

# 测试: 退出码 13 (EACCES)
result=$(classify_errno 13 "/root/secret")
echo "$result" | grep -q '"code": "E_PERM"' && echo "PASS: exit 13" || echo "FAIL: exit 13"
echo "$result" | grep -q '"retryable": false' && echo "PASS: E_PERM not retryable" || echo "FAIL: E_PERM not retryable"

# 测试: 实际 mkdir 场景
mkdir /tmp/_test_existing_dir 2>/dev/null
mkdir /tmp/_test_existing_dir 2>/dev/null
result=$(classify_errno $? "/tmp/_test_existing_dir")
echo "$result" | grep -q '"exit_code": 17' && echo "PASS: real mkdir EEXIST" || echo "FAIL: real mkdir EEXIST"
rmdir /tmp/_test_existing_dir 2>/dev/null
```

---

## 9. 错误码、层与死循环机理的交叉引用

参考 deadloop-taxonomy.md 中的 8 种触发场景，以下矩阵展示了错误分类如何**直接阻断**每种死循环：

| 死循环场景 (deadloop-taxonomy) | 触发条件 | 错误码 | 层 | 阻断机制 |
|-------------------------------|---------|--------|----|---------|
| 目录已存在 | `mkdir` → EEXIST | `E_EXISTS` | `resource` | `modify_params` 改为幂等模式，一次即止 |
| 权限不足 | `mkdir` → EACCES | `E_PERM` | `permission` | `retryable=false`，Agent 不重试，上报 |
| 父目录不存在 | `mkdir` → ENOENT | `E_EXISTS` | `resource` | 同 E_EXISTS 处理，创建父目录后重试一次 |
| 磁盘满 | `mkdir` → ENOSPC | `E_NOSPC` | `fs` | 有限次重试+冷却，耗尽后 escalate |
| OOM | fork 失败 | `E_OOM` | `os` | 熔断，禁止重试，等待系统恢复 |
| I/O 阻塞 | D 状态 | `E_TIMEOUT` / `E_IO` | `os` / `fs` | 超时后仅重试一次，仍失败则上报 |
| 工具崩溃 | segfault | `E_UNKNOWN` | `os` | 不可重试，直接 escalate |
| 路径名冲突 | 文件 vs 目录 | `E_PATH_CONFLICT` | `logic` | Agent 反思推理，修正后重试 |

> **核心洞察**: 8 种死循环场景中，有 5 种 (`E_PERM`, `E_OOM`, `E_UNKNOWN`, `E_PATH_CONFLICT`, `E_EXISTS` 在幂等模式下) 被分类为不可重试或一次重试即止。这意味着 **>60% 的 mkdir 死循环被分类系统直接消除**。剩余场景有严格的重试上限和冷却机制，防止无限循环。

---

## 附录 A: 严重性评级

| 严重性 | 标签 | 含义 | 示例错误 |
|--------|------|------|---------|
| 1 | info | 可以自动恢复，无需关注 | E_EXISTS (幂等后解决) |
| 2 | warning | Agent 需要调整行为 | E_PATH_CONFLICT |
| 3 | error | 需要用户注意 | E_PERM, E_TIMEOUT |
| 4 | critical | 系统资源问题 | E_NOSPC, E_IO |
| 5 | catastrophic | 系统级故障，需要人工介入 | E_OOM, E_UNKNOWN |

## 附录 B: 快速参考卡片

```
┌─────────────────────────────────────────────────────┐
│              错误分类快速参考                         │
├──────────┬──────────┬──────────┬────────────────────┤
│ 错误码    │ 层       │ 可重试    │ 建议动作            │
├──────────┼──────────┼──────────┼────────────────────┤
│ E_EXISTS  │ resource │ yes/once│ modify_params      │
│ E_PERM    │permission│ no       │ report_to_user     │
│ E_NOSPC   │ fs       │ yes(3x) │ retry_with_backoff │
│ E_IO      │ fs       │ yes(2x) │ retry_with_backoff │
│ E_OOM     │ os       │ no       │ circuit_break      │
│ E_TIMEOUT │ os       │ once     │ modify_params      │
│ E_PATH    │ logic    │ no       │ report_to_user     │
│ E_UNKNOWN │ os       │ no       │ escalate           │
└──────────┴──────────┴──────────┴────────────────────┘
```
