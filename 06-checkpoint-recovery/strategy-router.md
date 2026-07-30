# 多策略路由器设计 (Strategy Router)

> **核心命题**: 当一种操作策略失败时，如何选择下一个策略？本文档定义策略选择算法、策略表和最终降级路径。

## 1. 策略表 (Strategy Table)

### 1.1 ensure_directory 策略

| 优先级 | 策略名 | 命令 | 适用条件 | 失败条件 | 熔断阈值 |
|:---:|--------|------|---------|---------|:---:|
| 0 | mkdir_p | `mkdir -p {path}` | always | EACCES, ENOSPC | 3 |
| 1 | python_makedirs | `python3 -c 'import os; os.makedirs("{path}", exist_ok=True)'` | python3 available | EACCES, OOM | 3 |
| 2 | perl_makedirs | `perl -e 'use File::Path; make_path("{path}")'` | perl available | EACCES | 3 |
| 3 | create_parents_first | `mkdir -p $(dirname {path}) 2>/dev/null; mkdir {path}` | ENOENT on parent | EACCES | 3 |
| 4 | fallback_path | `mkdir -p ~/.agent/fallback/{relpath}` | EACCES persistently | ENOSPC | 5 |
| 5 | report_only | No execution. Report to user with full context. | All strategies exhausted | never | ∞ |

### 1.2 ensure_file 策略

| 优先级 | 策略名 | 命令 | 适用条件 | 失败条件 | 熔断阈值 |
|:---:|--------|------|---------|---------|:---:|
| 0 | atomic_write | `cat > /tmp/.tmp-$$ && mv /tmp/.tmp-$$ {path}` | always | EACCES, ENOSPC | 3 |
| 1 | python_write | `python3 -c 'open("{path}","w").write(content)'` | python3 available | EACCES | 3 |
| 2 | dd_write | `dd of={path} 2>/dev/null` | always | EACCES, ENOSPC | 3 |
| 3 | heredoc_write | `cat > {path} << 'EOF'\n{content}\nEOF` | always (risky) | EACCES | 2 |
| 4 | fallback_path | write to `~/.agent/fallback/{relpath}` | EACCES persistently | ENOSPC | 5 |
| 5 | report_only | No execution. Report to user with full context. | All exhausted | never | ∞ |

### 1.3 safe_remove 策略

| 优先级 | 策略名 | 命令 | 适用条件 | 失败条件 | 熔断阈值 |
|:---:|--------|------|---------|---------|:---:|
| 0 | trash_move | `mv {path} /tmp/.agent-trash/{name}.{ts}` | always | EACCES, EXDEV | 3 |
| 1 | trash_rename | `mv {path} {path}.trash.{ts}` | EXDEV (cross-fs) | EACCES | 3 |
| 2 | copy_then_rm | `cp -r {path} /tmp/.agent-trash/ && rm -rf {path}` | EXDEV | ENOSPC | 3 |
| 3 | chmod_then_rm | `chmod -R u+w {path} 2>/dev/null; rm -rf {path}` | EACCES on contents | EACCES on parent | 2 |
| 4 | report_only | No execution. Report to user. | All exhausted | never | ∞ |

## 2. 策略选择算法

### 2.1 主算法: Error-Driven Strategy Selection

```python
def select_next_strategy(goal_type, failed_error_code, exhausted_strategies, circuit_breaker_state):
    """
    根据失败的错误码选择最合适的下一个策略。
    
    原则:
    1. 如果错误是 E_PERM → 优先选择不同执行路径的策略 (python3 vs bash)
    2. 如果错误是 E_NOSPC → 优先选择不需要额外磁盘空间的策略
    3. 如果错误是 E_IO → 优先选择最简单的策略 (减少 I/O 操作)
    4. 如果错误是 E_TIMEOUT → 优先选择更快的策略
    """
    strategy_table = load_strategy_table(goal_type)
    
    # Filter: remove exhausted strategies
    candidates = [s for s in strategy_table 
                  if s.name not in exhausted_strategies]
    
    # Filter: remove circuit-broken strategies (OPEN state)
    candidates = [s for s in candidates
                  if circuit_breaker_state.get(s.name) != "OPEN"]
    
    # HALF-OPEN strategies: allow one probe
    half_open = [s for s in candidates 
                 if circuit_breaker_state.get(s.name) == "HALF-OPEN"]
    
    if not candidates:
        return "report_only"  # Ultimate fallback
    
    # Scoring based on error type
    for s in candidates:
        s.score = s.base_priority
        
        if failed_error_code == "E_PERM":
            # Prefer different execution path
            if s.name in ["python_makedirs", "perl_makedirs", "python_write"]:
                s.score -= 0.5  # Lower = better
            if s.name == "fallback_path":
                s.score -= 1.0  # Best for persistent E_PERM
        
        elif failed_error_code == "E_NOSPC":
            # Prefer strategies that don't need extra space
            if s.name in ["create_parents_first", "trash_rename"]:
                s.score -= 0.5
        
        elif failed_error_code == "E_IO":
            # Prefer simplest strategy (fewest syscalls)
            if s.name in ["mkdir_p", "atomic_write", "trash_move"]:
                s.score -= 0.3
        
        elif failed_error_code == "E_TIMEOUT":
            # Prefer faster strategies
            if "python" in s.name:  # Python startup is slow
                s.score += 0.5
            if s.name in ["mkdir_p", "atomic_write"]:
                s.score -= 0.5
    
    # Give HALF-OPEN strategies a penalty (prefer CLOSED ones)
    for s in half_open:
        s.score += 1.0
    
    # Return the strategy with the lowest score
    candidates.sort(key=lambda s: s.score)
    return candidates[0].name
```

