---
memo: todos
format: v2
epic: mcp-orchestration
---
# mcp-orchestration · 域内待办

## mcp-orchestration 待办（MO）

> 决策底：MO1~MO7 全确认（context/epics/mcp-orchestration/memory.md）；契约：docs/design/window-kernel-split.md。

## 阶段一（当前，PC 只读镜像）✅ 已落地（2026-10-16）

## 阶段二（D-D 落地后，解锁 PC 自主私有绑定）
- [ ] (功能) MO6-阶段二：落地 window-kernel-split §2.4「投影平面按 connection/workspace 隔离」——将 `GatewayController.shared` 全局单例改为 per-connection 投影上下文；之后解锁 PC 自主 `use_server` 独占 PC 会话私有槽。

## 跨服务防火墙（$ref 守卫边界）✅ 已落地（2026-10-16）

## 规范收口 ✅ 已落地（2026-10-16）

## 本地插件私有化 + 默认钉选 Hybrid ✅ 已落地（2026-10-16，MO8）
