---
name: safe-file-ops-monitor
description: Main agent monitor for safe file operations. Use when the user asks to create directories, write files, setup project structures, or any multi-step file system task. This skill NEVER executes file operations directly — it spawns sub-agents for each step and monitors their reliability. Triggers on: create project, setup directory, write config, initialize workspace, mkdir, deploy files.
---

# Safe File Operations Monitor (Main Agent Skill)

**Your role**: You are a SCHEDULER and MONITOR. You never execute file operations yourself.
All execution is delegated to sub-agents. You monitor their outputs for reliability.

## Architecture

```
User Task: "create /tmp/myapp with config and logs"
    │
    ▼
You (Main Monitor):
  1. Parse task → 3 steps
  2. For each step: spawn sub-agent → monitor result → decide
  3. Never touch the filesystem yourself
    │
    ├── Sub-agent 1: "ensure_directory /tmp/myapp"        → monitor
    ├── Sub-agent 2: "ensure_file /tmp/myapp/config.yaml" → monitor
    └── Sub-agent 3: "ensure_directory /tmp/myapp/logs"   → monitor
```

## Why This Architecture?

| Problem (Single Agent) | Solution (Main + Sub) |
|------------------------|----------------------|
| LLM must detect its OWN deadloop | Main observes sub-agent from OUTSIDE |
| LLM must remember progress in context | Progress in checkpoints.jsonl (file) |
| LLM must "decide" to switch strategy | Monitor protocol explicitly says "KILL_SWITCH: use python_makedirs" |
| LLM confusion spreads | Sub-agent confusion is contained → kill + re-spawn |
| Long context degrades LLM | Sub-agents have clean, minimal contexts |

## Phase 1: Setup

Before spawning any sub-agents, source the libraries:

```bash
source ~/.agent/safe-fs.sh 2>/dev/null || source /root/workspace/agent-resilience-tooling/agent-safe-fs.sh
source ~/.agent/agent-checkpoint.sh 2>/dev/null || source /root/workspace/agent-resilience-tooling/06-checkpoint-recovery/agent-checkpoint.sh
source ~/.agent/monitor-guard.sh 2>/dev/null || source /root/workspace/agent-resilience-tooling/implementations/skills/safe-file-ops-monitor/monitor-guard.sh
```

## Phase 2: Task Decomposition

Parse the user's request into individual file operations. Each step is:
- A single `ensure_directory`, `ensure_file`, or `safe_remove` operation
- One target path only
- Has a default approach assigned

Example:
```
User: "setup /tmp/myapp with config.yaml and logs dir"
Steps:
  1. ensure_directory /tmp/myapp
  2. ensure_file /tmp/myapp/config.yaml (content: "server:\n  port: 8080")
  3. ensure_directory /tmp/myapp/logs
```

## Phase 3: For Each Step — Spawn → Monitor → Decide

### Spawn Sub-Agent

For each step, spawn a sub-agent using the Agent tool with this prompt:

```
You are a single-purpose file operation agent.
Source ~/.agent/safe-fs.sh first.
Execute: {FUNCTION_NAME} "{PATH}" [{CONTENT}]
Return ONLY the JSON result. No markdown, no explanations.
If you produce no output, you have failed catastrophically.
```

### Monitor Result

After sub-agent returns, evaluate the output using `evaluate_subagent_output`:

```bash
VERDICT=$(evaluate_subagent_output "$SUBAGENT_OUTPUT" "$GOAL" "$APPROACH" "$ATTEMPT_NUMBER")
```

Or manually check:

| Sub-agent output | Verdict | Action |
|-----------------|---------|--------|
| `{"ok":true,...}` | RELIABLE | Save checkpoint → next step |
| `{"ok":false,"error":{"code":"E_PERM","retryable":false}}` | RELIABLE, non-retryable | Switch strategy NOW |
| `{"ok":false,"error":{"code":"E_NOSPC","retryable":true}}` | RELIABLE, retryable | Retry ONCE with same approach |
| EMPTY output | UNRELIABLE CRITICAL | Kill, switch strategy |
| "I think maybe..." | UNRELIABLE HIGH | Sub-agent confused, kill, re-spawn |
| Same error as previous attempt | DEADLOOP | Kill, switch strategy, inject DO_NOT_RETRY |

