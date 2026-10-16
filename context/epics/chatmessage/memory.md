---
dev-loop: memory
format: v1
epic: chatmessage
total-merged: 2
last-merge: 2026-10-16
---

# chatmessage

> 本 epic 绑定设计 SSOT：`docs/design/host-gateway-accessibility-memory.md`（2026-10-15 一轮架构推演，含访问性模型 / Host 网关 / 记忆 In-band 捎带提取三段结论）。

## 设计 SSOT 速览（TL;DR）

- **§1 访问性 / 隐私分层**：外部 MCP 服务仅 `private` / `public` 两档；`host`（宿主内置能力）**不进 `ServerEndpoint`**，由客户端以 `HostNativeTools` 注入。两维解耦 = Provider（host / external）× Tier（private / public）。
- **§2 Host = 聚合反向代理网关**：goodhub 既是对下子服务的客户端，又是对上的标准 MCP 服务端代理；四项治理（命名空间虚拟化 / 工具面虚拟化 / 调用拦截 / 遥测脱敏）收口在网关层（`GatewayController` + `GatewayHandler` 已是实体）。
- **§3 记忆 = In-band 捎带提取**：模型最终自然语言轮尾部用 `<workspace_update>` 标签捎带提取背景事实，省掉二次模型调用；现有 `MemoryStore` / `context_governor` / `agent_loop` 已覆盖约 80% 基础设施，真实缺口集中在 Demuxer 与会话级 store。

## 关键决策（锁定）

- D-A：外部服务仅 `private`/`public` 两档；`host` 不进 `ServerEndpoint`（Provider×Tier 两维解耦）。
- D-B：goodshare 迁移为普通外部 `ServerEndpoint`，`tier: public`；宿主能力另抽 `HostNativeTools`。
- D-C：私有 + 私有严禁由 `activePrivateServerId` 单一槽位构造保证。
- D-D：Host = 「连接平面全局 / 投影平面按工作区隔离」（`GatewayController.shared` 单例与投影态会话级矛盾待实现）。
- D-E：记忆走 In-band 捎带提取，非异步小模型。
- D-F：会话级事实 store 须新建（G3）——现有 `MemoryStore` 仅 app 全局级，无 per-conversation 层。
- D-G：Prompt Caching 以显式断点 + 工具序确定性为第一杠杆，记忆置尾策略维持。
- D-H：切换私有域做历史投影时绝不物理删除 `tool_call`/`tool_result`，保留 matching `id` 替换为合成占位桩（防 OpenAI/Anthropic 400）。详见 §9.1。
- D-I：超大工具输出在 `_governedContent` 入口前置物理硬截断 `kToolResultHardCap = 2000 tokens (≈8KB)`，Head 50 + Tail 20 折叠。详见 §10.4。
- D-J：单轮多 `tool_calls` 改 `Future.wait` 并发编排；任一失败须包装为合法错误 `ToolResult` 全量回填。详见 §10.2。
- D-K：剪枝与负收益消除——仅留断点 A（砍断点 B 消除 re-cache 惩罚）；砍 `is_locked` 行级锁；Gemini 保持无状态；当前阶段不引入 MCP Resources/Prompts。详见 §7.5 / §9.5 / §9.4 / §10.3。

## 真实缺口（待落地，§3.5）

- **G1** 语义 key 映射：`MemoryStore` 无 keyed upsert/remove，需按 key 查重或新建轻量 KV 子 store。
- **G2** Demuxer / FSM 未写：新建 `WorkspaceStreamFilter`，挂 `agent_loop.dart:265`（分流）+ `calls.isEmpty` 分支（终局剥离）。
- **G3** 会话级（workspace）store 缺失：最大缺口，落点 = 未落地的 `workspace_states` 表。
- **G4** scope 校验 + 「public」映射：扩展 `_scopeRegExp` 含 `session`/`ws:`，JSON 的 `"public"` 映射为「本会话域」。
- **G5** 工具 Schema 键序归一（P0 缓存杀手）：`CloudToolSchema` 缺规范 `toJson` 且 `parametersSchema` 键序不可控，须 Dart 层递归字典序排序。详见 §8.2 改动点 3。
- **G6** FSM 生命周期与取消回滚（P0 数据安全）：用户 Stop / 断网时 `pendingBuffer`/`jsonBuffer` 残留致脏解析，须 `_aborted` 挂 `fsm.discard()`。详见 §9.2。
- **G7** 输入端特异性标签转义（P1 防注入）：用户输入 `<workspace_update` 转义为 `&lt;workspace_update`；输出升级 `<workspace_update_v1>`。详见 §9.3。
- **G8** 移动端前后台生命周期探针（P1 稳定性）：缺 `WidgetsBindingObserver`；`resumed` 须 ping 探针 + 失效静默重连。详见 §10.1。

