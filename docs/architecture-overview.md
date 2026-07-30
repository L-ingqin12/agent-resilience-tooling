# 五层防护架构总览 (Architecture Overview)

## 1. 五层防护模型

```
┌──────────────────────────────────────────────────────────────────┐
│ Layer 6: Checkpoint Recovery (断点恢复层)          ← 🆕          │
│ 死循环感知 → 断点回退 → 失败上下文注入 → 多策略切换 → 继续执行    │
│ 策略: WAL + Saga + Circuit Breaker + Git-Reflog 式 checkpoint    │
├──────────────────────────────────────────────────────────────────┤
│ Layer 5: Pi Agent Adaptation (框架适配层)                         │
│ 800-token prompt + shell library → minimal footprint              │
│ 策略: 内联 shell 函数 + 提示词注入 + 技能包裹                     │
├──────────────────────────────────────────────────────────────────┤
│ Layer 4: Graceful Degradation (优雅降级层)                        │
│ CPU/内存耗尽 → structured fallback, never empty response           │
│ 策略: Pre-fork 健康检查 + timeout watchdog + 兜底错误生成器        │
├──────────────────────────────────────────────────────────────────┤
│ Layer 3: Error Classification (错误分类层)                        │
│ 错误性质感知 → classify → decide (retry/report/circuit-break)     │
│ 策略: 8 错误码 + 5 错误层 + 可重试性矩阵 + Python/Bash 双实现    │
├──────────────────────────────────────────────────────────────────┤
│ Layer 2: Safe Tool Abstraction (安全工具抽象层)                    │
│ 幂等封装 → ensure_directory, never mkdir                          │
│ 策略: ensure_*/safe_*/raw_* 三级架构，禁止裸调危险命令             │
├──────────────────────────────────────────────────────────────────┤
│ Layer 1: Root Cause Analysis (根因分析层)                          │
│ 理解死循环 → 9 scenarios → prevention taxonomy                    │
│ 策略: 场景分类 + 循环机理分析 + 三通道信息模型                     │
└──────────────────────────────────────────────────────────────────┘
```

## 2. 数据流图

```
Agent Decision
     │
     ▼
Tool Call ──→ [Pre-Call Guard] ──→ [Execution + Timeout] ──→ [Post-Call Validation]
                 │                        │                         │
                 │ 内存/负载/D状态检查     │ 30s timeout             │ 空输出检测
                 │ 参数合法性验证          │ partial output捕获      │ JSON格式验证
                 │                         │                         │
                 └─────────────────────────┴─────────────────────────┘
                                               │
                                               ▼
                                      [Error Classifier]
                                         │
                           ┌─────────────┼─────────────┐
                           ▼             ▼             ▼
                      retryable      non-retryable   unknown
                           │             │             │
                           ▼             ▼             ▼
                      [Retry Loop]  [Report/ESCALATE] [Fallback Generator]
                       max 3次        用户可见        ──→ 始终产出JSON
                           │             │             │
                           └─────────────┴─────────────┘
                                               │
                                               ▼
                                      Structured JSON Response
                                      {ok, path, created, error}
                                               │
                                               ▼
                                       Agent Response
```

**核心保证: 每一条路径终点都是结构化 JSON，永不为空。**

## 3. 决策矩阵

| 场景 | L1 根因 | L2 安全工具 | L3 错误分类 | L4 兜底 | L5 Pi Agent |
|------|---------|-----------|-----------|--------|------------|
| EEXIST | 目标函数错位 | ensure_directory 幂等 | E_EXISTS → retryable=false | N/A (L2 已捕获) | 提示词 "目录已存在=成功" |
| EACCES | 信息不对称 | 预检权限 | E_PERM → report_to_user | 结构化权限错误 | 提示词 "权限不足→报告不重试" |
| ENOENT | 状态不可观测 | ensure_directory create_parents | E_PATH → modify_params | N/A (L2 已处理) | 提示词 "父目录缺失→递归创建" |
| ENOSPC | 无代价意识 | 预检磁盘空间 | E_NOSPC → retryable=once | 磁盘满结构化错误 | df 检查函数 |
| OOM | 空响应最危险 | 预检 MemAvailable | E_OOM → circuit_break | Pre-fork 检查 + 兜底生成器 | guard_exec 包装 |
| I/O 阻塞 | 状态不可观测 | timeout 强制 | E_IO → circuit_break | timeout watchdog + D-state检测 | guard_exec 必带 timeout |
| 工具崩溃 | 信息不对称 | guard_exec 包装 | E_UNKNOWN → escalate | SIGCHLD 捕获 + 结构化错误 | guard_exec 必带信号处理 |
| 路径冲突 | 状态不可观测 | ensure_directory 预检 stat | E_PATH_CONFLICT → report_to_user | N/A (L2 已捕获) | 提示词 "同名文件→报错" |
| 符号链接 | 状态不可观测 | ensure_directory 预检 | E_PATH_CONFLICT → modify_params | N/A (L2 已处理) | readlink 检查 |

