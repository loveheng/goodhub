---
dev-loop: memory
format: v1
epic: arch-hardening
total-merged: 1
last-merge: 2026-10-17
---

# arch-hardening

- [挂载] docs/design/arch-hardening.md

## 定位

承接 `window-kernel-split`（已归档立法 epic）步 0→3 的施工 epic；内容 SSOT = `docs/design/window-kernel-split.md`（架构裁决十二项 §8.1 / 路线图 §7.5），施工态勾稽 = `docs/design/arch-hardening.md`。规则链 = `coding-standards.md` §1.1（五条判据）。

2026-10-16 架构盘点判 **S2 结构性引入**（命中否决信号 #2 装配 ×3、#4 改公共签名）；用户拍板**范围 A：架构债一次性全量清干净 + 形成规范**。

## 已闭环（2026-10-16 ~ 10-17）

**步 0~3 施工**：契约件 `lib/coordinator/mcp_runtime.dart`（纯 Dart，Run 级装配唯一入口 + `clientFactory` 注入位）；服务目录三拼收敛为 `lib/app/service_directory.dart` 单入口（顺带修 `gateway_controller` 漏 prefs 迁移的活 bug）；装配调用点收敛为 chat / gateway_controller / gateway_loop_debug_page / task_loop 四处的挂载原语。

**四条反向边斩断（清零，此后新增即违例）**：
| 方向 | 落点 |
|---|---|
| gateway→ui | 弹层迁 `ui/gateway_consent_dialog.dart`；gateway 只留 GateDelegate 接口 + fail-closed（`headless_no_ui_prompt` 恒拒） |
| mcp→coordinator | `mcp/connection_face.dart` 注入 + `ToolExecutionResult` 下沉 `core/tool_result.dart` + opsLog 走 `core/audit_sink.dart` 端口 |
| mcp→llm | `SamplingEngine` 端口 + 消息货币 `core/chat_message_data.dart` + 云适配 `llm/cloud/sampling_engine.dart` |
| sandbox→llm | transcript codec 迁 `llm/cloud/chat_message_codec.dart`，存储层只认 JSON Map + core DTO |

**#7 收口**：`GatewayController.shared` 的 `_activePrivateServerId` 重命名为 `_hostDefaultPrivateServerId`，澄清为 **host-level 默认投影源**（非会话态）；per-connection 投影隔离已在 `McpGatewayServer._handlers` + `forSession()` 落地并测试；补 POST-only 连接投影上下文泄漏修复（`idleTimeout` + `_gcIdle` + `_lastActivity`）。禁令保留：禁止在 shared 上加新会话级字段。

**#11 决策**：投影平面 `workspaceId` **选 B 暂不接线**（PC 协议 MCP 2025-06-18 initialize 不携带、网关侧无消费者），设计预留待产品裁决；`host-gateway-accessibility-memory.md` §2.1 三元描述维持目标态不改。

**海关过滤（SA-Q6）**：`lib/mcp/tool_router.dart` **保留待接线、不删不引**——现网服务端普遍不下发 annotations，启用即过滤全部工具、生产归零。启用三项前置条件：a 现网普遍下发 annotations / b fail-closed 默认关 / c 等价性单测 + 全量工具可见性回归。已立法进 `coding-standards.md` §1.1 规则 7。

**chat_page 拆分（三步）**：step1 会话内核下沉 `coordinator/chat_session_service.dart`（`trackJson` 以 `List<Map<String,Object?>>` 中立数据过边界，规避 coordinator→ui 反向边复燃）；step2-1 抽 `components/chat_composer.dart`；step2-3 抽 `components/chat_gate_delegates.dart`（Gate/Block/Fence 三 delegate 经 `ChatTrackSink` 接口回注）；step2-2 跳过（`_buildDrawer` 已是薄包装，无内联价值）。chat_page 由「内核+UI 混杂」瘦身为装配层。

**规范立法**：`coding-standards.md` §1.1 规则 7（海关红线）新增；规则 1（装配层内核纯 Dart）+ 规则 6（反向边红线）此前已固化，不重复立法防双源漂移。

## 验收基线

- `flutter analyze` → **No issues found**（0 新增，为交付线）
- `flutter test --timeout 180s` → **707/707 全绿**
- 写链确定性排空 API：`SequentialFileWriter.settled` + `MemoryStore` / `WorkspaceStateStore` 的 `ioDrained`——替换原 100ms 固定延迟「猜等」，消除 `memory_kernel_test`×2 在全仓 706 并发下的存量 flaky（根因：CPU 饱和时延迟窗口不够，读写竞态）
- 真机冒烟（聊天 + 私有域切换）留作最终验收，非代码阻断

## 断点

- [断点] 下一步：S2 大需求「架构债全量清干净 + 形成规范」推进中（用户拍板 范围 A 全量：ui→gateway 斩断 + 测试基线 + chat_page 拆分 + 双 ToolRouter/海关过滤接线(含 SA-Q6)；规范落点 A 更新 coding-standards 架构红线；epic 延续 arch-hardening）。**断点①②已完成**（ui→gateway 斩断 + 依赖护栏测试 2/2 绿，analyze 0 issue）；**断点③ step1 抽会话管理 ✅完成**（coordinator/chat_session_service.dart 建 + chat_page 接入 getter 委托 + analyze 0 + coordinator/gateway/sandbox 单测 369 绿）；**断点③ step2-1 抽底部输入集群 ChatComposer ✅完成**（lib/ui/components/chat_composer.dart；analyze 0 + chat_page 冒烟 5/5 绿）；**断点③ chat_page 拆分 ✅全部完成**（step1 会话内核下沉 service + step2-1 抽 ChatComposer + step2-3 抽 delegate 经 ChatTrackSink 接口；analyze 0 + UI 冒烟 5/5 绿）；**断点④ ✅完成（红线闭环）**：调查确认双 face(local Binder+cloud HTTP)已接进 coordinator/tool_router(mcp_runtime:407-465)；海关过滤 lib/mcp/tool_router.dart 受 SA-Q6 拍板「保留待接线」+ 施工纪律「不删不引」约束，启用会过滤现网全部未打标工具、生产归零，当前不可行——断点④ 转为红线闭环（确认 mcp/tool_router 维持不删不引、双 face 已接、海关红线=保留待接线+三项启用前置条件，待 SDK 发 annotations 后按 #9 补强接线）；无 coordinator 生产代码改动。**断点⑥ ✅完成 + epic arch-hardening 收官**：`flutter analyze` → No issues found!（0 新增）；断点①②③④⑤ 全 ✅；devlog/memory 闭环；海关过滤红线立法（§1.1 规则7）+ 反向边/装配层红线（规则6/1）固化。真机冒烟（聊天+私有域切换）留作最终验收，非代码阻断。建议提交（用户执行）。#7 已收口；#11 选 B 设计预留不写码。
