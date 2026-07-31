# Skill 迁移指南：单 Agent → 主监控 + 子执行

## 一、架构对比

```
【旧架构】单 Agent Skill（主Agent自己干活）
─────────────────────────────────────────
User: "创建 /tmp/app 项目结构"
    │
Main Agent (加载 safe-file-ops Skill):
  → source safe-fs.sh
  → ensure_directory /tmp/app          ← 自己执行
  → 检查返回值                          ← 自己判断
  → ensure_file /tmp/app/config.yaml   ← 自己执行
  → 如果失败 → 自己决定重试还是换方案   ← 自我反省（困难）
  → 如果死循环 → 自己检测自己           ← 最难点

问题：
  - LLM 必须检测自己的死循环（自我指涉）
  - 长上下文下 LLM 可能遗忘规则
  - 一个操作失败可能污染后续判断


【新架构】主监控 + 子执行（主Agent只管调度）
─────────────────────────────────────────
User: "创建 /tmp/app 项目结构"
    │
Main Agent (加载 main-monitor Skill):
  │
  ├── 解析任务 → [step1, step2, step3]
  │
  ├── Step 1: spawn Sub-Agent("ensure_directory /tmp/app")
  │   │         Sub-Agent: 执行 → 返回 JSON → 退出
  │   │         Main: evaluate JSON → RELIABLE → save checkpoint
  │   │
  ├── Step 2: spawn Sub-Agent("ensure_file /tmp/app/config.yaml")
  │   │         Sub-Agent: 执行 → 返回 JSON → 退出
  │   │         Main: evaluate JSON → RELIABLE → save checkpoint
  │   │
  └── Step 3: spawn Sub-Agent("ensure_directory /tmp/app/logs")
              Sub-Agent: 返回 {"ok":false,"error":{"code":"E_PERM"...}}
              Main: evaluate → RELIABLE but non-retryable
              Main: switch strategy → spawn NEW Sub-Agent
              Sub-Agent 2: 返回 {"ok":true}
              Main: RELIABLE → save checkpoint → DONE

优势：
  - 死循环检测 = 外部观察（主Agent看子Agent输出）
  - 子Agent上下文隔离（失败不污染主Agent）
  - 策略切换由主Agent显式控制（非LLM自我反省）
```

## 二、迁移对照表

| 原始 Skill 内容 | 迁移到 | 新位置 |
|---------------|--------|--------|
| 操作模板 (ensure_directory怎么用) | → Sub-Agent Worker | `subagent-worker/SKILL.md` |
| 错误分类表 (exit code → action) | → Main Monitor | `main-monitor/SKILL.md` + `monitor-guard.sh` |
| 重试规则 (什么时候重试/什么时候停) | → Main Monitor | `main-monitor/SKILL.md` Phase 3 |
| 策略切换 (mkdir失败 → python3) | → Main Monitor | `main-monitor/SKILL.md` Phase 4 |
| 死循环识别 | → Main Monitor | `monitor-guard.sh` (外部观察) |
| 断点保存/恢复 | → Main Monitor | `agent-checkpoint.sh` (不变) |
| 安全函数本身 | → 共享 | `agent-safe-fs.sh` (不变，两个Skill都用) |

## 三、具体迁移步骤

### Step 1: 拆分 SKILL.md

**原始** (`safe-file-ops/SKILL.md`):
```markdown
# Safe File Operations
## When to Use
Trigger on: mkdir, create directory, write file...

## Operation Templates
### Creating a Directory
```bash
ensure_directory "/path"
```

## Error Classification
| Exit | Meaning | Action |
|------|---------|--------|
| 1 | Permission | DO NOT RETRY |

## Deadloop Recognition
When same path + same approach fails 2+ times...
```

**迁移后** — 拆分为两个文件:

`subagent-worker/SKILL.md`:
```markdown
# File Operation Worker
Execute ONE operation. Return JSON. Nothing more.
[操作模板部分]
```

`main-monitor/SKILL.md`:
```markdown
# Safe File Operations Monitor
Schedule and monitor sub-agents. Never execute yourself.
[任务分解 + monitor protocol + strategy switch + checkpoint]
```

### Step 2: 迁移触发规则

**原始** (agents.md):
```markdown
Before mkdir/rm/touch → invoke safe-file-ops skill
```

**迁移后** (agents.md):
```markdown
For any file system task → invoke main-monitor skill
The main-monitor will spawn sub-agent workers automatically
```

### Step 3: 迁移执行流程

**原始流程** (在 Skill 中定义):
```
1. source safe-fs.sh
2. 使用 ensure_directory
3. 检查返回值
4. 如果失败 → 查表分类 → 决定
```