## 收尾账本 (2026-10-15)

- 全量测试 **583/583 全绿**（含此前编译失败的 `hybrid_cloud_engine_test` 21 例已修复入网）；`flutter analyze` 基线 = 1 条已知存量 info（`gateway_loop_debug_page.dart:670 value deprecated`，`release-r2.sh` 已降为告警不阻断）。
- 阻断修复（devlog → 此处收口）：
  - `lib/coordinator/hybrid_cloud_engine.dart`：`_cloudSend` 内 `fireTimeout` 闭包在 `late final srcSub` 声明前引用 → 编译回归（连带 `debug_hall_test`/`gateway_controller_test`/`hybrid_cloud_engine_test` 编译失败）；`srcSub` 声明前置解决。
  - `lib/mcp/connection_manager.dart`：`_resyncSubscriptions` 重连重放原走 `listResources()` 重列，server 重启后缺 `resources` 数组抛错且清单未必含手动订阅 uri → 重放中断（`subscription_test` 实际 1/期望 2）；改为先按本地 `client.subscribedUris` 重报（force）+ best-effort 重列补新增。
  - `lib/coordinator/hybrid_cloud_engine.dart`：`_cloudSend` gapTimer 三元 `isFirst ? firstTokenTimeout : interEventGapTimeout` 首事件后误重装首 token 预算（interEventGapTimeout 判据永不触发）；改为事件到达后一律按 `interEventGapTimeout` 重装并删废变量 `isFirst`；`hybrid_cloud_engine_test` `CloudDone` 缺必填 `finishReason` 编译失败补 `CloudFinishReason.stop`。

## 归并 (2026-10-16 · 会话绑定 UI 与流控判据)

- **会话绑定 UI 定稿**：状态带上下文胶囊改**常驻可点**（已绑定→`[服务名]`；有端点→`[公共]`；本地插件→`本地×N`），输入框「+」**固定常显不隐藏**（移除 `_composerVisible` 及输入监听）——解决"输入一半想切服务"的痛点，输入内容不丢。
- **本地插件语义（易错点）**：Binder 自动发现项**不进 `mcp_servers.json`**，经 `localPluginDiscovery.scan()` 填 `_localPlugins`；**按私有呈现**（锁形 + `l1Info` 色，非公有灰），**始终挂载**、无需绑定选择——绑定语义仅适用于手填 HTTP 端点。
- **`_endpoints` 缓存过时缺陷**：`ChatPage` 原只在 `initState` 读一次目录，"先开聊天→设置加服务→返回"后菜单恒空。修法 = `_openComposerMenu` 开菜单前先 `await _loadEndpoints()` 重读；且加载后即完成"新会话默认锁定"（`isDefault` → 首个 private）。
- **流控判据放宽（D-K 连带）**：`DegradationController` 移除 `maxThinkingGap` 上限——长思考/慢推理不掐断，交由人类按状态带新增的 `mm:ss` 运行计时自行决定中止；活体连接（含 SSE 心跳字节）永不误杀，仅持续无字节的真死连接被 `interEventGapTimeout`=120s 下限兜底。
- **验证基线**：`flutter analyze` No issues；全量 564/0（该轮排除 hybrid_cloud_engine_test），后随编译修复入网升至 583/583（见上节收尾账本）。

## 断点

- [断点] 下一步：收尾全量测试已完成：583/583 全绿（hybrid_cloud_engine_test 编译失败已修复并入网 21 例；连带修复 hybrid_cloud_engine 流内间隙计时器三元 bug）；等待新子任务或 ::done
- [note] 2026-10-16：本 epic 的 UI/装配层解耦已**分拆**至新 epic `window-kernel-split`（挂 `docs/design/window-kernel-split.md`），本 epic 仅保留 §3 记忆 In-band 提取战场；两边连线 = 依赖跟踪 §2.4 投影平面隔离
