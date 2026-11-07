---
memo: todos
format: v2
epic: chatmessage
---
# chatmessage · 域内待办

## chatmessage 实现拆解（分阶段交付 · WBS + DoD）

> 设计 SSOT：`docs/design/host-gateway-accessibility-memory.md`
> **Scope（方案 B 轻量约束）**：本 epic 执行范围 = §3 记忆 In-band 捎带提取（含 G1~G8 中流式 / 存储相关项）及其依赖（§1 数据模型、`§2 tool_router` 三段式）。纯 `lib/gateway/*` 服务端行为、命名空间虚拟化等对上游逻辑作**依赖跟踪**，不归本 epic。

## Phase 1 · 数据模型与缓存基建
> 交付目标：访问性枚举落地 + 工具序 / 缓存确定性，为记忆提取与网关虚拟化铺路（无记忆行为改动）。


- **DoD(P1)**：`flutter analyze` 0 issue；`ServerPrivacyTier.fromJson` 缺字段 / 非法值单测均兜底 `private`；同激活集两次 `toolsProvider()` 列表顺序与字节一致；Anthropic 首轮 usage 含 `cache_creation_input_tokens>0`、次轮含 `cache_read_input_tokens>0`；无缓存能力的 provider 行为零变化。

## Phase 2 · 工作区存储与流式分流
> 交付目标：会话级事实落盘 + In-band 提取 FSM 接线 + 防注入，是记忆能力的核心战场。


- **DoD(P2)**：控制台打印解析结果、UI 气泡无 JSON 残留；`cancelCommit` 后下一轮无脏解析；`scope` 非法值单测丢弃；`<workspace_update_v1>` 外版本 / 用户输入标签均不触发提取；会话级事实落盘后可经 UI 胶囊撤销（`remove`）。

## Phase 3 · 网关鲁棒性治理
> 交付目标：多工具并发、私有域切换脱敏、超大输出截断——稳定性保底（依赖 Phase 1 工具序 / Phase 2 提取稳定）。


- **DoD(P3)**：单轮多 `tool_calls` 总耗时显著下降且零异常中断流；切换私有域发往上游的历史严格成对、不触发 `400 Bad Request`；超大 result 回填永不超越 `2000 token` 上界。

## 依赖跟踪（不归本 epic，仅监测）
