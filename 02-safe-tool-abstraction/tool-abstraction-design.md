# 安全工具抽象层设计 (Safe Tool Abstraction)

## 1. 设计哲学

> "Agent 不应该有'创建目录'的能力，而应该有'确保目录存在'的能力。"

这是一个关键的语义转换：从**过程性指令**（容易出现部分失败）转向**声明性目标**（幂等、可检测最终状态）。

## 2. 工具分级架构

```
Level 3: ensure_* 系列 (Agent 只暴露这层)
  ├── ensure_directory(path)
  ├── ensure_file(path, content?)
  ├── ensure_permission(path, mode)
  └── ensure_path_accessible(path)
       │
Level 2: safe_* 系列 (幂等封装，内部使用)
  ├── safe_mkdir(path)    → 幂等安全版
  ├── safe_write(path)    → 原子写入
  ├── safe_chmod(path)    → 仅当需要时修改
  └── safe_rm(path)       → 垃圾桶式删除
       │
Level 1: raw_* 系列 (原生能力，禁止 Agent 直接调用)
  ├── bash / exec
  ├── fs_mkdir
  └── fs_write
```

## 3. ensure_directory 规范

```typescript
interface EnsureDirectoryInput {
  path: string;          // 目标路径（绝对路径）
  mode?: number;         // 权限位，默认 0o755
  create_parents?: boolean; // 是否递归创建父目录，默认 true
}

interface EnsureDirectoryOutput {
  ok: boolean;           // 最终目录是否存在且可访问
  path: string;          // 规范化后的绝对路径
  created: boolean;      // 本次是否实际创建了新目录
  existed_before: boolean; // 调用前是否已经存在
  error: null | {
    code: ErrorCode;     // 结构化错误码（见 error-classification）
    layer: "os" | "fs" | "permission" | "resource" | "logic";
    retryable: boolean;
    suggestion: string;  // 人类可读建议
  };
}
```

## 4. 幂等实现伪代码

```python
def ensure_directory(path, mode=0o755, create_parents=True):
    """
    确保目录存在。幂等、安全、永远返回结构化结果。
    """
    try:
        # 1. 检查当前状态
        stat_before = safe_stat(path)

        if stat_before and stat.isdir(stat_before):
            return {
                ok: True, path: normalize(path),
                created: False, existed_before: True,
                error: None
            }

        if stat_before and not stat.isdir(stat_before):
            return {
                ok: False, path: normalize(path),
                created: False, existed_before: False,
                error: {
                    code: "E_PATH_CONFLICT",
                    layer: "logic",
                    retryable: False,
                    suggestion: f"路径已存在但不是目录: {stat.type}"
                }
            }

        # 2. 尝试创建
        os.makedirs(path, mode=mode, exist_ok=True)

        # 3. 验证最终状态
        stat_after = os.stat(path)
        return {
            ok: True, path: normalize(path),
            created: True, existed_before: False,
            error: None
        }

    except PermissionError:
        return structured_permission_error(...)
    except OSError as e:
        return structured_os_error(e, ...)
    except MemoryError:
        return structured_oom_error(...)
    except:
        return structured_unknown_error(...)
```

## 5. 禁止裸调规则

在 Agent 系统提示词中注入：

```
FILE OPERATIONS:
- NEVER use `mkdir` directly. Use `ensure_directory` tool.
- NEVER use `rm -rf`. Use `safe_remove` tool.
- NEVER check file existence with `test -f` before writing. Use `ensure_file`.
- If a tool returns `error.retryable == false`, STOP and report to user.
- If a tool returns `error.layer == "resource"`, wait 5 seconds before one retry, then STOP.
```

## 6. 对 bare-bash 框架的补丁方案

如果框架不支持自定义工具（如 Pi Agent 仅 4 个工具），则通过以下方式实现：

1. **Prompt 注入**: 在系统提示词中嵌入 shell 函数定义，Agent 每次执行前需 `source` 或 inline 调用
2. **技能包裹**: 创建 `ensure-directory` 技能，内部实现完整错误处理
3. **中间件劫持**: 拦截 bash 工具调用，自动替换 `mkdir` 为包装函数
