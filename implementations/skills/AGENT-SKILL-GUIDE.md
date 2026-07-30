# Skill 形式接入完整指南

## 概览

本方案提供**纯 Skill 形式**接入，适用于任何支持 Skill/可复用模板的 Agent 框架（Claude Code Skill、OpenAI GPT Action、自定义 Agent Skill）。

### 核心思想

> Agent 的 agents.md 只管"什么时候触发 Skill"。
> Skill 的 SKILL.md 管"具体怎么做"。
> Shell library 管"实际执行"。

```
agents.md (系统提示词, ~100 tokens)
    ↓ 触发
safe-file-ops Skill (SKILL.md, ~600 tokens)
    ↓ 调用
agent-safe-fs.sh + agent-checkpoint.sh (实际执行)
```

## 1. 文件结构

```
~/.agent/
├── safe-fs.sh                 # 安全文件操作 shell library
├── agent-checkpoint.sh        # 断点恢复 shell library
├── skills/
│   └── safe-file-ops/
│       └── SKILL.md           # 技能定义（核心）
└── agents.md                  # Agent 系统提示词（极简）
```

## 2. agents.md 怎么写（~100 tokens）

这是 Agent 的系统提示词。只写**触发规则**和**核心原则**，不写操作细节：

```markdown
## File System Safety

You have access to the `safe-file-ops` skill. This skill MUST be triggered
before ANY operation that creates, modifies, or deletes files or directories.

### Trigger Keywords (ANY of these → invoke safe-file-ops skill FIRST):
mkdir, rm, touch, cat >, dd, chmod, chown, mv, cp (to new location)

### Source the libraries first:
```bash
source ~/.agent/safe-fs.sh && source ~/.agent/agent-checkpoint.sh
```

### Core Rules (if skill is unavailable, follow these):
1. NEVER use bare `mkdir` — always `mkdir -p` with `2>&1; echo "EXIT:$?"`
2. Empty output from ANY command = system crisis — STOP immediately
3. Same command on same path failed 2 times → STOP and try DIFFERENT approach
4. Use `ensure_directory` / `ensure_file` / `safe_remove` when available

### Recovery (when a step fails):
1. Check `~/.agent/checkpoints.jsonl` for last successful step
2. Verify the checkpoint state still holds (`test -d PATH`)
3. Skip verified steps — do NOT redo completed work
4. Try a DIFFERENT approach for the failed step (not the same command)
5. Only report to user when ALL alternative approaches are exhausted
```

**Token 分配**: ~100 tokens（在 800 token Pi Agent 预算中占 12%）

## 3. SKILL.md 怎么写（~600 tokens）

这是技能定义。写**完整的操作模板**和**错误处理逻辑**：

```markdown
# Skill: safe-file-ops

## Purpose
Prevent agent infinite loops caused by bare mkdir/rm/write operations.
Provides idempotent, structured-error-returning file system operations.

## When to Use (Trigger)
Invoke this skill BEFORE any of:
- Creating directories (`mkdir`)
- Writing files (`cat >`, `dd`, redirection)
- Deleting files (`rm`, `rmdir`)
- Changing permissions (`chmod`, `chown`)
- Moving/copying to new locations (`mv`, `cp`)

## Prerequisites
The shell libraries must be sourced before use:
```bash
source ~/.agent/safe-fs.sh 2>/dev/null || source /path/to/agent-safe-fs.sh 2>/dev/null
source ~/.agent/agent-checkpoint.sh 2>/dev/null || source /path/to/agent-checkpoint.sh 2>/dev/null
```

## Safe Operations (use these INSTEAD of bare commands)

### Creating a Directory
```bash
# INSTEAD OF: mkdir /path
# USE:
ensure_directory "/path"

# What it returns (JSON):
# Success: {"ok":true,"path":"/path","created":true,"existed_before":false,"error":null}
# Already exists: {"ok":true,"path":"/path","created":false,"existed_before":true,"error":null}
# Error: {"ok":false,"path":"/path","error":{"code":"E_PERM","layer":"permission","retryable":false,"suggestion":"Permission denied..."}}
```

### Writing a File (Atomic)
```bash
# INSTEAD OF: echo "content" > /path
# USE:
ensure_file "/path" "content"

# Atomic write: tempfile → mv (prevents partial writes)
# Returns: {"ok":true,"path":"/path","written":true}
```

### Removing a File/Directory (Trash-style)
```bash
# INSTEAD OF: rm -rf /path
# USE:
safe_remove "/path"

# Moves to /tmp/.agent-trash/ (recoverable)
# Returns: {"ok":true,"path":"/path","action":"trashed","trash_location":"/tmp/.agent-trash/name.ts"}
```

## Error Handling Protocol (CRITICAL)

### Step 1: Check the "ok" field
```bash
RESULT=$(ensure_directory "/path")
if echo "$RESULT" | grep -q '"ok":true'; then
    echo "Success — continue to next step"
else
    echo "Failure — classify before retrying"
