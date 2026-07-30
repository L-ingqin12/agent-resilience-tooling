# 断点恢复与多策略回退设计 (Checkpoint Recovery Design)

> **核心命题**: 死循环检测后不退出，而是回退到上一个成功的 checkpoint，用不同的策略重试失败步骤，继续执行剩余任务。已完成步骤零重复。

## 1. 理论基础：公开知识与最佳实践映射

| 来源领域 | 模式/概念 | 在本方案中的应用 | 关键引用 |
|---------|----------|----------------|---------|
| **数据库 ACID** | Savepoint + Rollback to Savepoint | `checkpoint_save()` → `checkpoint_rollback(seq)` | PostgreSQL SAVEPOINT / ROLLBACK TO |
| **数据库 WAL** | Write-Ahead Log (append-only, immutable) | `checkpoints.jsonl` 只追加不修改，崩溃后重放恢复 | SQLite WAL mode, PostgreSQL WAL |
| **分布式事务** | Saga Pattern (compensating transactions) | 回退时执行 undo (rmdir 已创建的半成品目录) | Garcia-Molina & Salem 1987 |
| **分布式事务** | Event Sourcing | 从 checkpoint 事件流重建当前进度 | Greg Young, CQRS/ES |
| **OS 内核** | Journaling Filesystem | 先写 checkpoint 日志，再执行实际操作 | ext4 journal, NTFS journal |
| **韧性工程** | Circuit Breaker | 策略切换状态机: CLOSED→OPEN→HALF-OPEN | Michael Nygard, "Release It!" (2007) |
| **韧性工程** | Retry with Backoff | 同一策略每次重试增加冷却时间 | AWS Architecture Best Practices |
| **设计模式** | Command Pattern + Undo | 每个操作携带 undo 函数 | GoF Design Patterns (1994) |
| **设计模式** | Memento Pattern | pre_state / post_state 状态快照 | GoF Design Patterns (1994) |
| **Git** | Commit = Checkpoint | 每次成功操作 = 一次不可变 commit | Git internals |
| **Git** | Reflog = Recovery | checkpoint log 记录所有操作，可回溯到任意点 | `git reflog` |
| **Git** | Staging Area | 操作前暂存状态 → 成功后 commit → 失败后 reset | Git index |
| **搜索算法** | Backtracking | 步骤N失败 → 回溯到步骤N-1 → 尝试替代方案 | AI/CS 经典算法 |
| **搜索算法** | Branch-and-Bound | 策略耗尽的路径标记为 dead_end，不再探索 | AI 搜索优化 |
| **FP** | Immutable State | checkpoint 记录只追加，状态不可变 | Haskell, Clojure 核心原则 |
| **Google SRE** | Error Budget | 每个策略有失败预算，耗尽 → 切换策略 | Google SRE Book (2016) |

## 2. 核心设计原则

### 2.1 Append-Only Checkpoint Log (WAL 模式)

```
所有状态变更先写入 checkpoint log，再执行实际操作。
日志只追加，不原地修改。
崩溃后从日志重放，重建最后一致状态。
原子写入: write to tmpfile → mv to log (POSIX 保证 mv 是原子的)
```

### 2.2 State Verification Before Skip (信任但验证)

```
恢复时不能假设 checkpoint 的状态仍然有效：
- 磁盘可能已被外部修改
- 文件可能已被其他进程删除
- 权限可能在操作间变更

每个 checkpoint 恢复前必须验证 post_state:
  checkpoint: {post_state: "directory"}  → 恢复时执行 test -d PATH
  checkpoint: {post_state: "file_sha256:abc123"} → 恢复时执行 sha256sum
```

### 2.3 Strategy Fallback Chain (分层降级)

```
每个 goal_type 有多个策略，按可靠性排序：
  Strategy[0] (首选): 最简单、最快、最可靠
  Strategy[1] (备选): 解决 Strategy[0] 无法处理的错误
  Strategy[2] (备选): 更通用但更慢
  ...
  Strategy[N] (最后手段): 总是可用但可能改变行为（如切换路径）
```

### 2.4 Undo-on-Rollback (Saga 补偿)

```
回退到 checkpoint N-1 时：
  1. 读取 checkpoint N 的 undo 字段
  2. 执行 undo 操作（清除步骤 N 的半成品）
  3. 验证回退后状态与 checkpoint N-1 的 post_state 一致
  4. 标记 checkpoint N 为 rolled_back
```

