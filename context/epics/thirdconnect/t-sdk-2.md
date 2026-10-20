---
dev-loop: task-card
format: v1
epic: thirdconnect
task: T-sdk-2
status: done
updated: 2026-10-12
---

# T-sdk-2：SDK 事件发射端（progress / _async 异步终帧 / 反向请求 → answerReverse）

> 归属：thirdconnect T-sdk 系列（TC14 / §11）。契约 SSOT：docs/design/thirdconnect.md §1.2.2（_async 约定）/ §5（反向请求与进度）/ §1.2.7（SDK 红线）/ §11（SDK 工程约束）。
> 前置：T-sdk-1（SDK 骨架 + dummy 靶子）；配套消费端：T-trans-3（宿主 BinderTransport 事件路由，已落）。
> 目的：补齐 SDK 事件发射端，闭环 T-trans-3 的 e2e（宿主收端已就绪，待设备 + 两 APK 同机安装验证）。

## 1. 任务定位与交付物

- **任务编号**：`T-sdk-2`
- **职责**：让第三方 `@McpTool` 工具能经 AIDL 事件通道（`IMcpCallback.onEvent`，oneway）向宿主投递三类事件，对齐 §1.2.2 / §5：
  1. **进度**：`notifications/progress`（带 request `_meta.progressToken`，宿主按 token 归属 callWithProgress）；
  2. **异步终帧**：`_async` 长任务真实 result/error（同 id 终帧，唤醒宿主 `_async` completer，§1.2.2）；
  3. **反向请求**：server→client request（如 `sampling/createMessage`），宿主经 `IMcpChannel.answerReverse` 回程（§5 闭环）。
- **红线对齐（§1.2.7 / §11.3）**：`_async` 透明化（>5s 自动异步，禁同步阻塞越 Binder 预算 ANR）；URI 统一 `mcp-blob://`（本任务未涉及大结果，留 TC9 数据面）；命名不上仲裁；安全闸门无关（SDK 不碰信任白名单）。

### 交付物
1. **`McpToolContext`（新类，SDK 暴露给插件作者）**：仅注入 `@McpTool(async=true)` 工具首参，提供：
   - `progress(progress, total?, message?)` → 推 `notifications/progress`（`params.progressToken` = request `_meta.progressToken`）；
   - `complete(text)` / `completeRaw(result)` / `fail(code, message)` → 推同 id 异步终帧（success/error）；
   - `reverseRequest(method, params?)` → 向宿主发反向 request 帧，返回 `CompletableFuture<JSONObject>` 待 `answerReverse` 回程。
   - 类型对外可见、构造 `internal`，第三方只能「接收」不能自构。
2. **`GoodHubPluginService` 改造**：
   - `@Volatile callback` + 反向请求在途表 `ConcurrentHashMap<Long, CompletableFuture<JSONObject>>` + `AtomicLong` 反向 id 计数器；
   - `answerReverse(json)`：按 id 关联并 `complete`/`completeExceptionally` 唤醒 future（解析失败静默，宿主超时兜底）；
   - `internal reverseRequest(...)`：发 `onEvent` request 帧，未注册回调立即异常完成（绝不悬挂）。
3. **`ToolDispatcher` 改造**：
   - `McpToolContext` 首参识别（`isContext`）：不进 tools/list Schema、不参与 JSON 入参、调用时注入 ctx；
   - `handleAsync(...)`：`call` 立即回 `{"_async":true}`，从 request `_meta.progressToken` 取进度令牌，worker 线程（`Executors.newCachedThreadPool`，守护线程）跑真实工作，业务异常转 `fail` 帧（确保宿主 completer 必被唤醒，不悬挂）；
   - `buildArgs(...)`：context 注入 + 其余按 `arguments` name 映射 coerce（缺必填 → null 触发 INVALID_PARAMS）。
4. **`DummyPluginService`（靶子）新增**：`slowEcho(ctx, text)`（async 分段进度 + 终帧）、`reverseDemo(ctx, prompt)`（发 `sampling/createMessage`，回程结果或降级文案）。

## 2. 落点

