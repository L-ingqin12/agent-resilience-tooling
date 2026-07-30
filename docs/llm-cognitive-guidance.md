# LLM 认知引导方案：培养"返回值思维"与"错误处置本能"

> **核心命题**: 让 LLM 从"写完命令就期待成功"的本能，转变为"每条命令都是一次带返回值的函数调用，必须检查返回值并决策下一步"的思维模式。
>
> **与技术防护的关系**: 技术防护（safe-fs.sh, guard_exec）是硬约束；认知引导是软约束。软硬结合才是完整方案。

## 1. 问题诊断：LLM 为什么容易死循环？

### 1.1 LLM 的"乐观偏差"

LLM 在生成命令时存在天然的乐观偏差：

```
LLM 思维: "我需要创建目录 /app/logs"
         → 生成: mkdir /app/logs
         → 假设: 这个命令会成功
         → 如果失败: "可能是意外，再试一次"
         → 再试 → 再失败 → 死循环
```

**根源**: LLM 被训练为"完成用户任务"，而不是"安全地执行系统操作"。它的 reward model 奖励"任务完成"，不奖励"正确识别不可完成任务"。

### 1.2 LLM 缺少的四个概念

| 缺失概念 | 表现 | 后果 |
|---------|------|------|
| 返回值思维 | 写 `mkdir /path` 而非 `mkdir /path; echo $?` | 不知道命令是否成功 |
| 输出即数据 | 只看 stdout 不看 stderr | 错误信息被忽略 |
| 分类先于行动 | "失败了 → 再试" 而非 "失败了 → 为什么失败？" | 盲目重试 |
| 停止条件 | 没有"什么情况下应该停"的概念 | 无限循环 |

## 2. 三层认知引导架构

```
Layer C1: 思维框架 (Mental Model)
  → 让 LLM 把每条命令当作 "函数调用"
  → 输入 → 执行 → 返回码 + 输出 → 分类 → 决策

Layer C2: 行为锚定 (Behavioral Anchoring)
  → Few-Shot 正例/反例
  → 让 LLM 在类似场景下自动选择正确模式

Layer C3: 自检机制 (Self-Check Mechanism)
  → 规则化 STOP 条件
  → LLM 在每个工具调用后自动运行的检查清单
```

## 3. Layer C1: 植入"函数调用"思维模型

### 3.1 核心概念转换

在系统提示词中，将"执行命令"重新定义为"调用函数"：

```markdown
## COMMAND EXECUTION IS FUNCTION CALLING

Every bash command you execute is a FUNCTION CALL:
  Input:  the command and its arguments
  Output: stdout + stderr (the return value)
  Status: exit code (0 = success, non-zero = error type)

Just as you would never call a Python function and ignore its return value,
you MUST never execute a bash command without capturing and classifying its result.

### The Function Call Pattern (MANDATORY for every command):

```bash
# Step 1: Execute and capture ALL outputs
OUTPUT=$(command 2>&1); EXIT=$?

# Step 2: Report in structured format
echo "EXIT:$EXIT"
echo "OUTPUT:$OUTPUT"

# Step 3: Classify and decide (DO NOT SKIP)
```
```

### 3.2 命令模式模板

给 LLM 提供固定的命令模式，让它只需要"填参数"：

```markdown
### The Three Command Patterns You Must Use:

#### Pattern A: Create/Mutate (mkdir, touch, rm, mv, cp, cat >, chmod)
```bash
# PRE-CHECK: What exists at the target?
test -e TARGET && echo "PRE_EXISTS:$(file TARGET)" || echo "PRE_NONE"

# EXECUTE: With output capture
OUTPUT=$(COMMAND 2>&1); EXIT=$?

# POST-VERIFY: Did we achieve the goal?
test -d TARGET && echo "POST_EXISTS:dir" || echo "POST_MISSING"

# CLASSIFY
echo "RESULT:$EXIT:$OUTPUT"
```

#### Pattern B: Query (cat, grep, find, ls, stat)
```bash
OUTPUT=$(COMMAND 2>&1); EXIT=$?
echo "EXIT:$EXIT"
echo "$OUTPUT"
```

#### Pattern C: Background/Long-running (curl, git clone, npm install)
```bash
timeout 30 COMMAND 2>&1; EXIT=$?
echo "EXIT:$EXIT"
[ $EXIT -eq 124 ] && echo "ERROR:TIMEOUT"
```
```

### 3.3 为什么这个思维模型有效？

1. **类比 LLM 已有的概念**: LLM 理解"函数调用"和"返回值"。把 bash 命令重新框架为函数调用，LLM 会自然迁移函数调用的行为模式（检查返回值）。

2. **结构化习惯**: 固定 Pattern 让 LLM 不需要"思考怎么写命令"，只需要"选择正确的 Pattern 并填参数"。减少创造性 = 增加可靠性。

