# 多场景防御矩阵：按控制面可用性选择方案

> **核心思想**: 不要预设框架有什么能力。枚举所有可能的控制面组合，对每种组合给出最优方案。
> 用户根据自己框架的实际能力，查表选取。

## 1. 控制面定义

Agent 框架可能提供的 6 种控制面：

| # | 控制面 | 说明 | 示例 |
|---|--------|------|------|
| C1 | 系统提示词 (System Prompt) | 可注入规则到 Agent 的系统消息 | agents.md, system message |
| C2 | 技能定义 (Skill) | 可定义可复用操作模板，按需加载 | Claude Code Skill, OpenAI GPT Action |
| C3 | 自定义工具 (Custom Tool) | 可添加新工具到 Agent 的工具集 | MCP tool, function calling |
| C4 | 中间件/钩子 (Hook) | 可在工具调用前后执行代码 | PreToolUse, PostToolUse |
| C5 | 命令拦截 (Command Interception) | 可拦截/修改/包装 bash 调用 | shell wrapper, proxy |
| C6 | 系统沙箱 (OS Sandbox) | OS 级别隔离和限制 | Landlock, seccomp, cgroups, Docker |

## 2. 能力层级与防护率

```
控制面越多 → 防护越可靠

C1 only:           ████████░░░░░░░░░░░░  ~60%  纯 prompt 规则
C1+C2:             ████████████░░░░░░░░  ~75%  prompt + skill 模板
C1+C2+C3:          ████████████████░░░░  ~85%  + 自定义安全工具
C1+C2+C3+C4:       ██████████████████░░  ~92%  + 钩子强制执行
C1+C2+C3+C4+C5:    ████████████████████  ~97%  + 命令级拦截
C1+C2+C3+C4+C5+C6: ████████████████████  ~99%  + OS 级沙箱 (理论极限)

注意: 没有 100%。内核 panic、硬件故障、电网断电无法在工具层防御。
```

## 3. 全场景矩阵

### 场景总览

| 场景 | C1 Prompt | C2 Skill | C3 Tool | C4 Hook | C5 Cmd Intercept | C6 Sandbox | 防护率 | 典型框架 |
|:----:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|------|
| S0 | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | 0% | 裸 LLM |
| S1 | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ~60% | Pi Agent 最小模式 |
| S2 | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | ~75% | Pi Agent + Skill |
| S3 | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ | ~85% | OpenAI GPT, LangChain |
| S4 | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ | ~92% | Claude Code |
| S5 | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ~97% | Claude Code + agent-gate |
| S6 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ~99% | Docker + Landlock |

### 场景 S0: 零控制面 — 裸 LLM

**条件**: 只有模型本身，无任何工具、无任何 prompt 注入。

**方案**: 无法防御。Agent 的行为完全依赖模型的对齐训练。如果模型被要求使用 mkdir，且出现错误，模型可能自主重试。

**唯一可做**: 在 user message 级别嵌入安全指令（但这是用户输入，不是系统控制）。

---

### 场景 S1: 仅 Prompt (C1) — Pi Agent 最简模式

**条件**:
- ✅ 可编辑 agents.md / system prompt (~800 tokens)
- ❌ 无 Skill、无自定义工具、无钩子、无拦截、无沙箱
- 只有 4 个原生工具: read / write / edit / bash

**可用方案**:

| 组件 | 内容 | Token 预算 |
|------|------|:---:|
| Exit Code 映射表 | mkdir 常见退出码 → 分类 → 决策 | ~150 |
| STOP 条件 | 何时必须停止（空输出/2次同错/3次同路径） | ~150 |
| mkdir -p 规则 | 始终使用 `mkdir -p` (天然幂等) | ~50 |
| test-before-act | 操作前检查状态 | ~100 |
| 反例锚定 | 3 个最常死循环场景的错误示例 | ~200 |
| 结构化报告格式 | 停止时输出格式 | ~100 |

**总计**: ~750 tokens (在 800 token 预算内)

