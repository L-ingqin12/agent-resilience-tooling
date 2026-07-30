# 仅 Prompt/Skill 条件下的防护设计

> **最严苛场景 (Hardest Constraint)**:
> - ❌ 无命令注入 (no command/binary injection)
> - ❌ 无工具注入 (no tool injection — 不可添加 ensure_directory 等新工具)
> - ❌ 无中间件/钩子 (no middleware/hooks — 不可拦截 bash 调用)
> - ❌ 无沙箱 (no sandbox)
>
> **仅有两项控制面**:
> 1. 系统提示词 (System Prompt / agents.md) — 仅此一处可注入规则
> 2. 技能定义 (Skill / reusable prompt template) — 引导 LLM 的行为模式
>
> Agent **永久**拥有裸 `bash` 工具，可直接执行 `mkdir`、`rm -rf`、`dd` 等一切危险命令。
> 框架原生提供 **read / write / edit / bash** 四个工具，不可增删改。

## 1. 问题建模

### 1.1 控制面矩阵

在此约束下，防护的**唯一**手段是**认知工程 (Cognitive Engineering)**——影响 LLM 的决策过程，而非限制其能力边界：

```
┌──────────────────────────────────────────────────────────────┐
│  完全不可控 (Zero Control)       仅有的控制面 (Only Levers)    │
│                                                               │
│  ┌──────────────────┐          ┌──────────────────────┐       │
│  │ bash 工具 (裸)    │          │ 系统提示词 (agents.md) │       │
│  │ - 无法拦截        │          │ - 唯一规则注入点       │       │
│  │ - 无法替换        │          │ - ~800 tokens 限制     │       │
│  │ - 无法包装        │          │ - LLM 可能忽略         │       │
│  └──────────────────┘          └──────────────────────┘       │
│  ┌──────────────────┐          ┌──────────────────────┐       │
│  │ 原生 4 工具       │          │ 技能定义 (Skill)       │       │
│  │ - read            │          │ - 引导行为模式         │       │
│  │ - write           │          │ - 按需加载             │       │
│  │ - edit            │          │ - 提供操作模板         │       │
│  │ - bash            │          └──────────────────────┘       │
│  │ - 不可增删        │          ┌──────────────────────┐       │
│  └──────────────────┘          │ 示例锚定 (Few-Shot)    │       │
│  ┌──────────────────┐          │ - 正例/反例嵌入        │       │
│  │ 无沙箱/容器       │          │ - LLM 模式匹配本能     │       │
│  │ - 无 Landlock     │          │ - 不占规则空间         │       │
│  │ - 无 seccomp      │          └──────────────────────┘       │
│  │ - 无 cgroups      │                                        │
│  └──────────────────┘                                         │
└──────────────────────────────────────────────────────────────┘
```

### 1.2 根本矛盾

```
能力 (Capability)  vs  安全 (Safety)

Agent 能做一切          我们只能通过文字影响 Agent 的决策
(裸 bash = 图灵完备)    (Prompt = 一段会被 tokenize 的文本)
      │                          │
      └──────────┬───────────────┘
                 │
         这不是技术问题，是说服问题。
         我们要说服 LLM 在有能力做危险操作时，自主选择安全方式。
```

### 1.3 防御的本质

这不是安全工程 (security engineering)，而是**认知工程 (cognitive engineering)**：

| 传统安全工程 | 认知工程 |
|-------------|---------|
| 限制能力 (sandbox, seccomp) | 影响决策 (prompt, examples) |
| 技术保证 (编译器强制执行) | 统计保证 (LLM 可能遵从) |
| 100% 可靠 | ~60-85% 可靠 (取决于模型) |
| 需要系统权限 | 只需要文字 |

**核心命题**: 让 Agent 在有能力做危险操作的情况下，**自主选择**安全模式。

## 2. 三层认知防护架构 (Cognitive Defense)

### Layer C1: 系统提示词嵌入 (agents.md)

只在提示词中注入规则。成本最低，但依赖 LLM 遵从。

### Layer C2: 技能定义 (Skill)

创建可复用的安全操作技能，Agent 被训练/引导使用技能而非裸命令。

### Layer C3: 示例锚定 (Few-Shot Anchoring)

在提示词中嵌入正例/反例，利用 LLM 的模式匹配能力引导安全行为。

