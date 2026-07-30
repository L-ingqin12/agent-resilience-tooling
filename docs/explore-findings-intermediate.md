# Explore 调研中间产物 — 关键发现汇总

> 本文档记录 3 个并行 Explore 子智能体的调研结果，作为后续设计的依据和交叉验证源。
> 调研日期: 2000-01-01

## 来源 1: 工作区现有 Agent 研究 (`agent-knowledge-base/`, `agent-learn/`)

### 已有防死循环机制

| 机制 | 来源文件 | 核心参数 |
|------|---------|---------|
| 收益递减检测 | `agent-resilience-architecture-analysis.md` | 3 次连续重跑产出 < 500 新 token → 终止 |
| 重启上限 + 冷却 | `claude-interruption-resilience-guide.md` | MAX_RESTARTS=5, COOLDOWN=60s |
| 网络预检 | `claude-network-resilience-design.md` | 启动前检查连通性，避免 crash-loop |
| D 状态检测 | `docs/production-diagnosis-2026-07-06.md` | 发现 D 状态进程完全未被监控 |
| 交互拒绝死循环 | `docs/subagent-lessons-learned-2026-07-03.md` | DENY→interactive→DENY 循环，已修复 |

### 现有错误分层架构

```
Layer 1 (Tool-level): Shell 失败、文件未找到、MCP 超时 → 作为 tool_result 返回，不抛异常
Layer 2 (Query-level): 流失败、429 限速、prompt 溢出 → 友好消息 + 降级/重试
Layer 3 (System-level): SSL 错误、API 过载、认证失败 → 遍历 cause chain，必要时熔断
```

### 错误分类与诊断

- **O-H-V-C 协议** (`agent-learn/agent_learn/analysis_agent.py`): Observe→Hypothesize→Verify→Conclude
- **预置 FailureMode**: InfiniteLoop, AuthError, RateLimit, TimeoutError, BadRequest
- **Severity 分级**: CRITICAL / HIGH / MEDIUM / LOW
- **Evidence reliability 评分**: 0-1 置信度

### 重试策略

| 类型 | 策略 |
|------|------|
| 快速失败 | 401/403/400 → 不重试 |
| 指数退避 + jitter | 429/529 → backoff |
| 降级切换 | 流失败→同步, prompt溢出→压缩, Opus→Sonnet |
| 前后台区分 | 529 前台重试，后台跳过（防止放大 3-10x） |

### 关键教训

1. **Errors as input signals, not exceptions** — 工具错误是 LLM 的感知输入，不是程序异常
2. **Graceful degradation over crash** — 降级链优于崩溃
3. **Externalized state** — 任务进度在文件中而非内存中
4. **Fail-open by default** — 门控和限流默认放行
5. **Advisory not enforcement** — 钩子引导而非强制，所有钩子带 `|| true`

## 来源 2: Claude Code 错误处理模式

### 中间件/钩子系统

```
PreToolUse:
  - Bash: agent-gate.sh acquire auto --try-only (资源锁)
  - Agent: agent-gate.sh check (子智能体门控)

PostToolUse:
  - Bash: agent-gate.sh release acquired (释放资源锁)

SessionStart:
  - version-hook.sh full (版本检查)
  - agent-gate.sh cleanup + mark-idle
```

### 现有安全实践

- **原子文件操作**: tmpfile + mv 模式
- **备份优先**: 编辑前创建 .bak 文件
- **超时保护**: curl 带 --connect-timeout, git 带 timeout
- **静默保护**: `GIT_TERMINAL_PROMPT=0` 防止交互式 hang
- **出口码捕获**: `echo "EXIT:$?"` 模式

### AEON 演化系统信号

- `stuck_loop`: 强度 0.9（最高失败信号）
- `tool_error`: 强度 0.7，标记为 `context_sensitive`
- fitness_threshold: 0.7, rollback_threshold: 0.1

## 来源 3: Pi Agent 框架画像

### 约束摘要

| 维度 | 限制 |
|------|------|
| 工具数量 | 4 (read/write/edit/bash) |
| 系统提示词 | ~800 tokens |
| 自定义工具 API | 无 |
| 沙箱 | 无 |
| 中间件 | 无原生支持 |
| 技能系统 | 可能有（待确认） |
| 目标环境 | Raspberry Pi (512MB) ~ 云服务器 |

### 与现有框架对比

| 特性 | Pi Agent | Claude Code | OpenCode |
|------|----------|-------------|----------|
| 工具数 | 4 | 10+ | 可扩展 |
| 沙箱 | ❌ | ✅ | 部分 |
| 钩子 | ❌ | ✅ (PreToolUse/PostToolUse) | ✅ |
| 插件 | ❌ | ✅ | MCP |
| 资源门控 | ❌ | agent-gate.sh | 无 |

### Pi Agent 补丁路径（从简到繁）

1. **Prompt Only**: 800 token 嵌入规则 (最简但脆弱)
2. **Shell Library + Prompt**: 预置 safe-fs.sh + 简短 prompt (推荐)
3. **Middleware**: 拦截 bash 工具调用 (最健壮但需框架改动)

## 关键交叉引用

- [[state-machine-quality-gate-loop]] — 7 状态 + RETRY/ESCALATE，重试上限 3，总轮次上限 10
- [[fan-out-subagent-pattern]] — 并行分发，不同文件零冲突
- [[occams-razor-principle]] — 从简到繁，用现有工具组合
- [[claude-code-preflight-checklist]] — 5 项检查 + 5 条硬规则
