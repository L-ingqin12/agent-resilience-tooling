# Pi Agent Constraints and Design Space for Safe Tool Execution

## 1. Framework Profile

### Capabilities

| Dimension | Constraint |
|-----------|-----------|
| Available tools | `read`, `write`, `edit`, `bash` (exactly 4) |
| System prompt budget | ~800 tokens (shared with all other instructions) |
| Tool customization API | None (no native way to add/modify tools) |
| Extension mechanisms | Skills (pre-canned prompts), hooks/middleware (if framework supports), prompt injection into system prompt |
| Target hardware | Raspberry Pi (512 MB RAM) through cloud servers |
| Execution model | LLM generates tool calls; framework dispatches; LLM sees output |
| Error recovery | Primarily LLM-driven; framework may retry on transient failures |

### Extension Mechanism Details

- **Skills**: Pre-written prompt snippets that are injected into the context when activated. Cannot modify tool behavior directly; only influence the LLM's choices.
- **Hooks/Middleware**: Hypothetical pre/post execution hooks around tool calls. Not natively present in minimal agents, but could be added at the framework level. This is the Tier 3 target.
- **Prompt Injection**: Adding instructions to the system prompt that constrain how the LLM uses tools. The primary mechanism available today.

---

## 2. Constraint Analysis

### What CANNOT Be Done (within 800 tokens)

- **Full type system**: Cannot define a Hindley-Milner type system, sum types, or exhaustive pattern matching.
- **Exhaustive error taxonomy**: Cannot enumerate every possible `errno` (130+ values) with recovery strategies.
- **Complex state machine**: Cannot implement a multi-state FSM with guards, transitions, and side effects.
- **Formal verification**: Cannot embed model checking or proof-carrying code.
- **Complete DSL**: Cannot define a full domain-specific language with parser and interpreter.
- **Framework-level tool wrapping**: Cannot add a new tool or modify existing tool dispatch logic from within the prompt.
- **Persistent counters/state**: The LLM has no memory beyond the conversation window; cannot maintain counters across turns without external files.

### What CAN Be Done

- **Keyword triggers**: Short rules like "if you see `mkdir` without `--parents`, prepend `ensure_directory` instead."
- **Shell function libraries**: Ship a `.sh` file that the agent sources, then invoke its functions via `bash`.
- **Skill wrappers**: Encapsulate safety rules in a skill that is always activated.
- **Structured output contracts**: Require JSON responses from shell commands for machine-parseable success/failure signals.
- **Minimal guard heuristics**: 3-5 hard rules that cover 90%+ of dangerous operations (bare `mkdir`, bare `rm -rf`, unbounded `dd`, missing `--`).
- **Trash-style recovery**: `mv` to a trash directory instead of `rm`, giving a manual recovery path.

### The 800-Token Budget Allocation

```
Category                    Tokens  Description
─────────────────────────────────────────────────────
Core file operation rules    200    NEVER use mkdir/rm/cp without wrappers;
                                   ALWAYS use ensure_directory, ensure_file,
                                   safe_remove; idempotency requirements

Error response rules         200    If empty response → report error, don't
                                   silently retry; classify stderr by errno;
                                   structured JSON error format

Retry limits                 150    Max 3 attempts per operation, then
                                   escalate; exponential backoff not needed;
                                   different retry strategies per error class

Structured output contract   150    Every shell command returns JSON;
                                   schema: {"status":"ok|error","data":...,
                                   "error":{"code":"ENOENT","message":"..."}}

Emergency escape             100    If 3 consecutive empty responses from
                                   any tool → STOP execution and report;
                                   do not auto-retry; do not guess
─────────────────────────────────────────────────────
TOTAL                        800
```

---

## 3. Three Implementation Tiers

### Tier 1 — Prompt Only

**Description**: Inject safety rules directly into the 800-token system prompt. The LLM is instructed to follow file operation conventions.

**Mechanism**: Pure prompt engineering. No external files, no shell libraries, no framework hooks.

**Strengths**:
- Zero deployment: just change the prompt.
- No filesystem footprint.
- Works on any agent framework.

