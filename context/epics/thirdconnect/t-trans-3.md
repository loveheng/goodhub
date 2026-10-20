---
dev-loop: task-card
format: v1
epic: thirdconnect
task: T-trans-3
status: done
updated: 2026-10-12
---

# T-trans-3：Binder 事件回传（onEvent → progress / _async 终帧 / 反向请求 → answerReverse）

> 归属：thirdconnect T-trans 系列。契约 SSOT：docs/design/thirdconnect.md §1.2.2（AIDL 消息流）/ §5（反向请求与进度）/ §1.2.3（Binder 调用约束）/ §9.1（状态机）。
> 前置：T-trans-2（宿主 BinderTransport 状态机 + 通道注册）；后续：T-sdk-2（SDK 事件发射端，补齐本任务 e2e）/ T-trans-4（PackageManager 发现）。

## 1. 任务定位与交付物

- **任务编号**：`T-trans-3`
- **职责**：消费插件经 `IMcpCallback.onEvent` 回推的事件，按 §1.2.2 / §5 路由：
  1. `notifications/progress` → 喂给在途 [McpClient.callWithProgress] 的 `onProgress`（收侧兑现）；
  2. `_async` 异步终帧（同 id 的 `result`/`error`）→ 唤醒 [McpClient.call]/[sendStream] 等待的 completer（§1.2.2 长任务约定）；
  3. 反向请求（server→client，带 `method`+`id`，如 `sampling/createMessage`）→ 经 [McpClient.onServerRequest] 处理后由 `answerReverse`（oneway）回程（§5 闭环）。
- **边界（§11.3 / §5）**：反向请求对 Binder 走 `answerReverse`（oneway），**绝不**走 `call` 内联应答（那是 HTTP SSE 内联路径）——本任务在传输层就把反向请求从事件广播中剔除，避免 callWithProgress 误用 `send` 回程。

### 交付物
1. `lib/mcp/transport/binder_transport.dart`（`McpTransport` 实现）重写：
   - `_onNativeEvent`：解析 `{transportId, message}`，按 `method`/`id` 分流（progress → 广播；终帧 → completer + 广播；反向 → `_handleReverseRequest`）；
   - `_eventBroadcast`：`StreamController.broadcast` fan-out，按 `progressToken`/`id` 被在途 `sendStream` 过滤消费；
   - `send`：`_async` 占位时保持 completer 开启（在 `await send` 之前注册，规避竞态）直到 onEvent 同 id 终帧；
   - `sendStream`：订阅广播先于 `await send`；progress 封装为 SSE `data:` 帧、终帧收尾关闭流；复用 [McpClient.callWithProgress] 既有 SSE 分帧解析（零协议层改动）；
   - `_handleReverseRequest` + `_reverseFrame`：与 `McpClient._answerServerRequest` 同语义（-32601 / McpRpcException 透传 / -32603）。
2. `lib/mcp/mcp_client.dart`：`McpClient.binder` 工厂把 `BinderTransport.onServerRequest` 转发到 client 处理器（闭包读最新值，handler 后置赋值安全）。
3. `android/app/.../BinderTransport.kt`：`onEvent` 经 `Handler(Looper.getMainLooper())` post 回主线程再 `EventChannel` 发 Dart（§1.2.3 合规）。

## 2. 落点

| 实现件 | 文件 |
|---|---|
| Dart 事件路由 + 反向回程 | `lib/mcp/transport/binder_transport.dart` |
| Client 工厂转发 onServerRequest | `lib/mcp/mcp_client.dart` |
| 原生 onEvent 主线程投递 | `android/app/src/main/kotlin/com/zzh/goodhub/BinderTransport.kt` |

## 3. 验收标准

- `flutter analyze`：`lib/` 零新增错误（已验证）。
- 真机联调（待 T-sdk-2 + 设备）：同机装 goodhub + 一个发射事件的插件（T-sdk-2 后），对 `_async` 工具 `call`/`callWithProgress` 能等到真实结果；`callWithProgress` 收到 `notifications/progress` 回调；插件发 `sampling/createMessage` 反向请求时宿主处理后经 `answerReverse` 回程闭环。
- 隐式验证 §1.2.3：onEvent 不卡主线程（主线程投递）；§9.1：`_async` completer 在 onEvent 终帧前保持开启，不悬挂。

## 4. 实施记录（2026-10-12）

- 重写 `binder_transport.dart`：补全 `_onNativeEvent` 分流、`_eventBroadcast` fan-out、`send`/`sendStream` 的 `_async` 等待与 progress SSE 帧封装、`_handleReverseRequest`/`_reverseFrame` 反向回程（对齐 `McpClient._answerServerRequest` 的 -32601/-32603 语义）。
- `McpClient.binder` 工厂：把 BinderTransport 的反向请求处理器转发到 client 的 `onServerRequest`（闭包读最新值）。
- 原生 `BinderTransport.kt`：`onEvent` 加 `mainHandler.post { eventSinks[tid]?.success(...) }`，满足 §1.2.3「post 回主线程再经 EventChannel 发 Dart」。
- 协议层零改动：`sendStream` 把 progress/终帧封装为 SSE `data:` 帧，`McpClient.callWithProgress` 既有 SSE 解析直接复用。

## 5. 后续 / 范围说明

- **依赖 T-sdk-2 才能 e2e 验证**：当前 sample-dummy-plugin（T-sdk-1）是纯同步工具，仅覆盖 T-trans-2 同步链路；progress/`_async`/反向三类的真实发射需 T-sdk-2（SDK 经 `pushEvent` 投递异步终帧 + progress + reverse 应答骨架）——本任务已完成宿主收端，等 SDK 发射端补齐即闭环。
- **TC11 原生 200ms 进度节流**：§10.3 将其归类 G1~G5（网关硬化），不在 T-trans-3 范围；当前单事件透传路径 spec-correct，节流留 G 系列统一实施。
- **T-trans-4**：PackageManager 动态发现 + `PACKAGE_ADDED/REMOVED` 广播，自动装配多 `BinderTransport`（替代当前手动传 package/service 类名），下一步推进。
