---
dev-loop: devlog
format: v1
epic: mcp-orchestration
total-merged: 0
last-merge: none
---
# mcp-orchestration · 开发日志

> 决策底：context/epics/mcp-orchestration/memory.md（MO1~MO7）。

## 2026-10-16 · 阶段一（MO6 只读镜像）落地

- **范围**：网关 PC 投影改为只透传宿主当前激活工具面（public + 激活 private），禁止 PC 发起 `use_server` 换绑。
- **改动**：
  - `lib/gateway/mcp_gateway_handler.dart`：`GatewayHandler` 增 `privateServerIds` / `activePrivateServerId`；`toolsList()` 仅投影 public + 激活 private；`toolsCall()` 加防火墙——非激活私有服务调用直接拒绝（isError，提示只读镜像 + 禁换绑）。
  - `lib/gateway/gateway_controller.dart`：`_assemble()` 按 `ServerEndpoint.tier` 注入 `privateServerIds` 并应用宿主激活私有；新增 `syncActivePrivate(String?)`（写 handler + `notifyToolsListChanged` 热同步）。
  - `lib/ui/chat_page.dart`：恢复会话 / 端点预热(`_loadEndpoints`) / 菜单即时绑定(`_bindSessionServer`) 三处私有绑定变更点调用 `GatewayController.shared.syncActivePrivate(...)`。
- **测试**：`test/gateway/mcp_gateway_handler_test.dart` 增 4 例（投影过滤 + 防火墙拦截 + 兼容全量 + 激活放行）；全仓 630 例全绿、`flutter analyze` 0 issue。
- **备注**：原有 memory.md 称「toolsList 已实现 host+public+active private」与代码不符——网关此前无 `ToolRouter` 参与、`faces` 暴露全部私有；本次为真实补齐，非新建设计。

## 2026-10-16 · 规范回填（window-kernel-split.md §8.4）
- **范围**：把 MO1~MO7 网关侧可见性与 PC 投影模型回填为权威口径，消「host 为服务端第三档」歧义。
- **改动**：`docs/design/window-kernel-split.md` 新增 §8.4，并 §8 对齐列表补一条指向指针。要点：
  - 两档可见性（public/private，唯一权威 `ServerPrivacyTier`），服务端无 host 档；内核 #9「Gateway 对外代理（host）」中的 host 是宿主 App 别称，非服务端可见性类型。
  - host 非服务、非可见性档（HostNativeTools 客户端自家工具，经投影常驻呈现）。
  - 防火墙 `toolsList` = host+public+active private；MO6 阶段一 PC 只读镜像 + 阶段二 D-D 后解锁；MO7 `$ref` 守卫仅网关入站/跨源边界，不侵入本地同进程。
- **备注**：纯文档回填，无代码改动；与 memory.md 决策同源，本文为内容 SSOT。

## 2026-10-16 · MO7 $ref 入站守卫实施
- **范围**：把跨源 `$ref` 防火墙守卫精确钉在网关入站分发层（MO7 裁决落地）。
- **改动**：
  - `lib/gateway/mcp_gateway_handler.dart`：`toolsCall` 增 `sessionId` 入参；私有防火墙之后新增 MO7 守卫——递归扫描入参收集「引用 serverId ≠ 目标 serverId」的跨源 `$ref` 句柄（整值匹配，与 `ref_hydrator` 一致），无有效会话即拒绝；新增 `_crossSourceRefHandles` 静态扫描助手（引入 `ref_store.parseRefHandle`）；守卫只做会话归属校验、不做注水（网关是代理按字面转发句柄）。
  - `lib/gateway/gateway_server.dart`：`_toolsCall` 透传 `sessionId` 给 `handler.toolsCall`。
  - `test/gateway/mcp_gateway_handler_test.dart`：新增 `_echoFace` 助手 + MO7 测试组 4 例（跨源无会话拒绝 / 跨源带会话放行 / 同源不触发 / 嵌套检出）。
- **验证**：`flutter analyze` 0 issue；`test/gateway` 全 41 例绿（含既有 MO6 / 环路 / 背压 / server 会话强制用例无回归）。
- **设计边界**：守卫严格位于网关入站层，不侵入 `coordinator/`；LAN 直连 goodhub 无网关投影面，靠「private 不进共享面」兜底——与 MO7 裁决一致。

