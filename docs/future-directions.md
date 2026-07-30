# 后续研究方向与扩展方案

> 本文档为基于当前研究成果延伸的有价值后续方向。
> 每个方向标注：可行性、预计工作量、与当前方案的承接关系。

---

## 方向 1: Agent 工具调用形式化验证

**承接**: L3 错误分类层中的结构化输出契约
**可行性**: ★★★★ (中高)
**工作量**: 2-3 周

### 核心思路

当前方案确保"永远返回结构化 JSON"，但 JSON schema 的正确性依赖开发者自律。可以引入**轻量级形式化验证**:

```
工具输出 → JSON Schema 校验 → 不通过 → 兜底生成器
                ↓
              通过 → Agent 消费
```

### 具体方案

1. 为每个 ensure_* 工具定义 JSON Schema (已具备输出格式，只需加 schema 定义)
2. 在 guard_exec 的 Post-Call 阶段加 JSON Schema 校验
3. 校验失败 → 不返回原始输出给 Agent → 返回 `{ok: false, error: E_SCHEMA_VIOLATION}`

### 价值

- 防御工具输出格式漂移 (tool output drift)
- 在框架升级 / shell 库升级后自动检测破坏性变更
- **这是当前方案的自然延伸，仅需加一个校验步骤**

---

## 方向 2: Agent 工具调用的可观测性仪表盘

**承接**: L4 兜底方案中的 diagnostics 字段 + failure.log
**可行性**: ★★★★★ (高)
**工作量**: 1-2 周

### 核心思路

当前方案的 `error.diagnostics` 字段已携带 mem_available_mb, load_avg, d_state_procs, exit_code。将这些数据聚合起来，构建 Agent 健康度仪表盘。

### 具体方案

```
failure.log → logstash/vector → SQLite/InfluxDB → Grafana / CLI TUI
```

监控指标:
- **工具失败率**: 按 error code 分组 (E_PERM vs E_OOM — 性质完全不同)
- **重试率**: 按 retryable 分组 (可重试错误占比多少?)
- **系统健康度**: mem_available / load_avg 趋势
- **D 状态进程数**: 提前发现 I/O 问题

### 价值

- 运维视角：提前发现磁盘满、内存泄漏、NFS 挂载问题
- 开发视角：识别哪些错误码触发最多 → 优化工具封装
- **当前方案已产出了所有必要数据，只是缺少展示层**

---

## 方向 3: 多框架工具安全适配器

**承接**: L5 Pi Agent 适配层的方法论
**可行性**: ★★★ (中)
**工作量**: 4-6 周

### 核心思路

Pi Agent (bare bash)、Claude Code (sandbox bash)、OpenCode (subagent)、LangChain (Python) — 这四个框架的 `mkdir` 安全问题完全相同，但解决方案各异。将本方案的 shell library 抽象为适配器模式:

```
                    ┌── Pi Agent Adapter ──── bash source safe-fs.sh
Tool Safety Core ──┼── Claude Code Adapter ── skill + permission allowlist
(safe-fs.sh)       ├── OpenCode Adapter ──── subagent pre-prompt + MCP tool
                    └── LangChain Adapter ─── Python Tool wrapper
```

### 具体方案

1. **Core**: `safe-fs.sh` shell library (已有)
2. **Claude Code Adapter**: skill 定义 + settings.local.json 权限模板
3. **OpenCode Adapter**: MCP server 包装 safe-fs.sh
4. **LangChain Adapter**: Python `@tool` decorator 调用 subprocess

### 价值

- 一套核心逻辑，多框架复用
- 降低跨框架迁移时的重写成本
- **当前 shell library 已经是框架无关的**

---

## 方向 4: 基于强化学习的工具调用策略优化

**承接**: L3 错误分类矩阵中的 retry/backoff 参数
**可行性**: ★★ (较低，需大量训练数据)
**工作量**: 8-12 周

### 核心思路

当前 retry 参数 (max_retries, cooldown_seconds) 是静态的。不同 Agent、不同任务、不同系统状态下的最优 retry 策略是不同的。用 RL 学习动态 retry 策略:

```
State: (error_code, layer, mem_available, load_avg, retry_count, task_type)
Action: {retry_now, wait_and_retry, modify_params, report, escalate}
Reward: task_completed ? +1 : (deadloop_detected ? -10 : -1)
```

### 价值

- 长期: 自适应 retry 策略显著降低死循环率
- 短期: 从日志中分析 retry 模式，手工优化静态参数

---

## 方向 5: 声明式 Agent 操作规范语言 (Agent DSL)

**承接**: L2 设计哲学 "Agent 不应有'创建目录'的能力，而应有'确保目录存在'的能力"
**可行性**: ★★★ (中)
**工作量**: 6-8 周

### 核心思路

将 ensure_* 的设计哲学推广到所有 Agent 系统操作。定义一种极简声明式 DSL:

```yaml
# agent-manifest.yaml
ensure:
  - directory: /var/log/myapp
    mode: 0o755
  - file: /etc/myapp/config.yaml
    content: |
      server:
        port: 8080
  - permission: /var/log/myapp
    owner: myapp
    group: myapp
  - package: curl
    version: ">=7.0"
```

Agent 执行 `apply(manifest)` 而非逐步执行 `mkdir; chmod; echo > file; apt-get install`。

### 价值

- 从"过程式脚本"升级到"声明式目标状态"
- Manifest 本身是可版本控制、可 review 的
- 彻底消除 mkdir 死循环 (manifest engine 内置幂等)

---

## 方向 6: Agent 故障注入测试框架 (Chaos Agent)