### 2.2 Bash 实现 (简化版)

```bash
strategy_router_select() {
    # Usage: strategy_router_select <goal_type> <failed_error_code> <exhausted_json_array>
    local goal_type="${1:-ensure_directory}" failed_error="${2:-E_UNKNOWN}" exhausted="${3:-[]}"
    
    case "$goal_type" in
        ensure_directory)
            case "$failed_error" in
                E_PERM)
                    # Persistent permission error → try different execution path
                    if ! echo "$exhausted" | grep -q "python_makedirs"; then
                        echo "python_makedirs"
                    elif ! echo "$exhausted" | grep -q "fallback_path"; then
                        echo "fallback_path"
                    else
                        echo "report_only"
                    fi ;;
                E_NOSPC)
                    if ! echo "$exhausted" | grep -q "create_parents_first"; then
                        echo "create_parents_first"
                    elif ! echo "$exhausted" | grep -q "fallback_path"; then
                        echo "fallback_path"
                    else
                        echo "report_only"
                    fi ;;
                E_IO|E_TIMEOUT)
                    if ! echo "$exhausted" | grep -q "python_makedirs"; then
                        echo "python_makedirs"
                    elif ! echo "$exhausted" | grep -q "mkdir_p"; then
                        echo "mkdir_p"
                    else
                        echo "report_only"
                    fi ;;
                *)
                    # Default: try remaining strategies in order
                    for s in mkdir_p python_makedirs perl_makedirs create_parents_first fallback_path; do
                        if ! echo "$exhausted" | grep -q "$s"; then
                            echo "$s"
                            return 0
                        fi
                    done
                    echo "report_only" ;;
            esac ;;
        ensure_file)
            # Similar logic for file strategies
            case "$failed_error" in
                E_PERM)
                    if ! echo "$exhausted" | grep -q "python_write"; then
                        echo "python_write"
                    elif ! echo "$exhausted" | grep -q "fallback_path"; then
                        echo "fallback_path"
                    else
                        echo "report_only"
                    fi ;;
                *)
                    for s in atomic_write python_write dd_write heredoc_write fallback_path; do
                        if ! echo "$exhausted" | grep -q "$s"; then
                            echo "$s"
                            return 0
                        fi
                    done
                    echo "report_only" ;;
            esac ;;
        *)
            echo "report_only" ;;
    esac
}
```

## 3. Circuit Breaker 状态管理