3. **输出即证据**: 每次命令都有 EXIT 码和 OUTPUT 明文。LLM 在下一步决策时有数据可用，不需要猜测"上次发生了什么"。

## 4. Layer C2: Few-Shot 行为锚定

### 4.1 为什么 Few-Shot 对 LLM 行为引导至关重要？

LLM 的模式匹配能力远强于规则遵从能力。

- 规则: "如果 exit code 是 1，不要重试" → LLM 可能忽略
- 示例: 展示一个"exit code 1 → 停止并报告"的完整对话 → LLM 模仿

### 4.2 锚定示例集

在 agents.md 中嵌入以下示例对：

```markdown
## LEARN FROM THESE EXAMPLES

### Example 1: Directory Already Exists — STOP, don't retry

BAD (what you MUST NOT do):
  User: "make /tmp/cache exist"
  Agent: mkdir /tmp/cache
  Output: mkdir: cannot create directory '/tmp/cache': File exists
  Agent: mkdir /tmp/cache    ← WRONG: retrying the same thing
  Output: mkdir: cannot create directory '/tmp/cache': File exists
  Agent: mkdir /tmp/cache    ← WRONG: infinite loop

GOOD (what you MUST do):
  User: "make /tmp/cache exist"
  Agent: test -d /tmp/cache && echo 'EXISTS' || mkdir -p /tmp/cache 2>&1; echo "EXIT:$?"
  Output: EXISTS
  Agent: "/tmp/cache already exists as a directory. Task complete. No action needed."

### Example 2: Permission Denied — REPORT, don't retry

BAD:
  Agent: mkdir /root/app
  Output: mkdir: cannot create directory '/root/app': Permission denied
  Agent: mkdir /root/app    ← WRONG: same permission, same failure
  Agent: sudo mkdir /root/app  ← WRONG: trying different approach blindly

GOOD:
  Agent: test -w /root && echo 'WRITABLE' || echo 'NOT_WRITABLE'; echo "EXIT:$?"
  Output: NOT_WRITABLE
         EXIT:0
  Agent: "Cannot create /root/app: /root is not writable by current user.
          Options: (1) I'll create ~/app instead, (2) you can run with sudo.
          Which would you prefer?"

### Example 3: Empty Output — EMERGENCY, stop immediately

BAD:
  Agent: mkdir /tmp/data
  Output: [empty]
  Agent: mkdir /tmp/data    ← WRONG: empty = system crisis, not "didn't run"

GOOD:
  Agent: mkdir /tmp/data 2>&1; echo "EXIT:$?"
  Output: EXIT:137
  Agent: "EMERGENCY: Command returned exit code 137 (killed, likely OOM)
          with no stdout/stderr. System may be critically low on resources.
          I am STOPPING all file operations. Please check: free -h, df -h, uptime."

### Example 4: Disk Full — retry ONCE with cleanup, then stop

GOOD:
  Agent: mkdir /data/logs 2>&1; echo "EXIT:$?"
  Output: mkdir: cannot create directory '/data/logs': No space left on device
          EXIT:28
  Agent: [CLASSIFIES: ENOSPC → retryable=once]
          "Disk is full (ENOSPC). Let me try cleaning temp files once..."
          df -h /data
          rm -rf /tmp/*.tmp 2>/dev/null
          mkdir /data/logs 2>&1; echo "EXIT:$?"
  Output: EXIT:28
  Agent: "Still no space after cleanup. I am stopping.
          /data needs manual cleanup. Current usage: 100%."
```

## 5. Layer C3: 自检机制

### 5.1 内化检查清单

让 LLM 在每个工具调用后，**主动运行内部检查清单**：

```markdown
## AFTER EVERY COMMAND, silently ask yourself:

□ Did I capture the EXIT CODE? (must have "EXIT:N" somewhere)
  → If NO: the command output is incomplete. Re-run with "; echo EXIT:$?".

□ Is the output EMPTY or only whitespace?
  → If YES: DO NOT RETRY. This is E_SYSTEM_CATASTROPHE. Report and stop.

□ Did I get exit code 0?
  → If YES: use "test" to verify the final state matches my goal.
  → If NO: classify the error BEFORE thinking about retry.

□ Have I already tried this exact command on this exact path?
  → If YES (2nd attempt): this is my LAST attempt. One more failure = stop.
  → If YES (3rd attempt): STOP. Report. Do not attempt again.

□ Is this error type in the classification table?
  → retryable=true → may retry ONCE with modified approach
  → retryable=false → report immediately, do NOT retry
```

### 5.2 触发式自检

特定关键词触发特定自检：

