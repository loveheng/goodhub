---
dev-loop: task-card
format: v1
epic: thirdconnect
task: T-trans-2
status: in_progress
updated: 2026-10-12
---

# T-trans-2：宿主端 BinderTransport（client 端 + 挂起状态机）

> 归属：thirdconnect T-trans 系列。契约 SSOT：docs/design/thirdconnect.md §1.2.2（AIDL）/ §1.2.3（Binder 约束）/ §9.1（冷启动状态机）。
> 联调靶子：T-sdk-1 产出的 `sample-dummy-plugin` APK（echo / add 两工具）。
> 前置：T-sdk-1 已落地（SDK 骨架 + dummy 靶子）；后续：T-trans-3（事件回传）/ T-trans-4（发现）。

## 1. 任务定位与交付物

- **任务编号**：`T-trans-2`
- **角色**：宿主侧 `BinderTransport`（client 端）——把单个本地插件的 `IMcpChannel` 客户端封装为与 `HttpTransport` 对等的 `McpTransport` 实现，经 `bindService` 同机零端口调用插件。
- **职责边界（§11.3 五处纠正·1）**：client 端连接生命周期（状态机 / 挂起队列 / DeathRecipient）完全在宿主侧；SDK 侧只实现 `IMcpChannel.Stub`（server 端），双方正交。

### 交付物
1. **宿主原生桥** `BinderTransportBridge`（Kotlin，`android/app/.../BinderTransport.kt`）：
   - 连接状态机 `IDLE → CONNECTING → READY → DEAD` + 挂起请求队列（PendingRequestQueue）
   - `bindService` 异步冷启动竞态处理：首个 `send` 触发连接，CONNECTING 期间请求入队、不重复 bind；`onServiceConnected` 后置 READY 按序排空；DEAD → 下次 `send` 自动 `rebind(BIND_AUTO_CREATE)`
   - 冷启动 5s 超时（§9.1）：CONNECTING 超时才向上抛错，不静默吞 / 不卡线程
   - `call` 在后台线程执行（`§1.2.3`：主线程同步 call 超 5s 触发 ANR）
   - `DeathRecipient` 感知崩溃 → DEAD；Binder 断连（`DeadObject`/`Remote`）映射为原生错误上抛，**不伪装** JSON-RPC error 帧（§1.2.3）
   - `registerCallback`：bind 完成后、首次 call 前调用一次（§1.2.2）；`onEvent` 经 `EventChannel` 透传 Dart（progress / 反向请求消费留 T-trans-3）
2. **Dart 实现** `BinderTransport implements McpTransport`（`lib/mcp/transport/binder_transport.dart`）+ `McpClient.binder(...)` 工厂
3. **通道注册**：`MainActivity` 注册 `goodhub/binder_mcp`（MethodChannel）+ `goodhub/binder_mcp_events`（EventChannel）

## 2. 落点

| 实现件 | 文件 |
|---|---|
| 宿主 AIDL 客户端 + 状态机 | `android/app/src/main/kotlin/com/zzh/goodhub/BinderTransport.kt` |
| 钉死 AIDL（宿主侧副本） | `android/app/src/main/aidl/com/zzh/goodhub/mcp/IMcpChannel.aidl` + `IMcpCallback.aidl` |
| Dart 传输门面 | `lib/mcp/transport/binder_transport.dart` |
| Client 工厂 | `lib/mcp/mcp_client.dart`（`McpClient.binder`） |
| 通道注册 | `android/app/src/main/kotlin/com/zzh/goodhub/MainActivity.kt` |

## 3. 验收标准

- `flutter analyze` 通过（Dart）；宿主 `android` 模块 AIDL + Kotlin 编译通过。
- 真机联调（待设备）：同机安装 `goodhub` + `sample-dummy-plugin` 两 APK，`McpClient.binder(transportId:"dummy", packageName:"com.zzh.goodhub.sample.dummy", serviceClassName:"com.zzh.goodhub.sample.dummy.DummyPluginService")` 完成 `initialize` / `tools/list` / `tools/call(echo / add)` 端到端。
- 隐式验证 §9.1：首个调用触发自动 bind + 挂起队列；插件崩溃（DeathRecipient）→ 下次调用自动 rebind。

## 4. 实施记录（2026-10-12）

- 宿主侧复制钉死 AIDL 契约（与 T-sdk-1 同包 `com.zzh.goodhub.mcp`），`android/app/build.gradle.kts` 启用 `buildFeatures { aidl = true }`。
- `BinderTransportBridge`：单 executor 后台派发 `call`；`transports` Map 按 `transportId` 区分多插件（为 T-trans-4 发现预留）；`eventSinks` 按 `transportId` 路由 `onEvent`。
- Dart `BinderTransport`：构造即 `bind` + 订阅事件流；`send` 原生返回裸 JSON-RPC 字符串，成功映射 200、传输层失败映射 `McpNetworkException`；`sendStream` 以单帧流模拟（progress 由 T-trans-3 经 `onEvent` 补）。

## 5. 后续

- T-trans-3：消费 `onEvent` 事件流（progress → `onProgress`；反向请求 → `answerReverse` 回程），替换 T-trans-2 的透传骨架。
- T-trans-4：PackageManager 发现 + 广播热插拔，按 `transportId` 自动装配多 `BinderTransport`（替代当前手动传 package/service 类名）。