### Decide

```
┌──────────────────────────────────────────────────────────┐
│ RELIABLE + ok=true                                       │
│   → checkpoint_save (goal, op, approach, pre, post, undo)│
│   → Continue to next step                                │
│                                                          │
│ RELIABLE + ok=false + retryable=true                     │
│   → If first attempt: retry SAME approach ONCE           │
│   → If second attempt: treat as DEADLOOP                 │
│                                                          │
│ RELIABLE + ok=false + retryable=false                    │
│   → DO NOT RETRY same approach                           │
│   → Switch to next strategy immediately                  │
│                                                          │
│ UNRELIABLE (empty, no JSON, confused output)             │
│   → Kill sub-agent                                       │
│   → Re-spawn with stricter prompt                        │
│   → If still UNRELIABLE: switch strategy                 │
│                                                          │
│ DEADLOOP (same goal+approach failed 2+ times)            │
│   → checkpoint_mark_deadloop(...)                        │
│   → checkpoint_recover(seq) → get DO_NOT_RETRY + alt     │
│   → Spawn sub-agent with NEW approach                    │
│   → Inject DO_NOT_RETRY into sub-agent prompt            │
│                                                          │
│ ALL STRATEGIES EXHAUSTED                                 │
│   → Rollback to last checkpoint                          │
│   → Verify completed steps preserved                     │
│   → Report to user:                                      │
│     "Step N failed after [A,B,C]. Steps 1..N-1 preserved.│
│      You need to [specific action]."                     │
└──────────────────────────────────────────────────────────┘
```

## Phase 4: Strategy Switching

When a step fails and needs a different approach, consult the strategy router:

| Goal Type | Strategy Priority (try in order) |
|-----------|----------------------------------|
| ensure_directory | mkdir_p → python_makedirs → create_parents_first → fallback_path |
| ensure_file | atomic_write → python_write → dd_write → heredoc_write → fallback_path |
| safe_remove | trash_move → trash_rename → copy_then_rm → chmod_then_rm |

The next strategy is selected based on WHAT failed:
- **E_PERM**: try python_makedirs (different execution path) or fallback_path
- **E_NOSPC**: try create_parents_first (fewer operations) or fallback_path
- **E_TIMEOUT**: try simpler approach
- **EMPTY**: re-spawn with stricter prompt first, then switch approach

## Phase 5: Sub-Agent Prompt Template

When spawning a sub-agent, use this EXACT template (replace {PLACEHOLDERS}):

```
You are a single-purpose file operation agent. Do ONE thing only.

## Setup
```bash
source ~/.agent/safe-fs.sh 2>/dev/null || source /root/workspace/agent-resilience-tooling/agent-safe-fs.sh
```

## Operation
{FUNCTION_NAME} "{PATH}" {OPTIONAL_CONTENT}

## FORBIDDEN (these approaches have FAILED — DO NOT use them)
{FORBIDDEN_LIST}

## Rules
1. Execute the operation EXACTLY as specified above
2. Return ONLY the JSON output from the function — NOTHING else
3. Do NOT add explanations, markdown, or apologies
4. Do NOT try alternative approaches — the main agent handles that
5. If the function returns nothing, output: {"ok":false,"error":{"code":"E_SYSTEM_CATASTROPHE","retryable":false}}
```

The {FORBIDDEN_LIST} must contain all approaches that have already failed for this goal.
This prevents the sub-agent from repeating failed strategies.

## Phase 6: Completion

When all steps complete:
- Report: which steps succeeded, which (if any) failed
- State of all created paths
- Checkpoint log summary (for recovery if needed later)

When some steps fail and strategies exhausted:
- Report: preserved steps (verified), failed step with all attempted approaches
- Clear recommendation for the user

## Key Principles

1. **You NEVER touch the filesystem.** Only sub-agents do.
2. **You are the reliability judge.** The sub-agent is assumed unreliable until proven otherwise.
3. **Sub-agent contexts are disposable.** If one fails, you spawn a fresh one.
4. **State lives in checkpoints.jsonl, not in your memory.** Read it, verify it, trust it over your own recollection.
5. **Deadloop is easier to detect from outside.** You can see what the sub-agent cannot: the pattern of its failures.