```markdown
## AUTOMATIC CHECKS (triggered by keywords in output):

When you see "Permission denied" → AUTOMATICALLY:
  □ Check: am I running as the right user? (whoami)
  □ Check: what are the parent directory permissions? (ls -ld $(dirname $PATH))
  □ Decision: DO NOT RETRY with same path. Suggest alternative.

When you see "No space left" → AUTOMATICALLY:
  □ Check: df -h $(dirname $PATH)
  □ Attempt: ONE cleanup (rm /tmp/*.tmp)
  □ Decision: if still full, STOP.

When you see "Killed" → AUTOMATICALLY:
  □ Check: dmesg | tail -5 (OOM killer log)
  □ Check: free -h
  □ Decision: DO NOT RETRY. System resources exhausted.

When you see "Segmentation fault" → AUTOMATICALLY:
  □ Decision: DO NOT RETRY. The tool itself is broken.

When you see EMPTY OUTPUT → AUTOMATICALLY:
  □ Decision: DO NOT RETRY. This is a catastrophic signal.
  □ Action: Report "The command produced no output — possible system crash or
             resource exhaustion. All file operations paused."
```

## 6. 完整 agents.md 模板 (750 tokens)

```markdown
# File System Operations — Safe Execution Protocol

## Mental Model: Every Command is a Function Call
Think of every bash command as: Input → Execute → {ExitCode, Output} → Classify → Decide.
You MUST capture the return value. You MUST classify before retrying.

## Mandatory Command Patterns

### For any file mutation (mkdir, rm, mv, cat >, chmod):
```bash
# PRE: check state
test -e PATH && echo "PRE:EXISTS" || echo "PRE:NONE"
# EXEC: capture all
OUT=$(command 2>&1); EX=$?
# POST: verify goal
test -d PATH && echo "POST:dir" || echo "POST:missing"
# REPORT
echo "EXIT:$EX"
```

## Error Classification (look up BEFORE retrying)
| Exit | Meaning | Action |
|------|---------|--------|
| 0 | Success | Verify state, continue |
| 1 | Permission | **STOP** — suggest alternative path |
| 17 | Already exists | **SUCCESS** (for mkdir) — stop |
| 28 | No space | Retry ONCE after cleanup, then **STOP** |
| 124 | Timeout | Retry ONCE with longer timeout |
| 137 | Killed/OOM | **STOP** — system exhausted |
| EMPTY | Crash | **STOP** — catastrophic |

## STOP Conditions (absolute)
1. Same command on same path failed 2 times → STOP
2. Empty output from any command → STOP
3. "Permission denied", "No space", "Killed", "Segfault" → classify, don't blindly retry
4. 3 tool calls about the same path → STOP and report

## Post-Command Self-Check (run silently in your head after each command)
1. Exit code captured? 2. Output empty? 3. Goal achieved? 4. Retried before? 5. Should stop?

## Examples of CORRECT behavior:
[Embed 2-3 of the GOOD examples from Layer C2 above]

## When in doubt, REPORT to user with:
- What you tried
- What the system returned
- What error type this is
- What you recommend the user do
```

## 7. 效果评估

### 7.1 引导效果分级

| 引导层级 | LLM 行为变化 | 预期防护率 |
|:---|------|:---:|
| 无引导 | 裸 mkdir，失败→重试→死循环 | 0% |
| C1 (思维框架) | 命令带 `; echo EXIT:$?` | ~40% |
| C1+C2 (思维+示例) | 模式匹配选择正确行为 | ~65% |
| C1+C2+C3 (思维+示例+自检) | 每次命令后主动检查分类 | ~80% |
| 全引导 + 技术防护 (safe-fs.sh) | 双重保障 | ~95% |

### 7.2 关键洞察

> **认知引导解决的是 LLM "不会"的问题；技术防护解决的是 LLM "不听话"的问题。**
>
> - 当 LLM 能力足够好 (Claude/GPT-4级别): 认知引导为主，技术防护为辅
> - 当 LLM 能力有限 (开源小模型): 技术防护为主，认知引导为辅
> - 当完全无法做技术防护 (S1/S2场景): 认知引导是唯一手段

## 8. 与场景矩阵的配合

在 [scenario-matrix.md](scenario-matrix.md) 的每个场景中，加入认知引导层：

```
S1 (仅Prompt): 认知引导 C1+C2+C3 (本文件) = 唯一防护线
S2 (+Skill):   认知引导 + Skill 操作模板
S3 (+Tool):    认知引导(精简~100tokens) + 自定义安全工具(主力防线)
S4+ (+Hook):   认知引导(极简~50tokens) + 技术防护(主力防线)
```

**原则**: 技术防护越强，认知引导可越精简。但认知引导永远不应为零——即使有完整技术防护，LLM 仍需要基本的"返回值思维"来正确处理工具的返回值。