fi
```

### Step 2: If failed, classify the error
| error.code | Meaning | Action |
|-----------|---------|--------|
| E_EXISTS | Already exists | THIS IS SUCCESS (for creation) — continue |
| E_PERM | Permission denied | DO NOT RETRY — use alternative path |
| E_NOSPC | Disk full | Retry ONCE after cleanup, then STOP |
| E_OOM | Out of memory | DO NOT RETRY — report system error |
| E_TIMEOUT | Command timed out | Retry ONCE with longer timeout |
| E_PATH | Parent missing | Create parent dirs, then retry ONCE |
| E_PATH_CONFLICT | File exists where dir needed | DO NOT RETRY — different path needed |
| E_SYSTEM_CATASTROPHE | Empty output | DO NOT RETRY — system may be crashing |

### Step 3: Use checkpoints before redoing work
```bash
# Before attempting a file operation, check if it was already completed:
checkpoint_skip_if_completed "ensure /path exists"
# Returns: {"skip":true} if already done and verified
# Returns: {"skip":false} if needs to be done (or state changed)
```

### Step 4: Save checkpoints after success
```bash
ensure_directory "/tmp/app"
checkpoint_save "ensure /tmp/app exists" "ensure_directory" "mkdir_p" "none" "directory" "rmdir /tmp/app"
```

## Deadloop Recognition
You are in a deadloop when:
- Same path + same command attempted 2+ times with same error
- Empty output from any command (not "didn't run" — process crashed)

When deadloop detected:
1. checkpoint_mark_deadloop "goal" "op" "approach" "[attempts]" "[remaining_strategies]"
2. checkpoint_recover <deadloop_seq>  # Returns recovery context with DO_NOT_RETRY
3. Read the recovery context — it tells you which approach NOT to retry and what to try instead
4. Execute the recommended alternative approach
5. If successful → checkpoint_save → continue
6. If failed → try next strategy from strategies_remaining

## Anti-Patterns (MUST avoid)

### WRONG: Blind retry
```
mkdir /app/logs → Permission denied
mkdir /app/logs → Permission denied  ← SAME command, SAME error = deadloop
```
### RIGHT: Classify then switch
```
ensure_directory /app/logs → {"ok":false,"error":{"code":"E_PERM","retryable":false}}
→ "E_PERM is non-retryable. I will create ~/app/logs instead. Proceed?"
```

### WRONG: Ignoring empty output
```
some_command → [empty]
some_command → [empty]  ← empty = system crisis, not "didn't run"
```
### RIGHT: Stop on empty
```
some_command → [empty]
→ "Command produced no output — possible system crash. STOPPING."
```
```

## 4. 安装步骤

### 一键安装

```bash
# Clone or copy the project
cd /path/to/agent-resilience-tooling

# Run the installer (auto-detects framework)
bash implementations/installer/install.sh

# Or manually:
mkdir -p ~/.agent/skills/safe-file-ops
cp agent-safe-fs.sh ~/.agent/safe-fs.sh
cp 06-checkpoint-recovery/agent-checkpoint.sh ~/.agent/agent-checkpoint.sh
cp implementations/skills/safe-file-ops.md ~/.agent/skills/safe-file-ops/SKILL.md
```

### 在 agents.md 中引用 Skill

**Claude Code**:
```markdown
# CLAUDE.md
[粘贴 s3-prompt-minimal.txt 的内容（见 implementations/prompts/）]
```

**OpenCode / Custom Agent**:
```markdown
# agents.md
[粘贴 s1-prompt-only.txt 的内容（完整750 token版本，不需要Skill支持）]
```

## 5. 三档 Skill 方案对比

| 方案 | agents.md tokens | Skill? | Shell Lib? | 防护率 | 适用场景 |
|:---|:---:|:---:|:---:|:---:|------|
| **Pure Skill** | ~100 | ✅ safe-file-ops | ✅ | ~85% | Claude Code, 支持Skill的框架 |
| **Prompt + Shell** | ~250 | ❌ | ✅ | ~75% | Pi Agent + 可source shell库 |
| **Prompt Only** | ~750 | ❌ | ❌ | ~60% | 仅能编辑系统提示词 |

## 6. 验证

```bash
# 1. 验证 shell library
source ~/.agent/safe-fs.sh
ensure_directory /tmp/test-skill
# 应输出: {"ok":true,"path":"/tmp/test-skill","created":true,...}

# 2. 验证 checkpoint library
source ~/.agent/agent-checkpoint.sh
checkpoint_save "test" "test" "test" "none" "none" ""
# 应输出: {"checkpoint_saved":true,"seq":1,...}

# 3. 验证 Skill 触发
# 在 Agent 中说: "创建 /tmp/test-skill-2 目录"
# Agent 应触发 safe-file-ops skill，使用 ensure_directory
# 而非直接执行 mkdir

# 4. 验证死循环恢复
# 模拟: 对无权限路径连续调用 ensure_directory
# Agent 应在2次失败后切换到替代策略（如 python3 makedirs 或 fallback_path）
# 而非第3次重试相同的 mkdir -p
```
