# 验证清单 (Verification Checklist)

## 1. 单元级验证 (Per Component)

### 1.1 classify_error (L3 — 错误分类)
- [ ] `classify_error(FileExistsError())` → `{code: "E_EXISTS", retryable: false, layer: "fs"}`
- [ ] `classify_error(PermissionError())` → `{code: "E_PERM", retryable: false, layer: "permission"}`
- [ ] `classify_error(FileNotFoundError())` → `{code: "E_PATH", retryable: false, layer: "logic"}`
- [ ] `classify_error(OSError(28, "No space"))` → `{code: "E_NOSPC", retryable: true, layer: "resource"}`
- [ ] `classify_error(MemoryError())` → `{code: "E_OOM", retryable: true, layer: "resource"}`
- [ ] `classify_error(TimeoutError())` → `{code: "E_TIMEOUT", retryable: true, layer: "os"}`
- [ ] `classify_error(OSError(5, "I/O error"))` → `{code: "E_IO", retryable: false, layer: "os"}`
- [ ] `classify_error(RuntimeError("unknown"))` → `{code: "E_UNKNOWN", retryable: false, layer: "os"}`
- [ ] `classify_errno(13)` (bash) → `{"code":"E_PERM","layer":"permission","retryable":"false"}`
- [ ] `classify_errno(17)` (bash) → `{"code":"E_EXISTS","layer":"fs","retryable":"false"}`

### 1.2 ensure_directory (L2 — 安全工具)
- [ ] 100 次 `ensure_directory("/tmp/test")` = 与 1 次相同结果 (幂等性)
- [ ] 首次调用: `{ok: true, created: true, existed_before: false}`
- [ ] 第二次调用: `{ok: true, created: false, existed_before: true}`
- [ ] 对文件路径调用: `{ok: false, error: {code: "E_PATH_CONFLICT"}}`
- [ ] 对 /root/foo (无权限) 调用: `{ok: false, error: {code: "E_PERM"}}`
- [ ] 深层路径 (50 级): 全部创建成功

### 1.3 guard_exec (L4 — 执行守卫)
- [ ] `guard_exec 5 "true"` → 返回结构化结果 (空命令但非空输出)
- [ ] `guard_exec 5 "./segfault"` → 非空输出, `error.code: "E_UNKNOWN"` 或检测到 SIGSEGV
- [ ] `guard_exec 5 "sleep 10"` → timeout 后返回, `error.code: "E_TIMEOUT"`
- [ ] `guard_exec 5 "kill -9 $$"` → 非空输出 (捕获 SIGKILL)
- [ ] Fork 失败场景: 兜底错误生成器产出有效 JSON

### 1.4 兜底错误生成器 (L4 — Last Resort)
- [ ] `/proc` 可用: 产生带 diagnostics 的完整 JSON
- [ ] `/proc` 不可用: 仍然产生 `{ok: false, error: {code: "E_SYSTEM_CATASTROPHE"}}`
- [ ] 生成器自身被 `chmod -x` 后: 仍可用 `bash /tmp/agent-fallback-error.sh` 执行
- [ ] 输出始终为合法 JSON (可用 `python3 -m json.tool` 解析)

## 2. 集成验证 (End-to-End)

### 2.1 deadloop-reproduction.sh
- [ ] 场景 1 (EEXIST): 触发, 分类正确, 标记 RETRYABLE=No, AGENT_WOULD_LOOP=Yes (w/o fix)
- [ ] 场景 2 (EACCES): 触发, 分类正确
- [ ] 场景 3 (ENOENT): 触发, 分类正确
- [ ] 场景 4 (ENOSPC): 触发或跳过 (需 root), 标记清晰
- [ ] 场景 5 (OOM): 触发或跳过, 标记清晰
- [ ] 场景 6 (I/O 阻塞): 触发, timeout 生效
- [ ] 场景 7 (工具崩溃): 触发, 非空输出
- [ ] 场景 8 (路径冲突): 触发, 分类正确
- [ ] 场景 9 (符号链接): 触发, 分类正确
- [ ] 脚本自清理无残留