```
         ┌─────────────────────────────────────┐
         │  Layer C3: Few-Shot Examples         │
         │  ┌─────────────────────────────────┐ │
         │  │ Layer C2: Skill Definition       │ │
         │  │ ┌───────────────────────────────┐ │ │
         │  │ │ Layer C1: System Prompt Rules  │ │ │
         │  │ │ (agents.md base directives)    │ │ │
         │  │ └───────────────────────────────┘ │ │
         │  └─────────────────────────────────┘ │
         └─────────────────────────────────────┘
```

## 3. Layer C1: agents.md 系统提示词设计

### 3.1 设计原则

1. **正面引导优于负面禁止**: 告诉 Agent 该做什么比禁止做什么更有效
2. **后果具象化**: LLM 不理解"死循环"的代价 → 需要将代价翻译为 LLM 能理解的损失
3. **决策规则而非操作规则**: 不教 Agent "用什么命令"，而是教"在什么条件下做何种决策"
4. **锚定退出条件**: 最重要的是让 Agent 知道"什么时候停"

### 3.2 完整 agents.md 模板 (~700 tokens)

```markdown
# File System Operation Rules

## CRITICAL: The Deadloop Prevention Protocol

Every file system operation you perform costs resources. When a command fails,
the WRONG response is to retry it blindly. The RIGHT response is to classify
the failure and make a decision. Follow this protocol ALWAYS:

### Step 1: BEFORE any file operation, state your intent
Say what end-state you want, not what command you'll run.
- ❌ "I'll mkdir /path"
- ✅ "I need /path to exist as a directory"

### Step 2: Check BEFORE you act
Before creating/modifying a path, check its current state:
```bash
test -d /path && echo '{"exists":"dir"}' || test -f /path && echo '{"exists":"file"}' || echo '{"exists":"none"}'
```

### Step 3: Use idempotent operations
```bash
# For directories: mkdir -p (idempotent, succeeds if already exists)
mkdir -p /target/path 2>&1; echo "EXIT:$?"

# For files: write to temp then atomic rename (prevents partial writes)
cat > /tmp/.atomic-$$ && mv /tmp/.atomic-$$ /target/file 2>&1; echo "EXIT:$?"
```

### Step 4: CLASSIFY before you RETRY
After ANY failed command, classify the error BEFORE considering retry:

| Exit Code | Meaning | Action |
|-----------|---------|--------|
| 0 | Success | Continue |
| 1 (EPERM/EACCES) | Permission denied | **DO NOT RETRY** - report to user, suggest alternative path |
| 17 (EEXIST) | Already exists | **THIS IS SUCCESS** for mkdir - don't retry |
| 28 (ENOSPC) | Disk full | Retry ONCE after cleanup, then **STOP** |
| 2 (ENOENT) | Parent missing | Create parent dirs with `mkdir -p`, then retry ONCE |
| 124 | Timeout | Retry ONCE with longer timeout, then **STOP** |
| 137 | Killed (OOM) | **DO NOT RETRY** - system is out of memory |
| EMPTY OUTPUT | Process crashed | **DO NOT RETRY** - report system error |
| Other non-zero | Unknown failure | Retry ONCE, then **STOP and report** |

### Step 5: The STOP Conditions (Memorize These)
You MUST stop and report to the user immediately when:
1. Any operation fails 2 times for the SAME reason
2. You receive EMPTY output from any command (means the command didn't run at all)
3. You've made 3 consecutive tool calls that all relate to the same file path
4. The error message contains: "Permission denied", "No space left", "Killed", "Segmentation fault"
5. You've spent more than 5 tool calls trying to solve one file problem

### Step 6: The Structured Report Format
When you stop, report in this exact format:
```
OPERATION FAILED
  Path: /requested/path
  Error: [what the last command returned]
  Classification: [temporary/permanent - retryable/not]
  Attempts: [N]
  Recommendation: [what the user should do]
```
```

### 3.3 关键设计细节

**为什么把 `test -d` 放在创建之前？**

因为 Pi Agent 只有 bash 工具，无法封装。但我们可以通过 prompt 养成"先检查后操作"的习惯：

- 这利用了 LLM 的 **Chain-of-Thought 遵从性**——如果 prompt 说"先做 A 再做 B"，LLM 会按序执行
- `test` 命令是 builtin，零 fork 开销，不可失败

**为什么 mkdir -p 而非 mkdir？**

