---
dev-loop: memory
format: v1
epic: mcp-orchestration
total-merged: 0
last-merge: none
---

# mcp-orchestration

> MCP 服务编排内核：以「可见性(visibility)」为编排边界，服务暴露分级 = 服务端仅两档（public/private）。

- [挂载] docs/design/window-kernel-split.md（两平面权威定义，§2：Shared Plane / Private Slot、单槽互斥、未达标绑定）

> 核心代码落点（原多挂载行，dev-loop §3 挂载恒 1 条故移正文）：`lib/mcp/server_endpoints.dart`（可见性 API：`ServerPrivacyTier{private,public}` + `ServerEndpoint{id,title,privacyTier}` + `ServerEndpointStore`）；`lib/gateway/mcp_gateway_handler.dart`（跨服务防火墙 `toolsList` + `switch_server`/`use_server` 绑定 ops）

## 决策（MO1~MO7 已确认，2026-10-16）

- **MO1 可见性双档（服务端）**：后端 MCP 服务只有两档——`public`（跨服务共享面 / Shared Plane）与 `private`（私有备选池 / Private Slot）。**服务端没有 host 这一档**；`ServerPrivacyTier{private,public}` 已是唯一权威枚举，规范两平面图对服务端完整自洽，无需第三档。
- **MO2 私有不进共享面**：private 服务默认不出现在共享面，`GatewayHandler.toolsList`（防火墙）只回 `host 内置 + 全部 public +（绑定的单一 active private）`——架构已实现，即规范两平面图。
- **MO3 单槽互斥 + 未达标绑定**：多个 private 经 `use_server` 申请、单一 active 互斥绑定；未达标（未绑定）的 private 不进主客户端视图。主客户端 `activeServers` = 固定 public 集合 + 至多一个 private。
- **MO4 host 非服务、非可见性档**：`HostNativeTools`（switch_server / 权限 / 工作区 IO 等）是**客户端自家工具**，不是后端 MCP、不计入任何可见性档；它经网关投影面常驻呈现，给 PC（及本地模型）当控制客户端用。PC 取用 host 走同一套投影机制，无特权后端通道。
- **MO5 PC 无特权、仅投影**：PC 是普通代理终端，是客户端视图的「端口投影」；它看到的 = 主客户端视图的投影（host 内置 + public + active private）。PC 不越权、不直连后端、无独立私有槽。
- **MO6 PC 私有绑定严格依赖 D-D 投影隔离（分两阶段）**：裁决「D-D 投影隔离须严格先于 PC 独立私有绑定」；在此之前 PC 仅是客户端当前会话工具面的**只读镜像**。（依据：现状 `GatewayController.shared` 为全局单例，若允许 PC 调 `use_server` 会直接改写宿主当前 `activePrivateServerId`，造成宿主与 PC 跨会话状态踩踏。）分阶段：
  - 阶段一（当前）：PC 接网关代理仅透传客户端当前激活投影（Host + Public + 宿主当前选中的 Active Private）；PC 只能调用，**无权**发起 `use_server` 动态换绑。
  - 阶段二（D-D 落地后）：`GatewayController` 改造为按 connection/workspace 分配独立投影上下文后，解锁 PC 自主发送 `use_server` 独占属于 PC 会话的私有槽位。
- **MO7 $ref 跨服务防火墙守卫精确范围（仅网关入站/跨源边界）**：裁决「仅限网关入站与跨源代理边界拦截，坚决不侵入本地同进程调用」。（依据：① 本地同进程结构性安全——D-C 单私有槽已保证会话上下文至多一个私有服务、其余皆 Public，同进程 `AgentLoop`/`ToolRouter` 无"两私有互相偷调"物理通路；② 真正风险在外源——跨服务泄漏唯一风险来自网络入站的外部 RPC（外部 MCP/PC 越权持私有句柄调其他服务）；③ 防过度设计——`$ref` 校验死锁在 `lib/gateway/mcp_gateway_handler.dart` 入站分发层，保住纯 Dart 协调内核 `coordinator/` 的纯粹与零开销，避免本地单测/本地链路引入繁重上下文权限检查。）规则 1「跨源请求须持 Session Context/$ref 否则拒」= 仅约束经网关入站的跨源请求；LAN 直连 goodhub 看不见、靠「private 不进共享面」兜底。
  - **[已实施 2026-10-16]** 守卫落地于 `GatewayHandler.toolsCall`：递归扫描入参（整值匹配口径，与 `ref_hydrator` 一致）收集「引用 serverId ≠ 目标 serverId」的跨源 `$ref` 句柄，须持 `sessionId`（网关 `Mcp-Session-Id`）否则拒绝；`gateway_server` 透传 `sessionId`；守卫只做会话归属校验，不做注水（网关是代理按字面转发句柄，注水属宿主运行时路径）。4 单测锁定（跨源无会话拒绝 / 跨源带会话放行 / 同源不触发 / 嵌套检出），`test/gateway` 全 41 例绿、analyze 0 issue。
- **MO8 本地插件同属私有 tier + 默认钉选 Hybrid（2026-10-16 用户拍板）**：
  - **私有是权限维度，挂载方式（自动/手动）是接入维度，二者正交**——本地自动挂载插件同为 private，一并进 `privateServerIds`、不默认激活、受单槽门控（不选则隐藏、选中才可用）。私有≠免隔离。
  - **持久默认放设置页（Hybrid）**：统一默认键 `default.private.server`（`lib/mcp/default_private_server.dart`）覆盖手动端点 + 本地插件；聊天菜单只做本次会话即时切换/覆盖，不再持有持久默认开关（原 `isDefault` 小开关对本地插件是 no-op，已废弃写入入口；字段保留作 JSON 兼容 + `resolveBinding` 遗留兜底）。
  - 运行时自洽：聊天页 init 即把统一默认绑定进 `ConversationSession.activePrivateServerId`，装配 `bound` 直达；顶层 `resolveBinding` 纯函数签名不动。

## 断点

- **[断点] 阶段一（只读镜像）已落地（2026-10-16）**：`GatewayHandler` 新增 `privateServerIds` + `activePrivateServerId`，`toolsList()` 仅投影 public + 激活 private（其余私有隐藏）；`toolsCall()` 加防火墙拒绝非激活私有调用（禁 `use_server` 换绑）；`GatewayController` 按 `ServerEndpoint.tier` 注入私有集 + 新增 `syncActivePrivate(String?)` 推送宿主激活私有；`chat_page` 三处私有绑定变更点（恢复会话 / 端点预热 / 菜单即时绑定）推送网关。单测 4 例锁定投影+防火墙（`test/gateway/mcp_gateway_handler_test.dart`），全仓 630 例全绿、analyze 0 issue。
- **[断点] 下一步**：① 阶段二（D-D 落地后）——推动 window-kernel-split §2.4「投影平面按 connection/workspace 隔离」（改 `GatewayController.shared` 全局单例为 per-connection 投影上下文），解锁 PC 自主 `use_server` 独占 PC 会话私有槽。**已收口项**：MO7（`$ref` 入站守卫，2026-10-16 已实施）；规范收口（window-kernel-split.md §8.4 两平面权威 + 消「host 为服务端第三档」歧义，2026-10-16 已回填）。

## 断点
- [断点] 下一步：待 AI 回填：该 epic 断点由 ctx-fix 结构重建（专项清理），须下一轮读 devlog 尾部补真实下一步
