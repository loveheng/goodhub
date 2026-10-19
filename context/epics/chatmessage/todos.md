---
memo: todos
format: v2
epic: chatmessage
---
# chatmessage · 域内待办
- [ ] [2026-10-19] (优化) (重:重) 存量债归本窗口处理（触发=本 epic 下次 ::bind / 恢复窗口时）：devlog 18 条待归并提炼进 memory.md 并清空追加区；待办行格式违规 3 处（缺类型/层/重标签，补标签保语义不丢） (src: ai, 存量债专项 QC3-a)

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
- [ ] (功能) §2.4 投影平面按工作区隔离（从 `GatewayController.shared` 单例拆出）——P3-2 发送边界合成桩已先行落地，投影态会话级持有多窗隔离仍待立项；**UI/装配侧方案 = `docs/design/window-kernel-split.md`（draft，未立项；第一步 ServiceDirectory 契约化）**
- [ ] (风险) [long] `MemoryStore` 兼作审计日志（`opsLog`）——2026-10-16 窗口解耦评估裁决：**本轮不动**（动审计会横向牵涉 `gateway_security` / `permission_gateway`，破收敛）。收敛条件：当审计与记忆需要不同保留策略（留存期/可删性/合规导出）时，必须从 `MemoryStore` 拆出独立 OpsLog 内核
- [ ] (功能) §9.4 多 Provider 缓存能力标记（Gemini 无状态，不建 `CachedContent` 生命周期）
- [ ] (功能) §10.1 移动端前后台生命周期探针（G8）