**Weaknesses**:
- LLM may ignore or forget rules (especially under context pressure).
- Rules compete with all other instructions for the 800-token budget.
- No enforcement mechanism: the LLM can still execute bare `rm -rf /`.
- Error handling is entirely dependent on LLM reasoning quality.

**Token allocation**: As shown in Section 2 above.

### Tier 2 — Shell Library + Prompt

**Description**: Ship a small shell library (`~/.agent/safe-fs.sh`) that the agent sources at startup. The prompt shrinks to just "always use `ensure_directory`, never `mkdir` directly". Enforcement shifts from the LLM (fallible) to the shell functions (deterministic).

**Mechanism**: The prompt tells the agent to source the library and use its functions. The functions themselves enforce safety (idempotency, error classification, structured output). The LLM only needs to remember to *call* the right function — the function guarantees correct behavior.

**Strengths**:
- Deterministic safety for file operations.
- Minimal prompt footprint (~250 tokens for the injection).
- Easy to audit: inspect the shell library directly.
- Can be versioned and updated independently of the agent.

**Weaknesses**:
- Requires the agent to reliably source the library (one-time cost).
- Cannot intercept raw `bash` calls that bypass the library (e.g., inline `rm -rf`).
- Shell functions cannot prevent all dangerous patterns (e.g., `dd if=/dev/zero of=/dev/sda`).

**Recommended as the default tier for Pi Agent deployments**.

### Tier 3 — Middleware Interception

**Description**: A pre-execution hook that intercepts all `bash` tool calls, pattern-matches against dangerous commands, and rewrites them to use safe wrappers.

**Mechanism**: The agent framework (or a shim) inspects each `bash` command before execution. If the command matches a dangerous pattern, it is transparently rewritten. An escape hatch (`--raw` flag) bypasses interception.

**Strengths**:
- Enforced at the framework level: the LLM cannot bypass it.
- Catches ALL bash commands, not just those using the shell library.
- Transparent: no change to the LLM's behavior or prompt.

**Weaknesses**:
- Requires framework-level support for pre-exec hooks.
- More complex to implement and maintain.
- Pattern matching may produce false positives (blocking legitimate commands).
- The escape hatch is a single point of failure if overused.

**Interface Specification**:

```typescript
// Pre-exec hook interface
interface PreExecHook {
  name: "safe-fs-intercept";
  priority: number;          // higher runs first
  fn: (cmd: string) => InterceptResult;
}

interface InterceptResult {
  action: "allow" | "rewrite" | "block";
  rewrittenCommand?: string; // if action === "rewrite"
  blockReason?: string;      // if action === "block"
}
```

**Pattern Replacement Table**:

| Raw Pattern | Replacement | Condition |
|-------------|-------------|-----------|
| `mkdir <path>` | `ensure_directory <path>` | Unless `-p` flag present with safe path |
| `rm <path>` | `safe_remove <path>` | Always |
| `rm -rf <path>` | `safe_remove <path>` | Always |
| `dd if=<src> of=<dst>` | `block` | If `dst` starts with `/dev/sd` or `/dev/mmcblk` |
| `> <file>` | `ensure_file <file>` | If `file` is not in `/tmp` |
| `<cmd>; rm <path>` | Split; rewrite `rm` portion | Always |

**Escape Hatch**: Any command prefixed with `--raw ` passes through without modification. The agent framework should log all escape hatch uses for audit.

---

## 4. Tier 1 Design: 800-Token Prompt Budget (Detailed)