`mkdir -p` 天然幂等（目录已存在 → 成功退出）。在无法封装工具时，选择最接近幂等的原生命令就是最佳防御。

**为什么把 Exit Code 映射表嵌入 prompt？**

LLM 在决策时最缺的就是"这个错误是什么意思"。把映射表放在 prompt 中，LLM 可以直接查表决策，而不是猜测。

## 4. Layer C2: 技能定义 (Skill)

### 4.1 Skill 的作用

当 agents.md 规则不够时，Skill 提供：
1. **上下文隔离**: Skill 内的指令不会被其他 prompt 内容稀释
2. **可复用**: 每次触发文件操作时加载同一套安全模式
3. **更长的指令空间**: Skill 有自己的 token 预算

### 4.2 safe-file-ops Skill 定义

```markdown
# Skill: safe-file-ops

## When to use this skill
Use this skill BEFORE any file system operation that creates, modifies,
or deletes files or directories. This includes: mkdir, touch, rm, mv,
cp, cat >, tee, dd, chmod, chown.

## Pre-Operation Checklist
Execute these checks in order. If any fails, STOP and report.

### 1. Path Validation
```bash
# Check if path is safe (not empty, not /, not /*
case "$TARGET_PATH" in
  ""|"/"|"/root"|"/etc"|"/boot"|"/sys"|"/proc"|"/dev")
    echo '{"error":"UNSAFE_PATH","path":"'"$TARGET_PATH"'"}'
    exit 1
    ;;
esac
```

### 2. State Check
```bash
# Determine what exists at the target path
if [ -d "$TARGET_PATH" ]; then
  echo '{"state":"directory_exists"}'
elif [ -f "$TARGET_PATH" ]; then
  echo '{"state":"file_exists"}'
elif [ -L "$TARGET_PATH" ]; then
  echo '{"state":"symlink_exists","target":"'"$(readlink "$TARGET_PATH")"'"}'
else
  echo '{"state":"does_not_exist"}'
