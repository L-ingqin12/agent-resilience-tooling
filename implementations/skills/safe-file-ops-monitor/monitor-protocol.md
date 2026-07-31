# Sub-Agent Reliability Monitoring Protocol

## Architecture: Main Skill + Monitored Sub-Agents

```
┌──────────────────────────────────────────────────────────────┐
│  Main Agent (runs safe-file-ops-monitor Skill)                │
│                                                               │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │ Task Planner                                             │ │
│  │ - Decompose: "setup /tmp/app" → [mkdir, write, mkdir]   │ │
│  │ - Assign checkpoint seq to each step                     │ │
│  │ - For each step, track: goal, approaches_tried, status   │ │
│  └─────────────────────────────────────────────────────────┘ │
│                          │                                    │
│    ┌─────────────────────┼─────────────────────┐              │
│    ▼                     ▼                     ▼              │
│  ┌────────┐         ┌────────┐         ┌────────┐            │
│  │Sub-A 1 │         │Sub-A 2 │         │Sub-A 3 │            │
│  │mkdir   │         │write   │         │mkdir   │            │
│  │/tmp/app│         │config  │         │/logs   │            │
│  └────────┘         └────────┘         └────────┘            │
│    │                   │                   │                  │
│    ▼                   ▼                   ▼                  │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │ Reliability Judge (main agent evaluates each result)     │ │
│  │                                                         │ │
│  │ RELIABLE signals:                                       │ │
│  │   ✓ {"ok":true,...}                → success, continue  │ │
│  │   ✓ {"ok":false,"error":{...}}      → classified error  │ │
│  │                                                         │ │
│  │ UNRELIABLE signals:                                     │ │
│  │   ✗ EMPTY output                    → crashed           │ │
│  │   ✗ Same error as previous attempt   → deadloop         │ │
│  │   ✗ No JSON in output               → confused          │ │
│  │   ✗ Sub-agent timed out             → hung             │ │
│  │   ✗ Output is markdown/excuses       → misbehaving      │ │
│  │   ✗ Sub-agent tried mkdir not ensure_directory → rogue │ │
│  └─────────────────────────────────────────────────────────┘ │
│                          │                                    │
│                   ┌──────┴──────┐                             │
│                   ▼             ▼                             │
│              RELIABLE      UNRELIABLE                         │
│              continue      intervene                          │
│                            │                                  │
│                   ┌────────┼────────┐                         │
│                   ▼        ▼        ▼                         │
│               Kill     Inject    Re-spawn                     │
│               sub-A    recovery  with new                     │
│                        context   approach                     │
└──────────────────────────────────────────────────────────────┘
```

## 1. Reliability Signals

### RELIABLE — Sub-agent can be trusted

| Signal | JSON Pattern | Action |
|--------|-------------|--------|
| Success | `"ok":true` | Save checkpoint, continue to next step |
| Classified error | `"ok":false`, `"error":{"code":"E_*"}` | Read `retryable` field, decide accordingly |
| Non-retryable error | `"retryable":false` | Do NOT re-spawn. Switch strategy or escalate. |

### UNRELIABLE — Sub-agent must be overridden

| Signal | Detection | Severity | Action |
|--------|-----------|:---:|--------|
| **Empty output** | `result == ""` or only whitespace | CRITICAL | Kill. DO NOT re-spawn same approach. |
| **Deadloop** | Same goal + same approach appeared in `checkpoints.jsonl` ≥2 times | CRITICAL | Kill. Switch strategy. Inject DO_NOT_RETRY. |
| **No valid JSON** | Output doesn't parse as JSON | HIGH | Kill. Re-spawn with stricter prompt. |
| **Timeout** | Sub-agent took >30s | HIGH | Kill. Re-spawn with simpler approach. |
| **Wrong approach** | Sub-agent used mkdir instead of python_makedirs | MEDIUM | Warning. Compare result anyway. |
| **Circular reasoning** | Output contains "I think", "maybe", "let me try" | MEDIUM | Kill. The sub-agent is confused. |
| **Hallucinated path** | Result path doesn't match requested path | HIGH | Kill. Verify filesystem state. |

## 2. Intervention Protocol

When sub-agent is UNRELIABLE:

```
Step 1: TERMINATE
  - If sub-agent is still running → kill it
  - Record the failure in checkpoints.jsonl

Step 2: CLASSIFY
  - What went wrong? (empty? deadloop? timeout?)
  - Is this the first failure or a pattern?
  - Which strategies have been exhausted?

Step 3: DECIDE
  ┌─────────────────────────────────────────────────┐
  │ First failure:                                   │
  │   → Re-spawn with SAME approach, stricter prompt │
  │   → "You MUST use {approach}. Return ONLY JSON." │
  │                                                 │
  │ Second failure (same approach):                  │
  │   → DEADLOOP detected                           │
  │   → Switch to NEXT strategy from strategy table  │
  │   → Inject DO_NOT_RETRY context                  │
  │   → Re-spawn with NEW approach                   │
  │                                                 │
  │ All strategies exhausted:                        │
  │   → Rollback to last checkpoint                  │
  │   → Report to user with full context             │
  │   → "Steps 1-2 preserved. Step 3 failed after   │
  │      trying [A, B, C]. You need to [action]."   │
  └─────────────────────────────────────────────────┘

Step 4: EXECUTE
  - Apply the decision
  - Monitor the result
  - If still unreliable → escalate decision level
```

## 3. Sub-Agent Prompt Structure

Each sub-agent gets a minimal, single-purpose prompt:

```
You are a single-purpose file operation agent.
Operation: {OPERATION} on {PATH}
Approach: {APPROACH}
Forbidden: {LIST_OF_FAILED_APPROACHES}

Source: ~/.agent/safe-fs.sh
Execute: {SPECIFIC_COMMAND}
Return: ONLY the JSON result. Nothing else.

If you cannot execute, return:
{"ok":false,"error":{"code":"E_SYSTEM_CATASTROPHE","retryable":false}}
```

The prompt is deliberately minimal to prevent:
- Sub-agent deviating from the specified approach
- Sub-agent trying alternative approaches (main agent's job)
- Sub-agent producing verbose output instead of clean JSON

## 4. Feasibility Analysis

### Claude Code Implementation

```
Main Agent (this conversation)
  │
  ├── Skill: safe-file-ops-monitor loads
  │   - Teaches main agent the monitoring protocol
  │   - Provides the sub-agent prompt template
  │   - Provides the reliability judge logic
  │
  ├── For each file operation:
  │   Agent tool → subagent_type: "general-purpose"
  │   prompt: [sub-agent prompt with operation + approach + forbidden]
  │   run_in_background: false (must wait for result to monitor)
  │
  │   Main agent evaluates result:
  │   - RELIABLE → save checkpoint → next step
  │   - UNRELIABLE → intervention protocol
  │
  └── All steps done → report summary to user
```

### Constraints

| Constraint | Handling |
|-----------|---------|
| Sub-agents cost tokens | Each sub-agent is ~200-500 tokens (minimal prompt) |
| Sub-agents may also be unreliable | Main agent is the final judge — if all sub-agents fail, escalate |
| Sub-agent latency | 1-3 seconds per sub-agent (acceptable for file ops) |
| Sub-agent cannot access checkpoints | Main agent maintains checkpoints, sub-agents just execute |
| Recursive unreliability | Max depth: main → sub → ONE re-spawn. No deeper. |

### Advantages over Single-Agent Approach

| Single Agent | Main + Sub-Agent Monitor |
|-------------|------------------------|
| One LLM context getting longer | Sub-agents have clean, minimal contexts |
| Same LLM can get confused and loop | Main agent is "fresh" for monitoring |
| Hard to separate "planning" from "execution" | Clear separation: main plans, sub executes |
| Deadloop detection is self-referential | Deadloop detection is external observation |
| No natural "kill and retry" boundary | Sub-agent boundaries provide natural intervention points |

## 5. Integration with Existing Layers

```
L6 (Checkpoint Recovery)    → Main agent saves/loads checkpoints between sub-agent calls
L5 (Pi Agent Adaptation)    → Sub-agent prompts are ~150 tokens (fit in any budget)
L4 (Graceful Degradation)   → Empty output from sub-agent = UNRELIABLE signal
L3 (Error Classification)   → classify_result() called on sub-agent output
L2 (Safe Tool Abstraction)  → Sub-agents use ensure_directory, not mkdir
L1 (Root Cause Analysis)    → Sub-agent failures classified per the 9-scenario taxonomy
```

## 6. Self-Test for Monitor Protocol

```bash
# Test: Spawn sub-agent → monitor → detect deadloop → intervene → recover

# 1. Main agent spawns Sub-A for mkdir /tmp/test
# 2. Sub-A returns {"ok":false,"error":{"code":"E_PERM"}} → RELIABLE (classified)
# 3. Main agent spawns Sub-A again (same goal, same approach) → detects DEADLOOP
# 4. Main agent intervenes: marks deadloop, selects alternative strategy
# 5. Main agent spawns Sub-B with different approach (python_makedirs)
# 6. Sub-B returns {"ok":true} → RELIABLE, continue
# 7. Main agent saves checkpoint, reports success

# EXPECTED: 2 deadloop detections (correct), 1 recovery, 0 data loss
```
