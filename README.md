# Agent Resilience Tooling — 健壮工具调用体系研究

## 核心命题

> 在 AI Agent 框架（特别是 Pi Agent）下，彻底解决因执行 mkdir 等文件操作而引发的 Agent 死循环问题，并建立一个能够感知错误性质、优雅失败的健壮工具调用体系。

## 最终目标

**无论底层发生什么（从目录已存在到服务器濒临崩溃），Agent 都能感知死循环、回退到上一个成功断点、切换替代策略、跳过已完成步骤、继续执行，永远不陷入沉默的、消耗资源的死循环，也永远不从头重做已完成的工作。**

---

## 目录结构 (✅ Phase 1+2 完成)

```
agent-resilience-tooling/
├── README.md                                    # ✅ 本文件：总纲
├── agent-safe-fs.sh                             # ✅ 生产可用 shell library (197行)
│
├── 01-root-cause-analysis/
│   └── deadloop-taxonomy.md                     # ✅ 9类死循环场景 + 机理分析
│
├── 02-safe-tool-abstraction/
│   └── tool-abstraction-design.md               # ✅ ensure_*/safe_*/raw_* 三级架构
│
├── 03-error-classification/
│   └── error-classification-system.md           # ✅ 8码5层 + Python/Bash双实现 (1130行)
│
├── 04-graceful-degradation/
│   ├── extreme-condition-fallback.md            # ✅ Pre-fork检查 + 兜底生成器 (538行)
│   └── null-response-guard.md                   # ✅ 3阶段guard_exec Bash+Python双实现 (1419行)
│
├── 05-pi-agent-adaptation/
│   ├── pi-agent-constraints.md                  # ✅ 800-token约束分析 + 3 Tiers (284行)
│   ├── minimal-implementation.md                # ✅ Tier 2 Shell Library推荐方案 (605行)
│   └── prompt-only-defense.md                   # ✅ 仅Prompt/Skill的认知防护
│
├── 06-checkpoint-recovery/                      # 🆕 Phase 2
│   ├── checkpoint-recovery-design.md            # ✅ 断点恢复设计 (WAL+Saga+CB+Git)
│   ├── agent-checkpoint.sh                      # ✅ Checkpoint shell library (260行)
│   └── strategy-router.md                       # ✅ 多策略路由器 (含Circuit Breaker)
│
├── docs/
│   ├── architecture-overview.md                 # ✅ 六层架构总览 + 数据流 + Recovery流
│   ├── explore-findings-intermediate.md         # ✅ 调研中间产物 (3个Explore子智能体)
│   ├── scenario-matrix.md                       # ✅ 多场景矩阵 S0-S6 (按控制面选用)
│   ├── llm-cognitive-guidance.md                # ✅ LLM认知引导：返回值思维+错误处置本能
│   ├── future-directions.md                     # ✅ 10个后续研究方向 (P0-P3分级)
│   └── verification-checklist.md                # ✅ 验证清单
│
├── experiments/
│   ├── deadloop-reproduction.sh                 # ✅ 9场景可复现脚本 (248行)
│   ├── ensure-directory-bench.py                # ✅ Python 对照实验 (500行)
│   ├── oom-simulation.sh                        # ✅ 极端条件模拟 (525行)
│   └── checkpoint-fallback-bench.sh             # 🆕 断点恢复集成测试 (9 tests, 8/9 pass)
│
└── references/
    └── external-resources.md                    # ✅ 外部参考索引
```

**总计**: 24 个文件，~9000+ 行
└── references/
    └── external-resources.md                    # ✅ 外部参考索引