| 实现件 | 文件 |
|---|---|
| 异步上下文（progress/complete/fail/reverseRequest） | `android-sdk/plugin-core/.../plugin/McpToolContext.kt` |
| 反向请求在途表 + answerReverse 回程 | `android-sdk/plugin-core/.../plugin/GoodHubPluginService.kt` |
| context 识别 + handleAsync + buildArgs | `android-sdk/plugin-core/.../plugin/ToolDispatcher.kt` |
| e2e 靶子（async + reverse 演示） | `android-sdk/sample-dummy-plugin/.../dummy/DummyPluginService.kt` |

> **2026-10-20 更新**：以上落点已迁至独立仓 `loveheng/goodhub-mcp-sdk`——`plugin-core/` → 该仓 `:plugin-core` 模块，`sample-dummy-plugin/` → `:sample-dummy-plugin` 模块；AIDL 契约迁至该仓 `:contract` 模块（唯一物理副本）。本表路径仅作历史留存。

## 3. 验收标准

- `./gradlew :plugin-core:assembleDebug :sample-dummy-plugin:assembleDebug`：BUILD SUCCESSFUL（已验证 2026-10-12）。
- 真机联调（待设备 + 同机装 goodhub + sample-dummy-plugin 两 APK）：对 `slowEcho` 经 `callWithProgress` 能逐帧收到 `notifications/progress` 且终帧返回 `async: <text>`；对 `reverseDemo` 宿主经 `sampling/createMessage` 回程推理结果（宿主需为该 Binder client 设 `onServerRequest=samplingRequestHandler`，见 lib/mcp/sampling.dart；若未设则回 -32601，工具降级为 `reverse failed:` 文案，不悬挂）。
- 隐式红线验证：async 工具 `call` 立即返回 `_async:true`（不阻塞 Binder 事务预算 §1.2.3）；worker 异常 → `fail(-32603)` 终帧（§1.2.7 异常隔离）。

## 4. 实施记录（2026-10-12）

- 新增 `McpToolContext.kt`：进度/完成/失败/反向四类能力，全部经 `service.pushEvent`（onEvent oneway）投递；`reverseRequest` 委托 `service.reverseRequest`。
- `GoodHubPluginService.kt`：`callback` 改 `@Volatile`；新增 `pendingReverse` 在途表 + `reverseCounter`；实现 `answerReverse` 按 id 唤醒 future；新增 `internal reverseRequest`；`pushEvent` 改 `internal`（Kotlin protected 非包可见，McpToolContext 同模块访问需 internal）。
- `ToolDispatcher.kt`：`ParamMeta.isContext`；`scan` 识别并跳过 context 参数（不进 Schema）；`toolsList` 跳过 context；`toolsCall` 按 `@McpTool.async` 分流到 `handleAsync`；`handleAsync` 取 progressToken + 注入 ctx + 守护线程池跑工作 + 异常转 fail；`buildArgs` 支持 context 注入与按名映射。
- `DummyPluginService.kt`：新增 `slowEcho`（async 分段进度+终帧）、`reverseDemo`（sampling 反向请求，降级不悬挂）。
- 编译通过：plugin-core AAR + sample-dummy-plugin APK assembleDebug 成功。

## 5. 后续 / 范围说明

- **设备 e2e 待补**：T-trans-3 宿主收端 + 本任务 SDK 发射端均已就绪，真机闭环需同机两 APK + 设备（T-trans-2/3 既定待办）。
- **宿主 Binder client 接线确认**：反向请求 e2e 要求 GoodHub 在构造 `McpClient.binder(...)` 后设置 `onServerRequest = samplingRequestHandler(...)`（host 侧 lib/mcp/sampling.dart 已具备；接线点随 T-trans-4 发现/挂载逻辑落位）。
- **大结果 URI 降级（TC9 / §1.2.7）**：`mcp-blob://` 数据面留待专项（非本任务范围）。
- **T-trans-4**：本地插件 PackageManager 动态发现 + 广播热插拔，自动装配多 `BinderTransport`（含 `onServerRequest` 接线），下一步推进。