```bash
# Circuit breaker state file (one per strategy per goal_type)
CIRCUIT_BREAKER_FILE="${CHECKPOINT_DIR:-/tmp/.agent-checkpoints}/circuit_breaker.json"

circuit_breaker_state() {
    # Returns: CLOSED, OPEN, HALF_OPEN
    local strategy="${1:-}"
    local state
    state=$(grep "\"$strategy\":" "$CIRCUIT_BREAKER_FILE" 2>/dev/null | grep -o '"state":"[^"]*"' | sed 's/"state":"//;s/"//')
    echo "${state:-CLOSED}"
}

circuit_breaker_record_failure() {
    local strategy="${1:-}"
    local current_count
    current_count=$(grep "\"$strategy\":" "$CIRCUIT_BREAKER_FILE" 2>/dev/null | grep -o '"failures":[0-9]*' | grep -o '[0-9]*')
    current_count=$((${current_count:-0} + 1))
    
    if [ "$current_count" -ge 3 ]; then
        # OPEN: stop using this strategy
        local tmpfile="/tmp/.cb-$$.json"
        printf '{"%s":{"state":"OPEN","failures":%d,"opened_at":%s}}\n' \
            "$strategy" "$current_count" "$(date +%s)" > "$tmpfile"
        mv "$tmpfile" "$CIRCUIT_BREAKER_FILE" 2>/dev/null
        printf '{"circuit_breaker":"OPEN","strategy":"%s","failures":%d}\n' "$strategy" "$current_count"
    else
        local tmpfile="/tmp/.cb-$$.json"
        printf '{"%s":{"state":"CLOSED","failures":%d}}\n' "$strategy" "$current_count" > "$tmpfile"
        mv "$tmpfile" "$CIRCUIT_BREAKER_FILE" 2>/dev/null
        printf '{"circuit_breaker":"CLOSED","strategy":"%s","failures":%d}\n' "$strategy" "$current_count"
    fi
}

circuit_breaker_half_open() {
    # Transition from OPEN to HALF_OPEN after cooldown period
    local strategy="${1:-}" cooldown="${2:-30}"
    local opened_at now
    opened_at=$(grep "\"$strategy\":" "$CIRCUIT_BREAKER_FILE" 2>/dev/null | grep -o '"opened_at":[0-9]*' | grep -o '[0-9]*')
    now=$(date +%s)
    
    if [ -n "$opened_at" ] && [ "$((now - opened_at))" -gt "$cooldown" ]; then
        printf '{"%s":{"state":"HALF_OPEN","failures":3,"opened_at":%s}}\n' "$strategy" "$opened_at" > "${CIRCUIT_BREAKER_FILE}.tmp"
        mv "${CIRCUIT_BREAKER_FILE}.tmp" "$CIRCUIT_BREAKER_FILE" 2>/dev/null
        printf '{"circuit_breaker":"HALF_OPEN","strategy":"%s"}\n' "$strategy"
        return 0
    fi
    printf '{"circuit_breaker":"OPEN","strategy":"%s","retry_after":%d}\n' "$strategy" "$((cooldown - (now - opened_at)))"
    return 1
}

circuit_breaker_reset() {
    # Reset to CLOSED on success
    local strategy="${1:-}"
    printf '{"%s":{"state":"CLOSED","failures":0}}\n' "$strategy" > "${CIRCUIT_BREAKER_FILE}.tmp"
    mv "${CIRCUIT_BREAKER_FILE}.tmp" "$CIRCUIT_BREAKER_FILE" 2>/dev/null
    printf '{"circuit_breaker":"CLOSED","strategy":"%s"}\n' "$strategy"
}
```

## 4. LLM 认知引导中的策略切换指令

在 agents.md 中注入的策略切换认知：

```markdown
## Strategy Switching Protocol (When a command fails)

When you detect that the SAME command on the SAME path has failed twice,
DO NOT try it a third time. Instead, follow this protocol:

### Step 1: Recognize the pattern
- "I tried mkdir -p /path → E_PERM"
- "I tried mkdir -p /path again → E_PERM (same error)"
- This is a DEADLOOP. Do not repeat.

### Step 2: Select a DIFFERENT strategy
Based on the error type, choose:

E_PERM → python3 -c 'import os; os.makedirs()'  (different execution path)
E_NOSPC → fallback_path (different filesystem)
E_IO → simplest possible operation (fewer syscalls)
E_TIMEOUT → decrease scope (create parent dir first, then child)

### Step 3: Execute the alternative
- Run the alternative command
- Compare the result
- If successful → save checkpoint and continue
- If failed → select NEXT strategy (not the same one)

### Step 4: When all strategies fail
- Revert to the last successful checkpoint
- Skip already-completed steps (verify their state first)
- Report to user with full context:
  "Step N failed after trying [strategy1, strategy2, strategy3].
   Steps 1..N-1 are preserved. You need to [specific action]."
```
```

## 5. 与公开知识对照

| 概念 | 来源 | 在策略路由器中的体现 |
|------|------|-------------------|
| Error-Driven Selection | Netflix Hystrix fallback | failed_error_code 驱动策略选择 |
| Strategy Priority Queue | Load Balancer Weighted Round-Robin | base_priority + score 排序 |
| Circuit Breaker | Michael Nygard "Release It!" | CLOSED→OPEN→HALF_OPEN 三态转换 |
| Exponential Backoff | AWS Well-Architected Framework | HALF_OPEN 前有 cooldown 冷却期 |
| Branch-and-Bound | AI Search Algorithms | 策略耗尽的路径被剪枝 (dead_end) |
| Graceful Degradation | Google SRE | report_only 是最终降级，保留用户上下文 |
| Least Astonishment | UX Design Principle | 策略按"最不意外"排序：总是先试最简单的 |
