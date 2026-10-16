---
status: draft
updated: 2026-10-17
---

# window-slim：窗口层瘦身与编排下沉

> 来源：2026-10-17 P1 结构盘点（账实核对当日快照，逐条对当前代码验证过）。
> 定位：窗口层（ui/）过厚、双实现并存、降级不可见、释放不幂等的系统性收口 epic。
> 上游规则 SSOT：`docs/design/window-kernel-split.md` §5 四条铁律 → `docs/project/coding-standards.md` §1.1。

## 1. 问题清单（账实核对版）

### P1-A 窗口层过厚（一页七责）

| 证据（当日复核） | 判定 |
|---|---|
| `settings_page.dart` 2145 行、setState 33 处、领域态字段 9 个（`_epStore:142`/`_trustedPackages:155`…） | 一页七责 |
| `settings_page.dart:385` 直连 `ServerProber().probe` 真网络探活；`:1823/:1872` 直改信任白名单；`:2128/:2138` 直写存储 | 窗口越界做编排 |
| `chat_page.dart:654` 起 `_send` 仍约 390 行，内联装配+信任闸门+记忆分层+两个 dialog | Run 编排未下沉 |
| `chat_page.dart:708/:712` 直接装配 `WorkspaceStateStore`/`MemoryStore` | 窗口直达 sandbox |
| pubspec 无 Provider/Riverpod/BLoC，16 个 StatefulWidget 全靠 setState 整页 rebuild | 无局部刷新粒度 |

注：早前快照提及的 `chat_session_service.dart`/`chat_composer.dart`/`chat_gate_delegates.dart` 三文件**当前树中不存在**——会话态下沉现状须开工前重新取证。

### P1-B 双实现与死件并存

- 双 Run 装配：`chat_page:775` `assemble` vs `gateway_loop_debug_page:320` `mount` + `:370` 手搭 `MemoryToolExecutor`
- 双 BYOK 表单：`settings_page` vs `gateway_loop_debug_page:795`
- 非生产面 ~1700 行：`gateway_loop_debug_page` 1145 + `grammar_spike_page` 350 + `claim_loop_page` 229；`archive/local_model/`
- `mcp/tool_router.dart` 双 ToolRouter：**已拍板「不删不引」+ R6 门禁封存（arch-hardening），本 epic 不再处理**

### P1-C 降级对用户不可见

- 93 处 `[DEGRADE]` 埋点绝大多数走 debugPrint/developer.log，release 用户零感知；接 `onNote` 进聊天轨迹的仅 `mcp_runtime`/`hybrid_assembly` 两文件
- 最危险三处：`coordinator/memory_kernel.dart` 写失败 `unawaited + discarded_futures` 静默丢事实；`gateway_server.dart` 心跳写失败空吞（僵死连接不可观测）；`mcp_gateway_handler.dart` progress 帧遮蔽失败原样透传（注释称"非数据面有意降级"，但与 `gateway_security.dart` 的 fail-closed 边界划分未成文）

### P1-D 释放不幂等 / 无释放

- `binder_transport.dart` `close()` 二次调用抛 StateError（无防重入守卫）；`task_loop_service.dart` 持有 client 全类无 close；`server_endpoints.dart` `save()` 裸 tmp→rename 不经串行队列
- 范式参照：`mcp_runtime.dart` `McpAssembly.close()` 幂等 + 异常路径全量回收——应全仓推广

### 低优先级结构气味

- `llm/cloud/sampling_engine.dart` → `mcp/sampling.dart`：SamplingEngine 端口落在客户端域（DIP 折中，接口归属错位）
- `coordinator/hybrid_inference.dart` → `task/task_inference.dart`：编排域依赖 M1 遗产 debug 域
- `ui/gateway_consent_dialog.dart` 从 gateway 取常量 `kGatewayConsentTimeout`（应下沉 core）
- `gateway_api/gateway_control.dart:8` 声称的 `gatewayControlOverride` 注入位全仓不存在（文档漂移，待核装配处）

### 测试缺口

`gateway_api/`、`app/service_directory`、`update/installer`、`core/security` 零用例；`integration_test/` 6 个不进 flutter test 基线。

## 2. 施工原则

1. **编排下沉不引框架**：先按 window-kernel-split 拓扑把 Run 编排、设备/权限策略下沉到 coordinator/gateway 端口层；状态管理框架引入属独立决策，未经拍板不进本 epic。
2. **窗口只持展示态**：领域态字段逐步迁出 settings_page/chat_page，迁移一批验一批（analyze + 全量测试绿为验收线）。
3. **降级可见性分级**：数据面写失败（memory_kernel 类）→ 升为可观测失败（onNote/回执）；非数据面 → 成文边界划分（与 fail-closed 口径合写进 coding-standards）。
4. **close 幂等范式推广**：以 McpAssembly.close 为样板，逐个补防重入守卫 + 释放断言测试（arch-hardening 施工验收口径：等价性单测 + 资源释放断言，不靠真机冒烟）。
5. 红线沿用 work-flow skill「架构依赖纪律」：修复期禁新增反向边，改相关代码前查 goodhub-index。

## 3. 拆解（候选顺序，开工时按 ::next 收敛）

1. P1-D 释放卫生（范围最小、有样板、可独立验收）→ 2. P1-C 降级可见性分级 → 3. P1-A chat_page Run 编排下沉 → 4. P1-A settings_page 分段拆解 → 5. P1-B 调试页/死件收敛 → 6. 测试缺口补齐。

## 断点

（待 ::next 拆解首个子任务）