### 2.5 Circuit Breaker per Strategy (策略级熔断)

```
每个 strategy 独立熔断：
  ┌──────────┐  连续失败3次  ┌──────────┐  冷却30s后尝试  ┌────────────┐
  │  CLOSED  │ ───────────→ │   OPEN   │ ──────────────→ │ HALF-OPEN  │
  │  正常使用 │              │  熔断    │                  │  试探一次   │
  └──────────┘              └──────────┘                  └────────────┘
                                   ↑                            │
                                   │    试探失败 → 回到 OPEN      │
                                   └────────────────────────────┘
                                        试探成功 → CLOSED
```

## 3. Checkpoint 文件格式

### 3.1 JSONL Schema

```json
// 成功记录:
{"seq":1,"goal":"/tmp/app exists as directory","op":"ensure_directory","state":"completed","approach":"mkdir_p","pre_state":"none","post_state":"directory","undo":"rmdir /tmp/app","verified_at":1700000000,"ts":1700000000}

// 失败/死循环记录:
{"seq":2,"goal":"/tmp/app/data exists","op":"ensure_directory","state":"deadloop","approach":"mkdir_p","attempts":[{"attempt":1,"approach":"mkdir_p","error":"E_PERM","errno":13,"ts":1700000001},{"attempt":2,"approach":"mkdir_p","error":"E_PERM","errno":13,"ts":1700000002}],"strategies_exhausted":["mkdir_p"],"strategies_remaining":["python_makedirs","create_parents_first","fallback_path"],"circuit_breaker":{"mkdir_p":"OPEN","python_makedirs":"CLOSED"},"ts":1700000002}

// 已回退记录:
{"seq":2,"goal":"/tmp/app/data exists","op":"ensure_directory","state":"rolled_back","rollback_reason":"all strategies exhausted","undo_executed":"rmdir /tmp/app/data","rolled_back_to_seq":1,"ts":1700000003}

// 替代策略成功记录:
{"seq":2,"goal":"/tmp/app/data exists","op":"ensure_directory","state":"completed","approach":"python_makedirs","pre_state":"rolled_back","post_state":"directory","undo":"rmdir /tmp/app/data","verified_at":1700000004,"prev_attempt_seq":2,"ts":1700000004}
```

### 3.2 字段定义

| 字段 | 类型 | 说明 |
|------|------|------|
| seq | int | 递增序号，全局唯一 |
| goal | string | 人类可读的目标描述 |
| op | string | 操作类型 (ensure_directory/ensure_file/safe_remove) |
| state | enum | completed/deadloop/rolled_back/in_progress |
| approach | string | 使用的策略名 |
| pre_state | string | 操作前状态 |
| post_state | string | 操作后状态（用于恢复验证） |
| undo | string | 回退命令 |
| attempts | array | 失败尝试列表 |
| strategies_exhausted | array | 已耗尽的策略 |
| strategies_remaining | array | 尚未尝试的策略 |
| circuit_breaker | object | 各策略熔断状态 |
| verified_at | int | 验证时间戳 |
| prev_attempt_seq | int | 如果是重试成功，指向之前的失败记录 |

## 4. 回退决策树

```
Step N 检测到死循环 (同一 goal 连续失败 ≥ 2 次)
  │
  ├── [1. Deadloop Confirmation]
  │   确认是死循环而非暂时性错误:
  │   - 同一 path + 同一 approach 连续失败 2 次 = deadloop
  │   - 同一 path + 同一 error code 连续失败 = deadloop
  │   - 不同 path 失败 → 不是 deadloop，分别处理
  │
  ├── [2. Circuit Breaker Check]
  │   检查当前 approach 的熔断状态:
  │   - OPEN → 跳过该策略，直接选下一个
  │   - HALF-OPEN → 允许尝试一次
  │   - CLOSED → 正常使用
  │
  ├── [3. Strategy Selection]
  │   从 strategy_router 获取下一个未尝试的策略:
  │   ├── Has strategies_remaining:
  │   │   ├── Select: 按 error_code → 选最匹配的策略
  │   │   │   例: E_PERM → python_makedirs (不同执行方式)
  │   │   │   例: E_PERM → fallback_path (换路径)
  │   │   └── Execute with new approach
  │   │
  │   └── All strategies exhausted:
  │       ├── [4a. Saga Rollback] 回退到 checkpoint N-1
  │       ├── [4b. Execute Undo] 清除半成品
  │       ├── [4c. Verify Rollback] 确认状态回到 checkpoint N-1
  │       ├── [4d. Skip Completed] 验证 1..N-1 的目标仍有效 → 跳过
  │       └── [4e. Report with Full Context]
  │           报告格式:
  │           "Step N failed after exhausting all strategies.
  │            Steps 1..N-1: PRESERVED (verified)
  │            Failed goal: /tmp/app/data
  │            Attempted: [mkdir_p(E_PERM), python_makedirs(E_PERM),
  │                        create_parents_first(E_PERM), fallback_path(OK)]
  │            Recommendation: [手动授权 /tmp/app/ 目录的写权限]"
  │
  ├── [5. Execute with Alternative Strategy]
  │   ├── Success → checkpoint_save(N, approach=new) → Continue to N+1
  │   └── Failed → 回到 [2]（选下一个策略）
  │
  └── [6. Deep Rollback] (仅当步骤 N-1 也有问题)
      步骤 N 失败 + 步骤 N-1 状态验证失败
      → 回退到 checkpoint N-2
      → 对步骤 N-1 尝试替代策略
      → 深度递归直到找到稳定 checkpoint
```