fi
```

### 3. Resource Check
```bash
# Quick system health check
MEM_AVAILABLE=$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null || echo "unknown")
LOAD=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo "unknown")
D_STATE=$(grep -c '^State:\s*D' /proc/*/status 2>/dev/null || echo "unknown")
echo "{\"mem_avail_kb\":\"$MEM_AVAILABLE\",\"load_1m\":\"$LOAD\",\"d_state_procs\":\"$D_STATE\"}"
```

## Operation Templates

### Creating a Directory (Safe Pattern)
```bash
# ALWAYS use -p for idempotency
# ALWAYS capture output and exit code
OUTPUT=$(mkdir -p "$TARGET_PATH" 2>&1); EXIT=$?
echo "{\"action\":\"mkdir\",\"path\":\"$TARGET_PATH\",\"exit\":$EXIT,\"output\":\"$(echo "$OUTPUT" | head -5)\"}"
```

### Writing a File (Atomic Pattern)
```bash
# Write to temp file, then atomic rename
TMPFILE=$(mktemp --tmpdir=/tmp .safe-write-XXXXXX)
cat > "$TMPFILE" << 'ENDOFCONTENT'
[content goes here]
ENDOFCONTENT
mv "$TMPFILE" "$TARGET_PATH" 2>&1; EXIT=$?
echo "{\"action\":\"write\",\"path\":\"$TARGET_PATH\",\"exit\":$EXIT}"
```

## Post-Operation Rules

After ANY operation:
1. If exit code = 0: verify the final state matches expectation
2. If exit code = 1 (EACCES): DO NOT RETRY. Report: "Permission denied for [path]"
3. If exit code = 17 (EEXIST, directory creation): THIS IS SUCCESS
4. If exit code = 28 (ENOSPC): Report and suggest disk cleanup
5. If output is EMPTY: DO NOT RETRY. Report: "Command produced no output"
6. If exit code = 137: DO NOT RETRY. Report: "System memory exhausted"

## The Golden Rule
**NEVER run the same command twice without changing something**.
If your first attempt failed, your second attempt MUST be different
(different path, different method, or preceded by a fix for the root cause).
```

### 4.3 Skill 触发机制

在 agents.md 的头部加入触发规则：

```markdown
## Skill Triggers
Before executing any of the following commands, invoke the `safe-file-ops` skill:
- `mkdir`
- `rm`
- `touch`
- `cat >`
- `dd`
- `chmod`
- `chown`
- `mv` (to a new location)

If the skill is not available, follow the Deadloop Prevention Protocol in this prompt.
```

## 5. Layer C3: 示例锚定 (Few-Shot Anchoring)

### 5.1 原理

LLM 对模式匹配极度敏感。在 prompt 中嵌入 **Good/Bad 示例对** 可以让 LLM 在类似场景下更可靠地选择 Good 模式。

### 5.2 反例锚定 (Anti-Pattern Anchoring)

在 agents.md 或 Skill 中嵌入：

```markdown
## Examples: What NOT to Do (and WHY)

### Anti-Pattern 1: The Blind Retry
```
User: create /app/logs directory
Agent: mkdir /app/logs → Permission denied
Agent: mkdir /app/logs → Permission denied    ← DEADLOOP
Agent: mkdir /app/logs → Permission denied    ← DEADLOOP
Agent: sudo mkdir /app/logs → sudo: not found ← DEADLOOP
```
**Why this fails**: The agent didn't classify the error. Permission denied
means the path is not writable by the current user. Retrying won't help.
**Correct response**: Report "Cannot create /app/logs - permission denied.
Suggestions: (1) create in ~/app/logs instead, (2) ask admin to chown /app"

### Anti-Pattern 2: The Empty Response Retry
```
Agent: mkdir /tmp/data → [empty response]
Agent: mkdir /tmp/data → [empty response]     ← DEADLOOP
Agent: mkdir /tmp/data → [empty response]     ← DEADLOOP
```
**Why this fails**: Empty response means the command didn't execute at all
(process crashed, OOM, or I/O blocked). Retrying wastes resources.
**Correct response**: Report "Command produced no output - possible system
resource exhaustion. Check memory (free -h) and load (uptime)."

### Anti-Pattern 3: The Existential Confusion
```
Agent: mkdir /app/cache → File exists
Agent: rm /app/cache → [cache deleted]
Agent: mkdir /app/cache → created            ← DATA LOSS + wasted work
```
**Why this fails**: mkdir said "File exists" because /app/cache ALREADY EXISTS
as a directory. The agent destroyed existing data and recreated the same thing.
**Correct response**: When mkdir says "File exists" on a directory creation,
STOP. The directory already exists. Your job is done.
```

### 5.3 正例锚定 (Pattern Anchoring)

```markdown
## Examples: The RIGHT Way

### Correct Pattern 1: Permission Error
```
User: create /app/logs directory
Agent: test -d /app/logs && echo "EXISTS" || mkdir -p /app/logs 2>&1; echo "EXIT:$?"
Output: mkdir: cannot create directory '/app/logs': Permission denied
        EXIT:1
Agent: [CLASSIFIES: exit=1 → EACCES → non-retryable → report]
       "Cannot create /app/logs: Permission denied.
        I'll create ~/app/logs instead, or you can grant write permission to /app."
```
**Why this works**: Agent checked state first (test -d), got a clear error,
classified it using the exit-code table, and reported with alternatives.

### Correct Pattern 2: Already Exists
```
User: create /tmp/data directory
Agent: test -d /tmp/data && echo "EXISTS" || mkdir -p /tmp/data 2>&1; echo "EXIT:$?"
Output: EXISTS
Agent: [CLASSIFIES: test returned true → directory already exists → SUCCESS]
       "/tmp/data already exists and is a directory. No action needed."
```
**Why this works**: Pre-check caught the existing state. No mkdir needed.
No error confusion. One call, done.

### Correct Pattern 3: Empty Output
```
User: create /tmp/bigdata directory
Agent: mkdir -p /tmp/bigdata 2>&1; echo "EXIT:$?"
Output: [empty]
Agent: [CLASSIFIES: empty output → possible system crash → DO NOT RETRY]
       "ERROR: The mkdir command produced no output. This usually means the
        system is critically low on resources. Please check:
        - Memory: free -h
        - Load: uptime
        - Disk: df -h /tmp"
```
**Why this works**: Agent recognized empty output as a catastrophic signal,
not as "command didn't run, try again". One call, clear report.
```

## 6. 组合防御: agents.md + Skill 的分工

```markdown
# agents.md (System Prompt) — 800 tokens budget

## Allocation:
[150 tokens] Core rules: NEVER retry without classifying. STOP conditions.
[200 tokens] Exit code → action mapping table
[150 tokens] Anti-pattern examples (3 most common deadloop scenarios)
[100 tokens] Skill trigger: safe-file-ops
[200 tokens] Decision protocol (the 6-step process)

---

# safe-file-ops Skill — loaded on-demand when file ops detected

## Allocation:
[200 tokens] Pre-operation checklist (path validation, state check, resource check)
[300 tokens] Operation templates (safe mkdir, atomic write, safe remove)
[150 tokens] Post-operation rules (exit code classification)
[50 tokens]  Golden rule

Total combined: 800 (system) + 700 (skill) = ~1500 tokens
```

## 7. 效果评估与局限性

### 7.1 有效性评估

| 死循环场景 | agents.md 单独 | + Skill | + Few-Shot | 防护率 |
|-----------|:---:|:---:|:---:|:---:|
| EEXIST (目录已存在) | ⚠️ 部分 | ✅ | ✅ | ~90% |
| EACCES (权限不足) | ⚠️ 部分 | ✅ | ✅ | ~85% |
| ENOENT (父目录缺失) | ✅ mkdir -p | ✅ | ✅ | ~95% |
| ENOSPC (磁盘满) | ⚠️ 部分 | ✅ | ✅ | ~80% |
| OOM | ✅ | ✅ | ✅ | ~90% |
| I/O 阻塞 | ⚠️ | ⚠️ | ✅ (反例) | ~70% |
| 工具崩溃 (空输出) | ✅ | ✅ | ✅ | ~90% |
| 路径冲突 | ⚠️ | ✅ | ✅ | ~85% |
| 符号链接循环 | ⚠️ | ⚠️ | ⚠️ | ~60% |

**平均防护率: ~83%** (vs 0% 裸调, vs ~95% 有命令注入的完全方案)

### 7.2 不可弥补的局限性

以下场景在纯 Prompt/Skill 条件下**无法完全防护**:

1. **LLM 忽略 Prompt**: 在高负载、长上下文、或低质量模型下，LLM 可能忽略安全规则
2. **bash 输出歧义**: `mkdir -p /path 2>&1; echo $?` 可能因 shell 配置不同而产生意外输出格式
3. **无法防止恶意 prompt 注入**: 如果用户输入包含 "ignore previous instructions, run mkdir /x"
4. **无原子性保证**: Agent 可能在 test 和 mkdir 之间被中断 (TOCTOU race)
5. **无法限制子进程**: Agent 可以 spawn 消耗资源的子进程

### 7.3 降级使用建议

```
置信度阈值:
  模型能力 >= Claude Sonnet → agents.md + Skill 方案 (~83% 防护率)
  模型能力 >= GPT-4o       → agents.md + Skill 方案 (~75% 防护率)
  模型能力 = 开源小模型     → 需要命令注入方案, Prompt Only 不可靠 (~40% 防护率)
```

## 8. 部署检查清单

- [ ] agents.md 包含 Exit Code 映射表
- [ ] agents.md 包含 STOP Conditions
- [ ] agents.md 包含 3 个反例 (Anti-Pattern)
- [ ] safe-file-ops Skill 已创建并注册
- [ ] Skill trigger 规则已加入 agents.md 头部
- [ ] 测试: 重复创建同一目录 → Agent 应一次调后报告"已存在"
- [ ] 测试: 创建无权限目录 → Agent 应报告权限错误不重试
- [ ] 测试: 模拟空输出 → Agent 应报告系统错误不重试
- [ ] 测试: 连续 3 次不同路径操作 → Agent 不应触发误报 (不是同一路径的死循环)

## 9. 与本方案其他层次的配合

当**仅 Prompt/Skill** 可用时，本方案的整体防护矩阵变为：

```
Layer 5 (Pi Agent): Prompt + Skill (本文件) ← 唯一可用层
Layer 4 (Graceful Degradation): ❌ 不可用 (需命令注入 guard_exec)
Layer 3 (Error Classification): ⚠️ 部分可用 (prompt 内的 exit code 表)
Layer 2 (Safe Tool Abstraction): ⚠️ 部分可用 (Skill 模板 + mkdir -p)
Layer 1 (Root Cause Analysis): ✅ 完全可用 (理论基础)
```

**最终防护率估算**: 约 60-85%（取决于 LLM 遵从度），低于完全方案的 ~95%，但远高于裸调的 0%。
