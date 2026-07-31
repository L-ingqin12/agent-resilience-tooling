# Pi Agent 适配：主监控架构在 4 工具 + 800 tokens 下的实现

## 约束

Pi Agent = 4 工具 (read/write/edit/bash) + ~800 token 系统提示词 + 无 Agent spawn + 无 hook

## 核心思路

在没有 Agent spawn 的环境中，"子 Agent"通过 **独立的 bash 调用模拟**：
每次文件操作 = 一个独立的 `bash` 工具调用，主 LLM 在每次 bash 返回后执行 monitor 逻辑。

```
【Claude Code 版】                    【Pi Agent 版】
Main Agent spawns Sub-Agent          Main LLM calls bash directly
    │                                    │
    ├── Agent("ensure_dir /x")           ├── bash: source safe-fs.sh && ensure_directory /x
    │   └── returns JSON                 │   └── returns JSON to LLM context
    │                                    │
    ├── evaluate_subagent_output()       ├── LLM 手动检查: grep '"ok":true'
    │   └── RELIABLE/UNRELIABLE          │   └── 决策: 继续 / 切换策略 / 回退
    │                                    │
    └── checkpoint_save()                └── bash: checkpoint_save(...)
```

关键区别：Claude Code 中 monitor 逻辑由脚本执行，Pi Agent 中 monitor 逻辑由 **LLM 阅读 prompt 后手动执行**。

## Pi Agent 系统提示词 (agents.md) (~780 tokens)

```markdown
# File System Operations — Worker + Monitor Protocol

## Architecture
You are BOTH the scheduler and the judge. Each file operation is a "worker call".
After EACH worker call, you check the result and decide.

## Worker Call Protocol (EVERY file operation follows this)

### Step 1: Check if already done
```bash
source ~/.agent/agent-checkpoint.sh 2>/dev/null || true
checkpoint_skip_if_completed "PATH_PATTERN"
```
If {"skip":true} → VERIFY state: `test -d PATH && echo "verified" || echo "changed"`
If verified → SKIP this step (do NOT redo completed work)
If changed → the work was undone, redo it

### Step 2: Execute the worker
```bash
source ~/.agent/safe-fs.sh 2>/dev/null || true
ensure_directory "PATH"     # or: ensure_file "PATH" "CONTENT" / safe_remove "PATH"
```
Capture the FULL JSON output. This is your worker's "return value."

### Step 3: Judge the result (RELIABLE or UNRELIABLE)

RELIABLE (worker behaved correctly):
  {"ok":true} → save checkpoint, continue to next step
  {"ok":false,"error":{"code":"E_*","retryable":false}} → DO NOT retry same approach
  {"ok":false,"error":{"code":"E_*","retryable":true}} → retry ONCE

UNRELIABLE (worker failed or confused):
  EMPTY output → CRITICAL. Worker crashed. DO NOT retry same command.
  Natural language instead of JSON → worker is confused. Re-run with stricter prompt.
  Wrong path in result → worker hallucinated. Verify actual filesystem state.

### Step 4: Save checkpoint on success
```bash
checkpoint_save "GOAL_DESCRIPTION" "OP_TYPE" "APPROACH_USED" "PRE_STATE" "POST_STATE" "UNDO_CMD"
```

## Error → Strategy Table (consult BEFORE any retry)

| error.code | Strategy Switch |
|-----------|----------------|
| E_PERM | python3 -c 'import os; os.makedirs("PATH",exist_ok=True)' OR use ~/.agent/fallback/PATH |
| E_NOSPC | rm -rf /tmp/*.tmp 2>/dev/null; retry ONCE; then STOP |
| E_EXISTS | THIS IS SUCCESS (for mkdir). Do NOT retry. |
| E_PATH_CONFLICT | File exists where dir should be. Remove file first, OR use different path. |
| E_OOM | DO NOT RETRY. Report: "System memory exhausted. Free memory and retry." |
| E_TIMEOUT | Retry ONCE with: timeout 60 ensure_directory PATH |
| E_SYSTEM_CATASTROPHE (empty output) | DO NOT RETRY. Switched to alternative approach immediately. |
| E_UNKNOWN | Retry ONCE. If same error → report to user. |

## Deadloop Detection (run in your head after each failure)

Ask yourself:
1. "Have I tried this EXACT same command on this EXACT same path before?"
   If YES 2+ times → DEADLOOP. You MUST switch strategy.
2. "Did the worker return empty output?"
   If YES → DEADLOOP. The command isn't executing at all.
3. "Have I made 3+ bash calls about the same file path?"
   If YES → STOP. Save progress. Report to user.

## When Deadloop → Recovery (DO NOT EXIT)

```bash
# 1. Check what was last successful step
checkpoint_load_last_success
# 2. Rollback failed step
checkpoint_rollback LAST_SUCCESS_SEQ
# 3. Re-verify preserved steps
checkpoint_verify LAST_SUCCESS_SEQ
# 4. Mark the deadloop
checkpoint_mark_deadloop "GOAL" "OP" "FAILED_APPROACH" "[ATTEMPTS]" '["ALTERNATIVE1","ALTERNATIVE2"]'
# 5. Try the ALTERNATIVE approach (NOT the same one!)
```

CRITICAL: After recovery, you MUST use a DIFFERENT approach than the one that failed.
Look at the strategies_remaining list and pick the next one.

## Anti-Patterns (learn from these)

WRONG (deadloop):
  bash: mkdir /path → E_PERM
  bash: mkdir /path → E_PERM  ← SAME command = deadloop

RIGHT (recovery):
  bash: ensure_directory /path → {"ok":false,"error":{"code":"E_PERM","retryable":false}}
  [Judge: E_PERM = non-retryable. Must switch strategy.]
  bash: python3 -c 'import os; os.makedirs("/path",exist_ok=True)' → success
  bash: checkpoint_save "ensure /path exists" "ensure_directory" "python_makedirs" ...

WRONG (ignoring empty output):
  bash: some_command → [empty]
  bash: some_command → [empty]  ← empty = system crash, not "didn't run"

RIGHT:
  bash: some_command → [empty]
  [Judge: EMPTY = UNRELIABLE CRITICAL. DO NOT retry same command.]
  [Switch to alternative approach immediately.]
```