```text
[FILE OPERATIONS - 200 tokens]
- NEVER use bare mkdir, rm, cp, mv, dd, or > redirection.
- ALWAYS use ensure_directory(path) for directory creation.
- ALWAYS use safe_remove(path) for file/directory deletion.
- ALWAYS use ensure_file(path, content) for writing files.
- Idempotency is required: ensure_directory(/x/y) must succeed
  even if /x/y already exists, without errors.

[ERROR HANDLING - 200 tokens]
- If a tool returns empty stdout + empty stderr, treat as error.
- Do NOT retry on empty response; report "EMPTY_RESPONSE".
- Classify errors: file not found (ENOENT), permission denied
  (EACCES), disk full (ENOSPC), timeout (ETIMEDOUT).
- Always produce structured JSON output from bash commands.

[RETRY LIMITS - 150 tokens]
- Maximum 3 attempts per operation. No more.
- After 3 failures, output {"status":"error","action":"escalate"}
  and stop. Do not attempt a 4th time with a different approach.
- Only retry on EAGAIN, EBUSY, or ETIMEDOUT. Do NOT retry on
  ENOENT, EACCES, EEXIST, or EINVAL — those are deterministic.

[STRUCTURED OUTPUT - 150 tokens]
All bash commands that perform file operations MUST return JSON:
{"status":"ok","data":{...}} on success
{"status":"error","error":{"code":"ENOENT","message":"..."}} on failure

[EMERGENCY ESCAPE - 100 tokens]
If you receive 3 consecutive empty responses (empty stdout AND
empty stderr) from any tool, STOP immediately. Do not retry.
Do not attempt alternative approaches. Output a final error
report and wait for human intervention.
```

---

## 5. Tier 2 Design: Shell Library

See the companion file `agent-safe-fs.sh` in `minimal-implementation.md` for the complete implementation.

The library architecture follows these principles:

1. **Every function returns JSON** — even if the shell itself is crashing, the last thing we output is valid JSON.
2. **Idempotent by design** — `ensure_directory` never errors if the directory already exists; `ensure_file` never overwrites unless explicitly told to.
3. **Error classification** — `classify_errno` maps raw `errno` values to structured error codes that the LLM can act on.
4. **Self-contained** — uses only bash builtins, coreutils (`mkdir`, `mv`, `rm`, `stat`, `cat`, `timeout`), and `/proc` filesystem. No external dependencies.
5. **Under 200 lines** — fits in a single file that can be sourced in under 10ms.

---

## 6. Tier 3 Design: Middleware Spec

### Hook Interface

```python
# Pseudocode for the middleware interceptor

import re
import shlex

DANGEROUS_PATTERNS = {
    r'\bmkdir\b': {
        'action': 'rewrite',
        'transform': lambda cmd: cmd.replace('mkdir', 'ensure_directory', 1)
    },
    r'\brm\b': {
        'action': 'rewrite',
        'transform': lambda cmd: re.sub(r'\brm\b(?!\s*-rf\s+/--no-preserve-root)', 'safe_remove', cmd)
    },
    r'\bdd\b.*\bof=(/dev/sd|/dev/mmcblk)': {
        'action': 'block',
        'reason': 'dd to block device detected — unsafe without confirmation'
    },
}

ESCAPE_HATCH = '--raw'

def pre_exec_hook(command: str) -> dict:
    """Intercept and optionally rewrite/block a bash command."""

    # Escape hatch: prefix with --raw to bypass all checks
    if command.startswith(ESCAPE_HATCH):
        return {
            'action': 'allow',
            'rewritten_command': command[len(ESCAPE_HATCH):].lstrip()
        }

    # Check each dangerous pattern
    for pattern, rule in DANGEROUS_PATTERNS.items():
        if re.search(pattern, command):
            if rule['action'] == 'block':
                return {'action': 'block', 'reason': rule['reason']}
            elif rule['action'] == 'rewrite':
                return {'action': 'rewrite', 'rewritten_command': rule['transform'](command)}

    return {'action': 'allow'}
```

### Integration Points

| Framework Component | Hook Location | Responsibility |
|--------------------|---------------|----------------|
| Tool dispatcher | Before `bash` execution | Call `pre_exec_hook()`; act on result |
| Audit logger | After execution | Log original command, rewritten command, and result |
| Error handler | On blocked command | Return structured error to LLM explaining why |

### Escape Hatch Audit Log Schema

```json
{
  "timestamp": "ISO8601",
  "original_command": "rm -rf /var/log/old-backups",
  "interception": "rewrite|block|bypass",
  "bypass_reason": "user-requested | --raw flag",
  "result": "allowed | blocked | rewritten"
}
```