## 2026-10-16 · 阶段二 D-D 投影隔离 · 评估设计（待裁决，未实施）

- **背景核查（关键）**：
  - `HostNativeTools`（`use_server`/`switch_server`）是**宿主客户端注入**能力，**不进网关 face**（`lib/mcp/server_endpoints.dart:23-24`）——故当前网关**未把 `use_server` 暴露给 PC**；MO6 阶段一的"跨会话踩踏"向量（PC 调宿主 `use_server`）当前**休眠**；阶段一真实约束仅为"PC 不能自选私有域"。
  - 隔离天然单位已存在 = `Mcp-Session-Id`（`McpGatewayServer._sessions: Set<String>`，每 HTTP 连接一个）；尚无 workspace 概念。
- **核心问题**：`GatewayController.shared` 持有单一 `GatewayHandler`（单一 `activePrivateServerId`），被所有 PC 会话 + 宿主共享 → PC 无法持有独立私有投影；且任一连接改写 `activePrivateServerId` 会踩踏宿主与其他连接。
- **拟议架构（shared vs per-connection 拆分）**：
  - **共享（归 controller）**：`faces`（已挂载 MCP face，重活）、`privateServerIds`、`security`/`opsLog`、`_listChanged`。`_assemble` 对 `faces`/`privateServerIds` **原地** clear+重填，会话 handler 持同一引用即自动同步。
  - **每连接（per `Mcp-Session-Id`）**：各自的 `GatewayHandler` 实例（持有共享 `faces`/`privateServerIds` 引用 + 自身 `activePrivateServerId` + 自身 `loopGuard`/`_backpressure`）。`initialize` 时按宿主当前激活私有初始化（阶段一默认镜像）；请求按 sessionId 路由到对应 handler。
  - **宿主投影**：controller 持 `hostActivePrivateServerId`（宿主自身选择，= 新 PC 会话默认）。
- **分步落地**：
  - **步 1（低风险前置，不改变行为）**：`McpGatewayServer` 按会话创建独立 `GatewayHandler`（共享 faces/privateServerIds 引用）；`syncActivePrivate` 仍向所有现存会话推送（保持阶段一镜像语义）；`stop()` 一并清 `_handlers`。无对外行为变化，先把"单一共享 handler"换成"每连接 handler"。
  - **步 2（阶段二解锁，gated by `pcIndependentProjection` 默认 false）**：`syncActivePrivate` 仅更新宿主默认（现存 PC 会话不再被迫镜像）；**新增网关级 `use_server` 私有域选择原语**（投影到 PC 为 `gateway__use_server` 或复用 `host__use_server` 在网关层拦截）——只改写**该会话** `activePrivateServerId`，**绝不**转给宿主 `discovery_executor` 槽位机；防火墙改用会话自身 `activePrivateServerId`。`tools/list` 按 sessionId 取该会话投影；`list_changed` 全局广播即可（各 PC 重拉自身投影）。
- **待裁决/风险**：
  1. 阶段二是否仍称 `use_server` 暴露给 PC，还是新增独立 `gateway__select_private` 原语以避免与宿主 `use_server` 语义混淆？（倾向新增独立原语，语义零歧义。）
  2. `_backpressure` 现为 handler 实例级（单 server 并发 4）——改为每会话后=每客户端 4 并发（更公平，符合"per-client 限流"），是否接受？（倾向接受。）
  3. `loopGuard` 改为每会话——环路由每连接独立熔断，是否接受？（倾向接受；跨网关级环路本就发生在单连接转发链内。）
  4. 是否需要会话空闲超时清理 `_handlers`（当前仅 `stop()` 全清）？暂定为 `stop()` 全清即可，留待观测。
- **备注**：纯评估设计，未写代码；待裁决点确认后按 dev-guide 流程落地步 1 → 步 2。

## 2026-10-16 · 阶段二 D-D 投影隔离 · 落地（步 1+步 2 合并）

