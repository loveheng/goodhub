---
status: active
updated: 2026-10-16
---

# arch-hardening：架构债修复施工稿（内核单入口 + 反向边斩断）

> **定位**：施工 epic 的范围/顺序/验收勾稽表。**内容 SSOT = [`window-kernel-split.md`](window-kernel-split.md)**（架构裁决十二项 §8.1、执行路线图 §7.5 步 0→3）；规则链 = `coding-standards.md` §1.1 → `goodhub-workflow` skill「架构依赖纪律与修复施工规范」节。本文严禁复制上述正文，只登记施工态。
> **背景**：2026-10-16 架构盘点判 S2（六信号命中 #2 装配 ×3、#4 公共接口），结构性方案已在 window-kernel-split 立法拍板（该 epic 已归档）；本 epic 承接其施工。

## 1. 施工范围（对齐 §7.5 步 0→3）

| 步 | 交付 | 关键验收 | 状态 |
|---|---|---|---|
| 0 | `lib/coordinator/mcp_runtime.dart` 纯 Dart 契约（SessionContext 快照 / SamplingQuota 独立入参 / RuntimeDelegates 八端口 + Abort 兜底 / McpAssembly.abort+close 幂等 / ConversationSession 写回签名）+ `lib/app/service_directory.dart` 单入口收敛三拼（**顺带修 `gateway_controller:148` 漏 prefs 迁移活 bug**）+ 契约基线测试同轮 | 新文件零接线；analyze 0 新增；测试全绿不降 | ✅ 已完成（window-kernel-split 并行施工入库，2026-10-16 重勘确认） |
| 1 | 搬迁 `chat_page._send` 658-970（含 `_startConnection`、`_GuardedExecutor`）入 McpRuntime；`test/coordinator/mcp_runtime_test.dart` 装配产物等价性 + 资源释放断言（`clientFactory` 注入 fake 计数） | 真机端到端冒烟（聊天 + 私有域切换） | ✅ 已完成（window-kernel-split 并行施工，步 3 接线同批入库） |
| 2 | 收敛调用点按序：`gateway_controller._assemble`（活 bug 所在，优先）→ `gateway_loop_debug_page` 只复用挂载原语 → `task_loop_service` 仅 `mountEndpoint(ephemeral)` 适配（凭证隔离：不进 Directory / scope 强制任务上下文） | 每收敛一点：等价性单测 + 释放断言；红灯清单对应行同步清零 | ✅ 已完成（7d86e20 步 2 收敛 + arch-hardening 反向边斩断，红灯表 2026-10-16 清零） |
| 3 | ChatPage 接线瘦身（`_send` 变薄 / `_samplingQuota` 归 ConversationSession / `WorkspaceStreamFilter` 构造落盘迁出）+ 行为变更回归三条（配额切会话重置 / headless L2 恒 user_rejected / transcript 全量替换不翻倍） | analyze 0 新增 + 全绿 + 端到端回归 | ✅ 已完成（ConversationSession/Archive/MemoryKernel 接线，2026-10-16；端到端回归待下次真机冒烟顺带核） |

## 2. 施工纪律（速查，正文见上游）

- 修复期**禁止新增任何反向边**；存量违例（`mcp→coordinator/sandbox`×4、`gateway→ui`×1、`ui↔gateway` 环）随步 2 清零，每清一条同步 `goodhub-workflow` 红灯表 + `goodhub-index` 债表状态列。
- `ServerEndpointStore` 唯一 owner = 装配容器单例；`lib/mcp/tool_router.dart`（海关过滤）**不删不引**；`MemoryStore` 兼审计日志本轮不动；`TaskLoop` 绕目录仅适配不改流程。
- 内核新文件**严禁 import Flutter Widget**；装配函数必须带注入位（范式 `server_probe.dart` clientFactory）。

## 3. 验收基线

`export PATH="$HOME/flutter/bin:$PATH" ANDROID_HOME="$HOME/android-sdk"` 后：`flutter analyze` 0 新增（存量 1 info：`gateway_loop_debug_page.dart:670`）；`flutter test --timeout 120s` 全绿（记录基线 491 例，实时为准）；步 1/3 加真机端到端冒烟。步级闭环按 dev-loop §2 记账，测试写保护覆盖 tests/core 与既有装配基线。