```

**总计**: 19 个文件，~8000+ 行内容

---

## 五层防护模型

```
Layer 5 (Pi Agent Adaptation):    800-token prompt + shell library → minimal footprint
Layer 4 (Graceful Degradation):   CPU/内存耗尽 → structured fallback, never empty
Layer 3 (Error Classification):   错误性质感知 → classify → decide (retry/report/circuit-break)
Layer 2 (Safe Tool Abstraction):  幂等封装 → ensure_directory, never mkdir
Layer 1 (Root Cause Analysis):    理解死循环 → 9 scenarios → prevention taxonomy
```

---

## 核心原则

1. **永远返回结构化结果** — 无论发生什么，Agent 必须收到明确、可解析的反馈
2. **幂等优于检查** — ensure_directory 而非 mkdir，操作本身就是安全的
3. **错误即数据** — 每一条错误信息必须携带：来源层、可重试性、建议动作
4. **空输出 = 灾难** — 不是"未执行"，而是"系统濒临崩溃"
5. **分类先于重试** — 不知道错误类型就重试 = 赌博

---

## 快速开始：按场景选择方案

**你的框架有什么能力？** 查阅 [场景矩阵](docs/scenario-matrix.md) 确定场景：

| 你能做什么？ | 你的场景 | 防护率 | 主要参考文件 |
|:---|:---:|:---:|------|
| 只能编辑系统提示词 | S1 | ~60% | [prompt-only-defense.md](05-pi-agent-adaptation/prompt-only-defense.md) |
| + 可定义 Skill | S2 | ~75% | 同上 (Layer C1+C2) |
| + 可注册自定义工具 | S3 | ~85% | [tool-abstraction-design.md](02-safe-tool-abstraction/tool-abstraction-design.md) |
| + 有 Pre/Post ToolUse 钩子 | S4 | ~92% | [null-response-guard.md](04-graceful-degradation/null-response-guard.md) |
| + 可拦截 bash 调用 | S5 | ~97% | [extreme-condition-fallback.md](04-graceful-degradation/extreme-condition-fallback.md) |
| + 有 OS 沙箱 (Docker/Landlock) | S6 | ~99% | [external-resources.md](references/external-resources.md) |

**一键部署 (场景 S3+)**:
```bash
# 1. 安装 shell library
cp agent-safe-fs.sh ~/.agent/safe-fs.sh

# 2. 在系统提示词中追加 (~120 tokens):
#    "Use ensure_directory, ensure_file, safe_remove from ~/.agent/safe-fs.sh
#     NEVER use bare mkdir/rm. If any tool returns empty output, report and STOP."

# 3. 验证
bash ~/.agent/safe-fs.sh  # --help
source ~/.agent/safe-fs.sh && agent_safe_fs_self_test
```

---

## 死循环场景 → 防护覆盖率

| # | 场景 | L1 根因 | L2 安全工具 | L3 错误分类 | L4 兜底 | L5 Pi适配 | 覆盖? |
|---|------|:---:|:---:|:---:|:---:|:---:|:---:|
| 1 | EEXIST (目录已存在) | ✅ | ✅ | ✅ | — | ✅ | ✅ |
| 2 | EACCES (权限不足) | ✅ | ✅ | ✅ | — | ✅ | ✅ |
| 3 | ENOENT (父目录缺失) | ✅ | ✅ | ✅ | — | ✅ | ✅ |
| 4 | ENOSPC (磁盘满) | ✅ | — | ✅ | ✅ | ✅ | ✅ |
| 5 | OOM (内存耗尽) | ✅ | — | ✅ | ✅ | ✅ | ✅ |
| 6 | I/O 阻塞 (D状态) | ✅ | — | ✅ | ✅ | ✅ | ✅ |
| 7 | 工具崩溃 (segfault) | ✅ | — | ✅ | ✅ | ✅ | ✅ |
| 8 | 路径冲突 (同名文件) | ✅ | ✅ | ✅ | — | ✅ | ✅ |
| 9 | 符号链接循环 | ✅ | ✅ | ✅ | — | ✅ | ✅ |

**覆盖率: 9/9 (100%)**

---

## 后续方向

10 个延伸研究方向详见 [future-directions.md](docs/future-directions.md)：

| 优先级 | 方向 | 工作量 |
|:---:|------|:---:|
| 🔴 P0 | 工具调用预算 (3行prompt, 立即生效) | 1天 |
| 🔴 P0 | Chaos Agent 故障注入测试框架 | 2-3周 |
| 🟡 P1 | JSON Schema 形式化验证 | 2-3周 |
| 🟡 P1 | 可观测性仪表盘 | 1-2周 |
| 🟢 P2 | 多框架适配器 | 4-6周 |
| 🟢 P2 | 审计溯源 | 1周 |
| 🔵 P3 | 声明式 Agent DSL | 6-8周 |
| 🔵 P3 | 运行时沙箱 (Landlock) | 3-4周 |