- **裁决（已拍板）**：① 新增独立原语 `gateway__select_private`（不复用 use_server，避免与宿主槽位语义混淆）；② 背压 per-session（每客户端并发队列，防多客户端饿死全局配额）；③ loopGuard per-session（单连接环不熔断他连接）；④ 会话清理=被动（stop 全清）+ 显式注销（SSE 关闭即从 `_handlers` 移除，无主动心跳巡检）。
- **架构（shared vs per-connection 拆分）**：`GatewayController` 持有共享 `faces` / `privateServerIds`（原地刷新）+ 模板 `_templateHandler`；`McpGatewayServer` 按 `Mcp-Session-Id` 经 `GatewayHandler.forSession()` 派生**每连接独立** handler（共享 faces/privateServerIds 引用，独立 `activePrivateServerId` / `_loopGuard` / `_backpressure` / `onListChanged`）。
- **改动**：
  - `mcp_gateway_handler.dart`：新增常量 `kGatewaySelectPrivate='gateway__select_private'`、`forSession()`、`_handleSelectPrivate()`；`toolsList()` 追加该系统工具入口；`toolsCall()` 起手拦截 `gateway__select_private`（仅改写本连接 `activePrivateServerId`，**绝不**转交宿主槽位机/任何 face）；`activePrivateServerId` 语义改为「本连接独立」。
  - `gateway_server.dart`：`template` 模板 + `_handlers[Mcp-Session-Id]` 映射；`initialize` 派生、`tools/list`、`tools/call` 走该连接 handler；SSE 关闭/ `stop()` 显式注销清理。
  - `gateway_controller.dart`：共享 `faces` / `privateServerIds` 上提为 controller 字段（原地刷新）；`syncActivePrivate` 仅更新宿主默认（PC 不再被强制镜像，零污染）；`notifyToolsListChanged` 改为 controller 级（广播全部连接）。
- **测试**：新增 `test/gateway/gateway_per_session_projection_test.dart`——两 `Mcp-Session-Id` 连接各自 `gateway__select_private('srv_a'/'srv_b')`，断言双方 `tools/list` 投影互异、防火墙按各自投影拦截越界私有调用、宿主模板 `activePrivateServerId` 保持 null（零污染）。更新 `gateway_server_test.dart` 的 tools/list 断言以容纳新增系统工具。`test/gateway/` 全量 42 例通过；`dart analyze` 0 error（仅既有 `mcp_gateway_handler_test.dart` 的 await info 提示，与本次无关）。
- **行为变化**：PC 连接现可经 `gateway__select_private` 自选独立私有域，不再镜像宿主；宿主私有变更不再强制推送现存 PC 会话（仅作为新会话默认）。LAN 直连兜底仍由「私有不进共享面」保证。

## 2026-10-16 · 本地插件私有化（B 方案：私有挂载≠免隔离）

- **问题**：聊天界面（宿主/手机）自动挂载的本地插件被 UI 标为「私有」，但路由层（`mcp_runtime` 装配）按「公共常驻」处理——既不进 `privateServerIds`、又默认全激活，导致本地插件永远可用、且不可选、无隔离，与"私有"措辞矛盾，用户感知"没隔离"。
- **裁决（用户拍板 B）**：私有是**权限维度**（单槽互斥），挂载方式（自动/手动）是**接入维度**，二者正交——本地插件同为私有 tier，必须受同一单槽隔离；**不选则隐藏、须选中才可用**。
- **改动**：
  - `mcp_runtime.dart`：`ToolRouter` 构造时把本地插件 `serverId` 一并并入 `privateServerIds`（原仅收 `endpoints` 中 `tier==private`）；因入私有集，自动激活的 `activatedServers` 不再包含它们 → 受单槽门控。本地插件**不进** `resolveBinding` 默认回退（须用户显式选定）。
  - `session_context_sheet.dart`：本地插件块由「私有·始终挂载/无需绑定」改为可选中（`onBind(lp.serverId)` + 勾选态），文案改「私有·须选定后占用单槽；未选中则对本会话隐藏」；状态文案「未锁定手动私有服务」→「未锁定私有服务」。
  - `chat_page.dart`：`_endpointName` 增加本地插件名解析（锁定标签显示插件标题）。
  - `settings_page.dart`：本地插件卡文案「已发现即可用」→「已发现即接入；是否可调用须由上下文菜单锁定私有槽位决定（私有≠免隔离）」。