**具体实现**: 见 `prompt-only-defense.md` 中的 Layer C1 完整模板

**不可防御的场景**:
- LLM 在长对话中遗忘 prompt 规则 (context window 后移)
- OOM 导致的空输出 (prompt 规则依赖 LLM 自主识别空输出，但空输出本身不可控)

**弥补措施**: 在 user 的第一条消息中重复核心 STOP 规则作为 "置顶提醒"

---

### 场景 S2: Prompt + Skill (C1+C2)

**条件**: 在 S1 基础上增加了 Skill 定义能力

**可用方案**: S1 全部 + Skill 加持

| 新增组件 | 内容 | 效果 |
|---------|------|------|
| safe-file-ops Skill | 预检 → 执行 → 分类 完整模板 | 操作前加载，规则不被稀释 |
| Skill trigger 规则 | 检测到 mkdir/rm/dd 关键词 → 触发 Skill | 自动化 |

**分工**:
- agents.md: 决策规则 (何时停、如何分类) → 始终在上下文中
- Skill: 操作模板 (具体的 bash 代码模式) → 按需加载

**具体实现**: 见 `prompt-only-defense.md` 中的 Layer C1 + C2 完整模板

**防护率提升**: S1 (~60%) → S2 (~75%)

---

### 场景 S3: Prompt + Skill + 自定义工具 (C1+C2+C3)

**条件**: 可以注册新工具 (如 MCP tool, function calling)

**这是安全方案的最佳性价比点** —— 加一个工具，防护率跃升。

**可用方案**:

```
新增工具:
  ensure_directory(path, mode?, create_parents?)
  ensure_file(path, content?)
  safe_remove(path)

每个工具的返回值是结构化 JSON:
  {ok, path, created, existed_before, error: {code, layer, retryable, suggestion}}
```

**具体实现**: 见 `02-safe-tool-abstraction/tool-abstraction-design.md` + `03-error-classification/error-classification-system.md`

**agents.md 精简为**:
```markdown
FILE OPERATIONS:
- Use ensure_directory, ensure_file, safe_remove tools
- NEVER use bash for file operations
- If tool returns error.retryable=false → report and STOP
- If tool returns empty → report E_SYSTEM_CATASTROPHE and STOP
```
仅需 ~100 tokens (vs S1 的 ~750 tokens)

**防护率**: ~85%

---

### 场景 S4: + 中间件/钩子 (C1+C2+C3+C4)

**条件**: 可以在工具调用前后执行自定义代码 (如 Claude Code 的 PreToolUse/PostToolUse)

**可用方案**:

```
PreToolUse (Bash):
  → 扫描命令中的危险模式 (mkdir, rm, dd, mkfs, shutdown)
  → 自动替换: mkdir → ensure_directory_wrapper
  → 注入: exec 前 source ~/.agent/safe-fs.sh
  → 记录: 所有 bash 调用写入 audit log

PostToolUse (Bash):
  → 检查退出码
  → 输出为空 → 注入结构化错误消息
  → 记录: 延迟、退出码、系统状态
```

**具体实现**: 见 `04-graceful-degradation/null-response-guard.md` (guard_exec) + `05-pi-agent-adaptation/pi-agent-constraints.md` (Tier 3 Middleware)

**防护率**: ~92%

---

### 场景 S5: + 命令拦截 (C1+C2+C3+C4+C5)

**条件**: 可以安装 shell wrapper / proxy 来拦截所有 bash 调用

**可用方案**:

```
Agent 调用 bash → wrapper 拦截 → 检查命令
  ├── 安全命令 (cat, echo, grep...) → 直接执行
  ├── 文件创建命令 (mkdir, touch, cat >) → 强制注入 ensure_* wrapper
  ├── 危险命令 (rm -rf, dd, mkfs) → 拒绝 + 结构化错误
  └── 未知命令 → 允许但记录
```

**具体实现**: 见 `04-graceful-degradation/` 下的 guard_exec (Bash 实现) 和 Python wrapper

**防护率**: ~97%

---