## 5. 与现有系统的集成点

### 5.0 关键机制：失败上下文注入 (Failure Context Injection)

**这是整个断点恢复系统最重要的设计决策。**

当 Agent 从死循环中恢复到 checkpoint 时，仅仅"回到上一个断点"是不够的。LLM 天然会重复之前的行为模式。必须**显式告诉 LLM 为什么之前的操作失败了，以及为什么不能重复相同的操作**。

**实现方式**：checkpoint 恢复函数返回的不是简单的成功/失败，而是包含完整失败上下文的**结构化注入消息**。这个消息作为 tool_result 直接进入 LLM 的上下文窗口：

```json
{
  "ok": true,
  "recovered": true,
  "recovered_from_seq": 1,
  "skipped_steps": [
    {"seq": 1, "goal": "...", "verified": true},
    {"seq": 2, "goal": "...", "verified": true}
  ],
  "failed_step": {
    "seq": 3,
    "goal": "/tmp/app/data exists as directory",
    "original_approach": "mkdir_p",
    "why_failed": [
      "Attempt 1: mkdir_p → E_PERM (exit=1) — /tmp/app/data is not writable",
      "Attempt 2: mkdir_p → E_PERM (exit=1) — same error, confirmed non-retryable"
    ],
    "strategies_exhausted": ["mkdir_p"],
    "strategies_remaining": [
      {"name": "python_makedirs", "why": "python3 uses different syscall path, may bypass shell-level permission"},
      {"name": "create_parents_first", "why": "explicitly creates each parent dir, helps with inherited ACLs"},
      {"name": "fallback_path", "why": "uses ~/.agent/fallback/ as alternative root when primary path blocked"}
    ],
    "recommended_next": "python_makedirs",
    "DO_NOT_RETRY": ["mkdir_p on /tmp/app/data"]
  },
  "context_for_llm": "Step 3 (create /tmp/app/data) failed with E_PERM using mkdir_p. Do NOT retry mkdir_p — it will fail identically. Use python_makedirs strategy instead. Steps 1-2 are verified and preserved."
}
```

**为什么这很重要？**

没有失败上下文注入的 LLM 行为:
```
Agent: [恢复到 checkpoint 2]
Agent: "我需要创建 /tmp/app/data"
Agent: mkdir -p /tmp/app/data    ← 重复同样的错误！
Output: E_PERM
Agent: "失败了，再试"
Agent: mkdir -p /tmp/app/data    ← 死循环重演
```

有失败上下文注入的 LLM 行为:
```
Agent: [收到注入消息]
       "Step 3 failed with E_PERM using mkdir_p. Do NOT retry mkdir_p.
        Use python_makedirs strategy instead."
Agent: "mkdir_p 被标记为 DO_NOT_RETRY。使用 python_makedirs 替代。"
Agent: python3 -c 'import os; os.makedirs("/tmp/app/data", exist_ok=True)'  ← 不同方案
Output: success
Agent: "替代方案成功。继续下一步。"
```

**注入消息的构造原则（来自公开知识）**:

| 原则 | 来源 | 在注入消息中的应用 |
|------|------|------------------|
| **展示后果** | SRE Postmortem 文化 (Google) | `why_failed` 字段详细记录每次失败的根因 |
| **提供选项** | Decision Theory (Kahneman & Tversky) | `strategies_remaining` 给 LLM 选择而非指令 |
| **明确禁止** | Safety Engineering (STAMP/STPA) | `DO_NOT_RETRY` 显式禁止特定危险操作 |
| **保留上下文** | Contextual Inquiry (Beyer & Holtzblatt) | `context_for_llm` 人类可读摘要，适合 LLM 处理 |
| **可验证声明** | Formal Methods (Hoare Logic) | `verified: true` 是经过实际系统调用验证的结果 |
| **因果关系** | Root Cause Analysis (Ishikawa) | `why_failed` 包含 why，不只是 what |

### 5.1 修改 agent-safe-fs.sh

```bash
# 每个 ensure_* 函数成功后:
ensure_directory() {
    # ... existing logic ...
    if [ "$ok" = "true" ]; then
        # NEW: Save checkpoint on success
        checkpoint_save "ensure $path exists as directory" \
                        "ensure_directory" \
                        "mkdir_p" \
                        "none" \
                        "directory" \
                        "rmdir $path"
    fi
}

# 新增: 执行前检查是否有 checkpoint 需要恢复
ensure_directory() {
    # NEW: Check if this goal was already completed
    local existing
    existing=$(checkpoint_lookup "ensure $path exists as directory" "completed")
    if [ -n "$existing" ]; then
        # Verify the state still holds
        if [ -d "$path" ]; then
            echo '{"ok":true,"checkpoint":"recovered","seq":'"$existing"'}'
            return 0
        fi
    fi
    # ... continue with normal execution ...
}
```

### 5.2 修改 guard_exec

```bash
guard_exec() {
    # Stage 0 (NEW): Check for deadloop
    local deadloop
    deadloop=$(checkpoint_detect_deadloop "$goal" "$approach")
    if [ -n "$deadloop" ]; then
        # Delegate to recovery logic instead of returning error
        checkpoint_recover "$deadloop"
        return
    fi
    # ... existing stages ...
}
```

### 5.3 修改 classify_result

```bash
classify_result() {
    # ... existing classification ...
    # NEW: Add fallback field
    printf '{"code":"%s","layer":"%s","retryable":%s,"suggestion":"%s","requires_fallback":%s}\n' \
        "$code" "$layer" "$retryable" "$suggestion" \
        "$([ "$retryable" = "false" ] && echo "true" || echo "false")"
}
```

### 5.4 修改 agents.md 认知引导

在 STOP 条件部分增加：

```markdown
## When Deadloop is Detected (DO NOT EXIT — RECOVER)

Instead of stopping, follow the RECOVERY PROTOCOL:

1. Check ~/.agent/checkpoints.jsonl for last successful checkpoint
2. Verify the checkpoint state still holds (test -d PATH)
3. Pick a DIFFERENT approach from the strategy table:
   - mkdir -p failed → try python3 -c 'os.makedirs()'
   - python3 failed → try create parent dirs manually
   - All failed → try alternative path (~/.agent/fallback/)
4. Execute the alternative. If successful, save new checkpoint and CONTINUE
5. Only report to user when ALL strategies for ALL checkpoints are exhausted
```

## 6. Pi Agent 约束适配

| 约束 | 适配方案 |
|------|---------|
| 800 tokens prompt | checkpoint 逻辑在 shell library 中，prompt 只含 ~80 tokens 恢复指令 |
| 4 tools only | checkpoint 文件通过 bash (cat/echo) 读写，不依赖外部数据库 |
| 无 middleware | checkpoint 调用嵌入在 ensure_* 函数中，无需钩子 |
| 无 tool injection | agent-checkpoint.sh 与 agent-safe-fs.sh 合并 source，不新增工具 |
| 512MB RAM | checkpoint 文件限制 100 行 (循环覆盖)，内存占用 < 10KB |

## 7. 验证场景

| 场景 | 预期行为 |
|------|---------|
| Step1成功→Step2成功→Step3死循环 | 回退到 Step2→切换策略→Step3成功→继续 |
| Step3所有策略耗尽 | 回退到 Step2(验证状态)→报告 (Step1-2保留) |
| Step3死循环 + Step2状态已损坏 | Deep rollback 到 Step1→Step2用替代策略→Step3重试 |
| 进程崩溃后重启 | 从 checkpoints.jsonl 重放，跳过已完成步骤 |
| 并发执行 | 基于 path 的锁: 同一 path 的 checkpoint 串行写入 |