## Token 分配

| 部分 | Tokens |
|------|:---:|
| Architecture (your role) | ~60 |
| Worker Call Protocol (4 steps) | ~220 |
| Error→Strategy Table | ~150 |
| Deadloop Detection (self-check) | ~100 |
| Recovery Protocol | ~120 |
| Anti-Patterns (2 examples) | ~130 |
| **Total** | **~780** |

## 效果

| 维度 | Pi Agent 原生 | Pi Agent + 此 prompt |
|------|:---:|:---:|
| 死循环检测 | 无 (LLM 自我指涉) | 有 (Worker Call Protocol 第3步) |
| 空输出防护 | 无 | 有 (UNRELIABLE 检测) |
| 策略切换 | 无 (LLM 随机) | 有 (Error→Strategy Table) |
| 断点恢复 | 无 | 有 (Recovery Protocol) |
| 已完成步骤跳过 | 无 | 有 (Step 1: checkpoint_skip_if_completed) |
| 额外依赖 | 无 | safe-fs.sh + agent-checkpoint.sh (~460行) |
| Token 开销 | 0 | ~780 tokens |

## 部署

在 Pi Agent 上：

```bash
# 1. 安装 shell 库
mkdir -p ~/.agent
scp agent-safe-fs.sh pi@agent:~/.agent/safe-fs.sh
scp agent-checkpoint.sh pi@agent:~/.agent/agent-checkpoint.sh

# 2. 将上面的 agents.md 内容追加到 Pi Agent 的系统提示词

# 3. 验证
source ~/.agent/safe-fs.sh && ensure_directory /tmp/pi-test
# 应输出: {"ok":true,...}
```