- **测试**：新增 `test/coordinator/tool_router_test.dart`——钉住核心机制：私有 tier（含本地插件 id）未激活时不进 `focusedSchemas` 且 `execute` 被单槽门控拦截；仅激活的单一私有可见、其余私有被互斥隐藏。`mcp_runtime` 把本地插件 id 并入 `privateServerIds` 即依赖此机制。
- **影响面**：仅宿主（手机）路由隔离生效；网关/PC 路径不受影响（网关本就不挂载本地插件，本地插件不进 `GatewayController.privateServerIds`）。`discovery_executor.use_server` 因 `privateServerIds` 现含本地插件 id，亦可绑定本地插件占用单槽。
- **验证**：`flutter analyze` 全量 0 issue；`flutter test` 全量 637 例绿（新增 2 例）。
## 2026-10-16 · 默认私有服务统一钉选（Hybrid：设置页管默认，聊天菜单管本会话覆盖）

- **裁决（用户拍板 Hybrid）**：「设为全局默认」原是藏在聊天上下文菜单里的小开关（写 `isDefault` 进 mcp_servers.json），且对本地插件是 no-op（本地插件不在 endpoints store，钉选写不进去）——持久默认应放**设置页**（可发现、持久、覆盖手动端点+本地插件）；聊天菜单保留**本次会话即时切换/覆盖**。
- **改动**：
  - 新增 `lib/mcp/default_private_server.dart`：统一持久键 `default.private.server`（SharedPreferences）+ `readDefaultPrivateServerId`/`writeDefaultPrivateServerId`。与遗留 `ServerEndpoint.isDefault` 的关系：isDefault 是旧「手动端点内单选」位，本键为统一权威默认。
  - `chat_page.dart`：新增 `_defaultPrivateId` 状态；`_loadEndpoints` 读取统一默认（先刷缓存再解析绑定，修掉旧实现 setState 前读缓存的时序坑）；`_resolveBinding` 回退链改为「显式绑定 → 统一默认（须当前仍存在：启用 private 端点或已发现本地插件）→ 首个手动 private → null」；删除 `_defaultId()`（读 isDefault）与 `_setGlobalDefault()`（写 isDefault）；`_openComposerMenu` 传 `defaultId: _defaultPrivateId`、移除 `onSetDefault`。
  - `session_context_sheet.dart`：移除「设为全局默认」SwitchListTile 与 `onSetDefault` 参数；顶部状态区新增只读提示「默认私有服务：X（在设置可改）」；会话锁定值 ≠ 默认时提示「已为本会话覆盖默认：X」。
  - `settings_page.dart`：新增「默认私有服务」面板（本地插件面板之后）——单选列启用 private 手动端点 + 已发现本地插件 + 「无（纯公共）」，经 `RadioGroup` 写统一键；独立初始化失败按空（DEGRADE 不拖垮页面）。
- **运行时自洽**：`mcp_runtime.resolveBinding`（顶层纯函数，测试钉住 isDefault 语义）签名不动；聊天页在 init 即把统一默认绑定进 `ConversationSession.activePrivateServerId`，装配时 `bound` 非空直接生效——统一默认（含本地插件）经会话态进运行时，isDefault 分支仅作遗留兜底。
- **测试**：`flutter analyze`（4 改动文件）0 issue；`test/coordinator/mcp_runtime_test.dart` + `test/ui/chat_page_smoke_test.dart` + `test/mcp/server_endpoints_test.dart` 33 例绿；`test/ui/settings_page_test.dart` + `test/ui/local_plugins_panel_test.dart` 11 例绿（测试环境 SharedPreferences 不可用 → default-private 按无默认 DEGRADE，与 gateway-token/about-panel 同模式非致命）。
- **行为变化**：本地插件现可被钉选为持久默认（原 no-op 修复）；聊天菜单不再能改持久默认（只能本会话覆盖）；旧 `isDefault` 字段保留（JSON 兼容 + resolveBinding 遗留兜底），不再有写入入口。
