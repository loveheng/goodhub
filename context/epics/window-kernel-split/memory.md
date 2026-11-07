---
dev-loop: memory
format: v1
epic: window-kernel-split
total-merged: 1
last-merge: 2026-11-07
state: maintenance
---

# window-kernel-split（维护态）

- [挂载] docs/design/window-kernel-split.md——裁决 12 项 SSOT=§8.1 台账（本文件不抄正文）；实施计划=域内 plan.md（WBS/门禁/回滚点）
- [域] ai-app-split 从属大域（goodhub/goodshare 拆分的宿主侧架构）；本 epic=其 UI/装配侧落地
- [形态] 两层+端口：窗口投影层单向依赖内核层；向下值对象（SessionContext+装配选项）、向上 8+1 端口（第 9 广播端口 onNotice 补于步 1）；横向内核走具体类型+快照无接口=显式取舍非 Clean/Hexagonal
- [实施] 步 0~步 3 全部完成（2026-10-16）：lib/app/service_directory.dart 单一入口（修 gateway_controller:148 漏 prefs 活 bug）/ lib/coordinator/mcp_runtime.dart 契约件（纯 Dart 无 Flutter import）/ 装配内核自 chat_page 658-970 迁入 / mount·mountEndpoint 三调用点收敛（ephemeral 隔离）/ ChatPage 瘦身 1421→1402 行 / endpointStoreOverride·engineOverride 注入位
- [验收] 三项行为变更全部代码级闭环（配额切会话重置单测 / headless L2 恒 user_rejected 断言 / transcript 三断言）；测试 588→601 全绿；真机冒烟用户验收通过（聊天正常）；gateway 生产路径真机冒烟挂起（DoD 未闭，随下次网关真机轮）
- [遗留债] 8 条移交全局 context/todos.md（标 [window-kernel-split 移交]，多数收敛条件指向 Archive epic）+ 6 条耦合残留（事件循环留窗口两处写内核态等，显式取舍的登记面，域内 done.md 有案）
- [规范沉淀] coding-standards §1.1 分层纪律（五硬规则+三形态判据）+ §1 lib/app/ 唯一例外白名单 + §6.1 装配等价性单测要求——后续内核认领必须遵循
- [SSOT 修正存档] `lib/mcp/tool_router.dart` 非死件（F1.9 海关过滤唯一实现，保留待接线不删，装配不得引）；铁律 2 降级已拍板接受（不引 Router）

## 断点
- [断点] 已完结：步 0~3 交付+三项行为变更验收代码级闭环+真机冒烟通过（gateway 生产路径冒烟挂起随网关真机轮）；::done 审计域内零阻断，标记结算 0/0/0