**迁移后流程** (在 main-monitor 中定义):
```
1. source safe-fs.sh + agent-checkpoint.sh + monitor-guard.sh
2. 解析用户任务 → 分解为单步操作列表
3. For each step:
   a. 检查 checkpoint_skip_if_completed → 跳过已完成
   b. Spawn Sub-Agent (prompt = subagent-worker 模板)
   c. evaluate_subagent_output(sub-agent result)
   d. RELIABLE → checkpoint_save → next
   e. UNRELIABLE → monitor_subagent() → get action
   f. Execute action (KILL_RETRY | KILL_SWITCH | ESCALATE)
4. 报告结果
```

### Step 4: 迁移死循环检测

**原始** (在 Skill 中定义，LLM 自查):
```markdown
## Deadloop Recognition
You are in a deadloop when:
- Same path + same command attempted 2+ times with same error
```

**迁移后** (在 monitor-guard.sh 中，外部检测):
```bash
detect_subagent_deadloop() {
    # Check monitor log for repeated UNRELIABLE verdicts
    count=$(grep -c "goal:$goal.*approach:$approach.*UNRELIABLE" "$MONITOR_LOG")
    [ "$count" -ge 2 ] && echo "true" || echo "false"
}
```

关键变化：死循环检测从"LLM 自省"变成了"grep 日志文件"。

### Step 5: 迁移策略切换

**原始** (LLM 自己决定):
```markdown
If mkdir fails with E_PERM → try python3 makedirs
```

**迁移后** (主 Agent 执行脚本):
```bash
alternative=$(get_alternative_strategy "ensure_directory" "mkdir_p" "mkdir_p python_makedirs")
# Returns: create_parents_first
# 主Agent 执行: spawn Sub-Agent with approach=create_parents_first
```

关键变化：策略选择从"LLM 判断"变成了"函数调用"。

## 四、实际迁移示例

### 用户任务: "创建 /tmp/myapp 项目结构，包含 config.yaml 和 logs 目录"

**旧 Skill 执行过程:**
```
Main Agent:
  → [自己] ensure_directory /tmp/myapp           ✓
  → [自己] ensure_file /tmp/myapp/config.yaml     ✓
  → [自己] ensure_directory /tmp/myapp/logs       ✗ E_PERM
  → [自己判断] "权限错误，我该重试吗？"            ← LLM自我反省
  → [自己] "试试 sudo？不对..."                   ← 困惑
  → [自己] ensure_directory /tmp/myapp/logs       ✗ E_PERM ← 死循环
```

**新 Skill 执行过程:**
```
Main Agent:
  → [spawn Sub-1] ensure_directory /tmp/myapp           → ok=true
  → [evaluate] RELIABLE → checkpoint_save

  → [spawn Sub-2] ensure_file /tmp/myapp/config.yaml     → ok=true
  → [evaluate] RELIABLE → checkpoint_save

  → [spawn Sub-3] ensure_directory /tmp/myapp/logs       → ok=false, E_PERM
  → [evaluate] RELIABLE but retryable=false
  → [monitor] detect_deadloop? → NO (first failure)
  → [monitor] get_alternative → "python_makedirs"
  → [spawn Sub-4 with approach=python_makedirs, DO_NOT_RETRY=mkdir_p]
    → ok=true
  → [evaluate] RELIABLE → checkpoint_save → DONE

关键区别：
  - 死循环不可能发生（Sub-3 失败一次后，Sub-4 用的是不同策略）
  - 主 Agent 不需要"自我反省"（monitor-guard.sh 给了明确的 action）
  - Sub-agent 的失败不污染主 Agent 的判断
```

## 五、兼容性：新旧 Skill 共存

两个 Skill 可以同时存在，按场景选用：

| 场景 | 使用 | 原因 |
|------|------|------|
| 简单单步操作 (`mkdir /tmp/x`) | 旧 safe-file-ops Skill | 一步操作不需要 sub-agent 开销 |
| 复杂多步任务 (`create project structure`) | 新 main-monitor Skill | 多步骤需要调度和监控 |
| 高可靠性要求 | 新 main-monitor Skill | 死循环检测更可靠 |
| 资源受限 (Pi Agent) | 旧 safe-file-ops Skill | Sub-agent 需要额外的 token 开销 |

agents.md 中可以同时注册两个 Skill：

```markdown
## File System Skills

For single file operations: invoke `safe-file-ops` skill.
For multi-step project setup: invoke `main-monitor` skill.

Quick rule: if the task has MORE THAN ONE file operation → use main-monitor.
If it's just ONE mkdir/write/delete → safe-file-ops is fine.
```