## 4. 跨层协作

```
Layer 2 是主力防线:
  85%+ 的 mkdir 死循环场景在 L2 被幂等工具直接消除
  → L3/L4 不需要介入

Layer 3 是决策大脑:
  当 L2 无法直接解决时（如权限、资源耗尽）
  → L3 分类错误性质，输出决策指令
  → L3 告诉 Agent: "这个错误可以重试" 或 "这个错误必须报告用户"

Layer 4 是安全网:
  当 L2/L3 全部失效（进程崩溃、OOM、I/O 阻塞）
  → L4 保证始终输出结构化 JSON
  → L4 的兜底生成器是最后一道防线

Layer 5 是适配器:
  将 L1-L4 的全部机制压缩到 Pi Agent 的 ~800 token 约束内
  → shell 函数库 (~200 行) + prompt (~250 tokens)
```

## 5. 框架对比

| 维度 | Pi Agent (裸) | Pi Agent + 本方案 | Claude Code | OpenCode | LangChain |
|------|:---:|:---:|:---:|:---:|:---:|
| mkdir 安全 | ❌ | ✅ 5层 | ⚠️ sandbox | ⚠️ subagent隔离 | ⚠️ Python库 |
| 错误分类 | ❌ | ✅ 8码5层 | ⚠️ 部分 | ⚠️ 部分 | ⚠️ 异常层级 |
| 优雅降级 | ❌ | ✅ 兜底生成器 | ⚠️ timeout | ⚠️ 超时 | ❌ |
| 空响应保护 | ❌ | ✅ guard_exec | ⚠️ 部分 | ❌ | ❌ |
| 重试智能 | ❌ | ✅ 分类决策 | ✅ 指数退避 | ⚠️ 简单 | ⚠️ 简单 |
| Pi Agent兼容 | ✅ 原生 | ✅ 原生 | ❌ | ❌ | ❌ 太重 |
| 提示词开销 | 0 | +250 tokens | N/A | N/A | N/A |
| 代码量 | 0 | ~200行shell | 内建 | 插件 | 库 |

## 6. Data Flow with Layer 6 Recovery

```
Agent Task: Step1→Step2→Step3→Step4
                  │      │      │
                  ▼      ▼      ▼
              ✅CP1   ✅CP2   ❌Deadloop Detected
                                  │
                   ┌──────────────┘
                   ▼
            [Checkpoint Recover]
                   │
            ┌──────┼──────┐
            ▼      ▼      ▼
        Rollback  Undo   Verify CP2
        to CP2    Step3  state
            │      │      │
            └──────┴──────┘
                   │
                   ▼
        [Build Recovery Context]
        {DO_NOT_RETRY: [old_approach],
         recommended_next: "python_makedirs",
         context_for_llm: "Step3 failed with E_PERM..."}
                   │
                   ▼
        LLM receives context → selects alternative
                   │
                   ▼
        python3 -c 'os.makedirs(...)' → ✅ Success
                   │
                   ▼
        Save CP3 (approach=python_makedirs) → Continue to Step4
```

## 7. 实施 ROI 分析

```
安全性提升
    ▲
    │     Layer 6 ████████████████████  (断点恢复, 避免从头重来)
    │           Layer 4 ████████████  (关键安全网)
    │           Layer 5 ████████████  (适配必须)
    │     Layer 3 ██████████████████  (决策智能)
    │  Layer 2 ████████████████████████████████  ← 最高 ROI
    │  Layer 1 ████████████████  (理论基础)
    └──────────────────────────────────────► 实施复杂度

Layer 2 (安全工具抽象) 是最优投资:
  - 最低复杂度 (3 个函数)
  - 覆盖 85%+ 场景

Layer 6 (断点恢复) 是韧性关键:
  - 解决"停止=丢失进度"的根本矛盾
  - 避免已完成任务从头重做的浪费
  - 基于 WAL/Saga/CircuitBreaker 等公开最佳实践
```