**承接**: experiments/ 目录中的 deadloop-reproduction.sh 和 oom-simulation.sh
**可行性**: ★★★★ (中高)
**工作量**: 2-3 周

### 核心思路

将 9 种死循环场景系统化为故障注入测试套件:

```
chaos-agent inject --scenario EEXIST --target ensure_directory
chaos-agent inject --scenario OOM --target guard_exec
chaos-agent inject --all
```

每种注入产生报告:
```json
{
  "scenario": "OOM",
  "target": "ensure_directory",
  "raw_output": "...",
  "structured_output": {...},
  "empty_response": false,
  "correctly_classified": true,
  "agent_would_loop": false
}
```

### 价值

- CI/CD 集成: 每次 shell library 变更 → 自动跑 chaos 测试
- 新框架适配: 验证新适配器是否正确处理所有 9 种场景
- **experiments/ 目录已有脚本雏形，只需封装为框架**

---

## 方向 7: Agent 运行时沙箱 (最小权限原则)

**承接**: L2 三级架构中的 raw_* 禁止层
**可行性**: ★★★ (中)
**工作量**: 3-4 周

### 核心思路

不只是封装 mkdir——在 OS 级别隔离 Agent 的文件系统操作:

```
Agent → ensure_directory → [Landlock / seccomp / bubblewrap] → 实际系统调用
```

Linux Landlock (5.13+) 提供无特权文件系统沙箱:
```python
import landlock
rules = landlock.Ruleset()
rules.allow_read("/var/log")     # 只读特定目录
rules.allow_write("/tmp/agent")  # 只写特定目录
rules.apply()                    # 其他路径全部拒绝
```

### 价值

- 即使 Agent 绕过 ensure_directory 直接调 bash，OS 级别阻止危险操作
- 符合最小权限原则
- **是 L2 软件封装的硬件级补充**

---

## 方向 8: 跨 Agent 共享的错误知识图谱

**承接**: L3 错误分类中的 suggestion 字段
**可行性**: ★★★ (中)
**工作量**: 4-6 周

### 核心思路

每个 Agent 遇到的错误和解决方案是孤立的。建立共享知识图谱:

```
Agent A: EACCES /root/foo → suggestion: "使用用户目录 ~/.local/ 代替"
    ↓ 贡献到知识图谱
    ↓
Agent B: EACCES /root/bar → 查询知识图谱 → 直接获得同样的 suggestion
```

### 数据结构

```json
{
  "pattern": {"code": "E_PERM", "path_pattern": "/root/*"},
  "solution": "use ~/.local/ instead of /root/",
  "success_count": 15,
  "failure_count": 0,
  "last_seen": "2000-01-01"
}
```

### 价值

- 群体学习: 100 个 Agent 实例共享错误经验
- 冷启动: 新 Agent 从知识图谱获取已知解决方案
- **当前 suggestion 字段是种子数据**

---

## 方向 9: 工具调用预算与令牌经济学

**承接**: L5 中的 retry 预算机制
**可行性**: ★★★★ (中高)
**工作量**: 1-2 周

### 核心思路

给 Agent 分配"工具调用预算"，每次工具调用消耗令牌:

```
Agent 初始预算: 100 tokens
  ensure_directory: 1 token
  bare mkdir: 5 tokens (惩罚)
  重试: 3 tokens (递增)
  空响应: 10 tokens (高代价)
预算耗尽 → 强制报告用户
```

### 价值

- 让 Agent 天然倾向于安全工具 (更便宜)
- 防止重试消耗无限资源
- **在 ~800 token prompt 中只需加 3 行规则**

---

## 方向 10: 工具调用审计与溯源

**承接**: 整体方案的安全性
**可行性**: ★★★★★ (高)
**工作量**: 1 周

### 核心思路

记录每次工具调用的完整链路用于审计:

```json
{
  "timestamp": "2000-01-01T00:00:00Z",
  "session_id": "abc123",
  "tool": "ensure_directory",
  "input": {"path": "/tmp/foo"},
  "output": {"ok": true, "created": true},
  "layer_hit": "L2",  // 在 L2 就被幂等处理了
  "latency_ms": 3,
  "system_state": {"mem_mb": 512, "load": 1.2}
}
```

存入 SQLite → 支持查询: "过去 24h 有多少 E_PERM 错误？哪些路径？"

### 价值

- 安全审计: 谁在什么时候操作了什么文件
- 性能分析: 哪些工具调用最慢
- **可用现有 failure.log 扩展实现**

---

## 优先级推荐

| 优先级 | 方向 | 理由 |
|:---:|------|------|
| 🔴 P0 | 方向 9: 工具调用预算 | 最简单 (3行prompt), 立即生效 |
| 🔴 P0 | 方向 6: Chaos Agent 测试框架 | 基于已有实验脚本, CI 可集成 |
| 🟡 P1 | 方向 1: 形式化验证 | 自然延伸, 提高可靠性 |
| 🟡 P1 | 方向 2: 可观测性仪表盘 | 运维必需, 数据已就绪 |
| 🟢 P2 | 方向 10: 审计溯源 | 安全合规, 实现简单 |
| 🟢 P2 | 方向 3: 多框架适配器 | 扩大影响面 |
| 🔵 P3 | 方向 5: Agent DSL | 远景, 范式变革 |
| 🔵 P3 | 方向 7: 运行时沙箱 | 需要内核特性 (Landlock) |
| ⚪ Future | 方向 4: RL 策略优化 | 需大量训练数据 |
| ⚪ Future | 方向 8: 错误知识图谱 | 需多 Agent 部署生态 |