### 2.2 ensure-directory-bench.py
- [ ] 所有 6 个测试场景运行
- [ ] ensure_directory 的 Success Rate = 100%
- [ ] ensure_directory 的 Idempotency = 100%
- [ ] ensure_directory 的 Error Clarity > Bare mkdir
- [ ] 输出 Markdown 格式表格

### 2.3 oom-simulation.sh
- [ ] Memory exhaustion 测试通过
- [ ] Fork bomb protection 测试通过
- [ ] Empty output validation: 0 个空输出
- [ ] Fallback generator: 始终输出 JSON
- [ ] `critical_gaps` 数组为 [] (零空隙)
- [ ] 最终 JSON report 的 tests_total = tests_passed (或跳过项被明确标记)

## 3. Pi Agent 专项验证

### 3.1 体积约束
- [ ] `agent-safe-fs.sh` 行数 < 200
- [ ] `agent-safe-fs.sh` 字节数 < 8KB
- [ ] Prompt injection 段 < 250 tokens
- [ ] Shell lib + Prompt 合计 < 500 tokens (留 300 tokens 给其他系统指令)

### 3.2 依赖约束
- [ ] 仅依赖 bash builtins + coreutils (mkdir, mv, rm, stat, cat, timeout)
- [ ] 不需要 python3, jq, curl 等外部工具
- [ ] 不需要 root 权限
- [ ] 不需要 /proc 也可运行（降级模式）

### 3.3 兼容性
- [ ] 在 bash 4.x (macOS) 上运行
- [ ] 在 bash 5.x (Linux) 上运行
- [ ] 在 busybox sh (Alpine/Pi) 上可降级运行

## 4. 回归测试

### 4.1 正常路径 (Happy Path)
- [ ] `ensure_directory /tmp/foo` → 目录创建, ok=true
- [ ] `ensure_file /tmp/bar.txt "hello"` → 文件创建, 内容正确
- [ ] `safe_remove /tmp/bar.txt` → 文件移入 Trash, ok=true
- [ ] Unicode 路径: `ensure_directory /tmp/测试目录` → 正常
- [ ] 空格路径: `ensure_directory "/tmp/my test dir"` → 正常

### 4.2 并发安全
- [ ] 10 个并发 `ensure_directory /tmp/concurrent-test` → 全部返回 ok=true
- [ ] 无竞态条件导致错误 (利用 tmpfile+mv 原子操作)

### 4.3 性能
- [ ] ensure_directory 延迟 < 10ms (normative case, 已存在目录)
- [ ] guard_exec 开销 < 5ms (仅 pre-flight 检查)
- [ ] classify_error 延迟 < 1ms

## 5. 故障模式覆盖 (Taxonomy → Coverage)

| # | 场景 | L1 | L2 | L3 | L4 | L5 | 覆盖? |
|---|------|:--:|:--:|:--:|:--:|:--:|:-----:|
| 1 | EEXIST | ✅ | ✅ | ✅ | — | ✅ | ✅ |
| 2 | EACCES | ✅ | ✅ | ✅ | — | ✅ | ✅ |
| 3 | ENOENT | ✅ | ✅ | ✅ | — | ✅ | ✅ |
| 4 | ENOSPC | ✅ | — | ✅ | ✅ | ✅ | ✅ |
| 5 | OOM | ✅ | — | ✅ | ✅ | ✅ | ✅ |
| 6 | I/O 阻塞 | ✅ | — | ✅ | ✅ | ✅ | ✅ |
| 7 | 工具崩溃 | ✅ | — | ✅ | ✅ | ✅ | ✅ |
| 8 | 路径冲突 | ✅ | ✅ | ✅ | — | ✅ | ✅ |
| 9 | 符号链接 | ✅ | ✅ | ✅ | — | ✅ | ✅ |

**覆盖率: 9/9 (100%)**
