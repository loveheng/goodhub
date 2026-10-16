# mcp-orchestration 待办（MO）

> 决策底：MO1~MO7 全确认（context/epics/mcp-orchestration/memory.md）；契约：docs/design/window-kernel-split.md。

## 阶段一（当前，PC 只读镜像）✅ 已落地（2026-10-16）
- [x] MO6-阶段一：PC 网关代理只读透传宿主当前激活投影（public + 激活 private），`toolsList` 过滤 + `toolsCall` 防火墙拒绝非激活私有；`GatewayController.syncActivePrivate` + chat_page 三处变更点推送；4 单测锁定，全仓 630 例绿。

## 阶段二（D-D 落地后，解锁 PC 自主私有绑定）
- [ ] MO6-阶段二：落地 window-kernel-split §2.4「投影平面按 connection/workspace 隔离」——将 `GatewayController.shared` 全局单例改为 per-connection 投影上下文；之后解锁 PC 自主 `use_server` 独占 PC 会话私有槽。

## 跨服务防火墙（$ref 守卫边界）✅ 已落地（2026-10-16）
- [x] MO7：把 `$ref` 守卫精确钉在 `lib/gateway/mcp_gateway_handler.dart` 入站分发层（仅约束经网关入站的跨源请求）；明确不侵入本地同进程 `coordinator/` 调用链；LAN 直连兜底靠「private 不进共享面」。守卫实现：递归扫描跨源 `$ref` 句柄须持 `sessionId`（Mcp-Session-Id）否则拒绝；`gateway_server` 透传 `sessionId`；4 单测锁定。

## 规范收口 ✅ 已落地（2026-10-16）
- [x] 把可见性双档（MO1~MO5）+ MO6/MO7 裁决钉为编排内核权限矩阵权威，回填/对账 window-kernel-split.md §8.4 两平面图表述，移除任何「host 为服务端第三档」的歧义。
- [x] PC 投影协议：界定 PC 视图 = 主客户端投影（host + public + active private），写清 PC 无独立私有槽、阶段一只读、阶段二绑定走主客户端（见 §8.4）。

## 本地插件私有化 + 默认钉选 Hybrid ✅ 已落地（2026-10-16，MO8）
- [x] B：本地插件并入 `privateServerIds`、不默认激活、受单槽门控；上下文菜单可选定占用单槽。
- [x] Hybrid：统一默认私有服务持久键（`default.private.server`）+ 设置页「默认私有服务」面板（覆盖手动端点+本地插件）；聊天菜单移除持久默认开关，仅保留本会话覆盖（原 `isDefault` 对本地插件 no-op 的缺口一并修复）。