### 场景 S6: + OS 沙箱 (C1 到 C6 全)

**条件**: Docker / Landlock / seccomp / cgroups 可用

**这是终极方案**，OS 级别隔离作为最后一道防线：

```
Agent → ensure_directory → [Landlock: 仅允许 /var/agent/* 写入]
                         → [cgroups: 内存限制 512MB, 进程数限制 10]
                         → [timeout: 30s 硬超时]
                         → [seccomp: 禁止 mount, reboot, kernel modules]
```

即使 Agent 绕过所有上层防护，OS 层阻止危险系统调用。

**防护率**: ~99% (内核 panic 和硬件故障无法防御)

---

## 4. 快速选择指南

```
你的框架支持什么？按此流程确定场景：

1. 能编辑系统提示词吗？
   ├── 否 → S0 (无法防御)
   └── 是 → 继续

2. 能定义 Skill / 可复用模板吗？
   ├── 否 → S1 (仅 Prompt, ~60%)
   └── 是 → 继续

3. 能注册自定义工具吗？
   ├── 否 → S2 (Prompt + Skill, ~75%)
   └── 是 → 继续

4. 有 PreToolUse / PostToolUse 钩子吗？
   ├── 否 → S3 (Prompt + Skill + Tool, ~85%)
   └── 是 → 继续

5. 能拦截/包装 bash 调用吗？
   ├── 否 → S4 (+ Hook, ~92%)
   └── 是 → 继续

6. 有 OS 级沙箱吗 (Docker/Landlock/cgroups)？
   ├── 否 → S5 (+ Cmd Intercept, ~97%)
   └── 是 → S6 (全能力, ~99%)
```

## 5. 方案文件索引

根据你的场景，查阅对应文件：

| 场景 | 技术防护参考 | 认知引导参考 |
|:----:|------|------|
| S1 | N/A (无技术手段) | `prompt-only-defense.md` + `llm-cognitive-guidance.md` (全量C1+C2+C3, ~750tokens) |
| S2 | `prompt-only-defense.md` (Skill模板) | `llm-cognitive-guidance.md` (C1+C2, ~500tokens) |
| S3 | `tool-abstraction-design.md` + `error-classification-system.md` | `llm-cognitive-guidance.md` (C1精简, ~150tokens) |
| S4 | `null-response-guard.md` + `pi-agent-constraints.md` | `llm-cognitive-guidance.md` (C1极简, ~80tokens) |
| S5 | `extreme-condition-fallback.md` + `agent-safe-fs.sh` | `llm-cognitive-guidance.md` (核心概念, ~50tokens) |
| S6 | 本文档 S6 + `external-resources.md` | `llm-cognitive-guidance.md` (返回值概念, ~30tokens) |

> **原则**: 技术防护越强，认知引导可越精简。但认知引导永远不应为零。

## 6. 各场景核心约束与应对

### 所有场景的通用原则

无论控制面多少，三条铁律不变：

1. **永远返回结构化结果** — bash 输出必须包含 `EXIT:$?` 或 JSON
2. **空输出 = 灾难** — 不是"未执行"，而是"系统濒临崩溃"
3. **分类先于重试** — 不知道错误类型就重试 = 赌博

### 仅 Prompt 场景的救命稻草

当所有技术手段都不可用时，最后防线是**认知锚定**：

- **Exit Code 映射表嵌入 prompt**: 给 LLM 一个"查表决策"的能力
- **反例 Few-Shot**: 展示 3 个死循环 → LLM 模式匹配避免
- **STOP 条件具象化**: 不是 "don't loop"，而是 "if same path 3 times, STOP"

### 有 Tool 注入的场景的关键抉择

一旦可以加自定义工具，**不要把安全逻辑放在 prompt 中**:

```
❌ prompt: "用 mkdir -p，检查 exit code，如果是 EEXIST 就不要重试..."
✅ tool:   ensure_directory(path) → 内部处理所有逻辑 → 返回 {ok, error}
```

原因: prompt 规则可以被遗忘，tool 的返回值永远在上下文中。
