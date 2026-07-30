# 外部参考资料索引

## 1. POSIX / Linux 系统参考

### errno.h 错误码
| 常量 | 值 | 含义 | 在本方案中的映射 |
|------|---|------|----------------|
| EACCES | 13 | Permission denied | E_PERM → layer:permission, retryable:false |
| EEXIST | 17 | File exists | E_EXISTS → layer:fs, retryable:false |
| ENOENT | 2 | No such file or directory | E_PATH → layer:logic, retryable:false |
| ENOSPC | 28 | No space left on device | E_NOSPC → layer:resource, retryable:once |
| EIO | 5 | I/O error | E_IO → layer:os, retryable:circuit_break |
| ENOMEM | 12 | Out of memory | E_OOM → layer:resource, retryable:once |
| ETIMEDOUT | 110 | Connection timed out | E_TIMEOUT → layer:os, retryable:yes |
| EAGAIN | 11 | Resource temporarily unavailable | E_TIMEOUT → layer:resource, retryable:yes |

- 完整参考: `man errno` 或 POSIX IEEE Std 1003.1

### /proc 文件系统
| 文件 | 内容 | 本方案用途 |
|------|------|----------|
| `/proc/meminfo` | 内存统计 (MemAvailable, MemTotal, Cached) | Pre-fork 内存检查 |
| `/proc/loadavg` | 系统负载 (1min/5min/15min + 运行/总进程数) | Pre-fork 负载检查 |
| `/proc/PID/status` | 进程状态 (State, VmRSS, Threads) | D 状态进程检测 |
| `/proc/PID/stat` | 进程统计 | 进程健康检查 |
| `/proc/sys/kernel/pid_max` | 最大 PID | 进程数上限检测 |

- 完整参考: `man 5 proc`

### cgroups v2
| 文件 | 用途 |
|------|------|
| `memory.max` | 内存硬限制 (bytes) |
| `memory.current` | 当前内存使用 |
| `pids.max` | 进程数上限 |
| `pids.current` | 当前进程数 |

- 参考: https://docs.kernel.org/admin-guide/cgroup-v2.html

### 信号处理
| 信号 | 值 | 触发| 本方案用途 |
|------|---|-----|----------|
| SIGALRM | 14 | alarm()/setitimer() | timeout watchdog |
| SIGKILL | 9 | kill -9 | OOM killer 触发检测 |
| SIGSEGV | 11 | 段错误 | 工具崩溃检测 |
| SIGCHLD | 17 | 子进程状态变化 | 子进程监控 |

- 参考: `man 7 signal`

## 2. AI Agent 工具安全

### Claude Code
- BashTool sandbox 机制: 隔离执行环境，捕获 stderr/stdout
- PreToolUse/PostToolUse 钩子系统: 拦截工具调用前后
- Permission 系统: allow/deny 列表控制危险操作
- 参考: Claude Code 官方文档 + `/root/.claude/settings.local.json` 中的配置模式

### OpenAI Function Calling
- 错误处理最佳实践: 在 function 返回中携带 error 字段而非抛异常
- 幂等性设计建议: 操作应是声明性的（"确保X存在"）而非过程性的（"创建X"）
- 参考: https://platform.openai.com/docs/guides/function-calling

### LangChain
- ToolException: 工具异常的标准包装
- 自定义错误处理: `handle_tool_error` 回调
- 参考: https://python.langchain.com/docs/how_to/tool_exception

### AutoGPT
- 命令插件安全指南: 白名单策略，禁止裸 shell 执行
- 参考: AutoGPT 官方文档

## 3. 韧性工程 (Resilience Engineering)

### Circuit Breaker 模式
- Michael Nygard, "Release It!" (2007)
- 三态: CLOSED → OPEN → HALF-OPEN
- 阈值: 失败率 > 50% → OPEN, 30s 后 → HALF-OPEN, 一次成功 → CLOSED
- 本方案应用: L3 错误分类层对 E_IO/E_OOM 实施熔断

### Google SRE 错误预算
- Error budget = 1 - SLO
- 预算耗尽 → 冻结发布
- 本方案类比: Agent 的 "重试预算" — 3 次重试上限 = 错误预算用尽

### Postel's Law (Robustness Principle)
- "Be conservative in what you send, liberal in what you accept"
- 本方案应用:
  - Conservative output: 工具始终输出结构化 JSON
  - Liberal input: 分类器接受多种错误格式 (exception, errno, stderr 文本)

### Netflix Hystrix
- 线程池隔离 + 超时 + 熔断
- Fallback 模式: 每个命令必须有 fallback
- 本方案类比: guard_exec timeout + fallback error generator

## 4. 相关内部工作

### 项目本身
- `01-root-cause-analysis/deadloop-taxonomy.md` — 9 场景死循环分类
- `02-safe-tool-abstraction/tool-abstraction-design.md` — 三级工具架构
- `03-error-classification/error-classification-system.md` — 8 码 5 层分类系统
- `04-graceful-degradation/extreme-condition-fallback.md` — 兜底方案
- `04-graceful-degradation/null-response-guard.md` — 空响应守卫
- `05-pi-agent-adaptation/pi-agent-constraints.md` — 框架约束分析
- `05-pi-agent-adaptation/minimal-implementation.md` — 最小可用实现
- `docs/explore-findings-intermediate.md` — 调研中间产物

### 内部记忆 (Knowledge Base)
- [[claude-interruption-resilience]] — 中断恢复三层架构
- [[claude-socket-error-elimination]] — Socket 错误四层防御
- [[state-machine-quality-gate-loop]] — 7 状态质量门控回环
- [[fan-out-subagent-pattern]] — Fan-Out 并行分发模式
- [[occams-razor-principle]] — 奥卡姆剃刀设计原则
- [[claude-code-preflight-checklist]] — 操作前强制检查清单
- [[deploy-workflow-write-to-repo-first]] — 先仓库后部署工作流

## 5. Pi Agent / 边缘 AI

### Raspberry Pi 资源约束
- Pi 4B: 4GB RAM (其中~3GB 可用), 4 核 Cortex-A72
- Pi Zero 2W: 512MB RAM
- SD 卡写入寿命: ~10,000-100,000 次擦写循环 → 减少不必要的文件操作
- 参考: Raspberry Pi 官方文档

### Termux / PRoot
- Android 进程管理: OOM 调整 (oom_score_adj), cgroup 限制
- PRoot 限制: ptrace 不可用, /proc 部分可用
- 参考: [[claude-code-environment-architecture]]

### 边缘推理资源管理
- 内存分级: GREEN (>500MB) / YELLOW (200-500MB) / RED (<200MB) / DENY (<100MB)
- 子进程上限: 2 并发 (Pi), 5 并发 (云)
- 参考: `/root/.claude/resource-protocol.md`
