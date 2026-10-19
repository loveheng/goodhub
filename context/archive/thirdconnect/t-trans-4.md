---
dev-loop: task-card
format: v1
epic: thirdconnect
task: T-trans-4
status: done
updated: 2026-10-12
---

# T-trans-4：本地插件发现 + 零配置自动挂载（系统托管）

> 归属：thirdconnect T-trans 系列（TC1~TC14）。契约 SSOT：docs/design/thirdconnect.md §1.2.4（发现）/ §4（系统托管端点）/ §9.4（同 User 越界）/ §5（反向请求闭环）。
> 前置：T-trans-2（宿主 BinderTransport 状态机）、T-trans-3（宿主事件回传）、T-sdk-1/2（插件侧 SDK + 事件发射端）。配套消费端均已落。
> 目的：让 GoodHub 自动发现已安装的本地插件（声明 `com.zzh.goodhub.action.MCP_SERVER`），零配置挂载为 BinderTransport 并接线 `onServerRequest=samplingRequestHandler`，闭环反向请求 e2e（§5）。

## 1. 任务定位与交付物

- **任务编号**：`T-trans-4`
- **职责**：本地插件「系统托管」端点——安装即挂载、卸载即摘除，不进用户手填配置；并接线反向请求处理，使插件侧 `reverseRequest`（sampling/createMessage，T-sdk-2）能在宿主侧得到应答 → `answerReverse` 回程。
- **红线对齐（§1.2.7 / §9）**：物理主键 = `PackageName`（非 SERVER_ID，§9.3）；同 User 空间扫描（不附加 `MATCH_ALL` 跨 User 标志，§9.4）；发现失败 / 挂载失败 → 降级为空目录 / TrackNote 告警，绝不阻断既有 HTTP 端点装配。

### 交付物
1. **宿主 Native（`android/app/.../BinderTransport.kt` → `object BinderTransportBridge`）**：
   - 新增 `discover` MethodChannel 方法：`PackageManager.queryIntentServices(Intent(ACTION))` + 读 meta-data（`SERVER_ID`/`SERVER_TITLE`/`packageName`/`serviceClassName`）→ 返回 JSON 目录；
   - 注册 `PACKAGE_ADDED/REMOVED/REPLACED` 广播（`RECEIVER_NOT_EXPORTED`，data scheme `package`）→ 经 `goodhub/binder_discovery` 通道 native→Dart 通知重扫；
   - `<queries>` 声明该 Action（Android 11+ 包可见性，§1.2.4）。
2. **Dart 发现门面（`lib/mcp/local_plugin_discovery.dart`）**：`LocalPluginInfo` + `LocalPluginDiscovery`（单例）：`scan()` 拉扫、`changes` 流（包变更）、`createClient(info)` 构 Binder McpClient。
3. **生产装配（`lib/ui/chat_page.dart` `_send`）**：装配前扫描本地插件，与 HTTP 端点合并判定；每个本地插件 = 一个 Binder `McpClient` + `McpToolFace` 纳入同一 `ToolRouter`；`onServerRequest(sampling)` 由既有统一循环接管（反向请求 e2e 闭环）；本地-only 用户（无 HTTP 端点）也能进入装配。
4. **调试页（`lib/ui/gateway_loop_debug_page.dart`）**：新增「扫描本地插件」按钮 + 下拉选 Binder 目标，`_run` 选中本地插件时走 Binder 而非 HTTP——作为反向请求 / 进度 e2e 的直接联调面。

## 2. 落点

| 实现件 | 文件 |
|---|---|
| 宿主发现（discover + 广播 + channel） | `android/app/src/main/kotlin/com/zzh/goodhub/BinderTransport.kt` |
| `<queries>` 包可见性 | `android/app/src/main/AndroidManifest.xml` |
| Dart 发现门面 | `lib/mcp/local_plugin_discovery.dart` |
| 生产自动挂载 + sampling 接线 | `lib/ui/chat_page.dart` |
| 调试页 Binder 目标选择 | `lib/ui/gateway_loop_debug_page.dart` |

## 3. 验收标准

- `flutter analyze lib/mcp/local_plugin_discovery.dart lib/ui/chat_page.dart lib/ui/gateway_loop_debug_page.dart`：仅 1 条 pre-existing deprecation info，无 error（已验证 2026-10-12）。
- `./gradlew :app:compileDebugKotlin`：BUILD SUCCESSFUL（已验证 2026-10-12）。
- 真机联调（待设备 + 同机两 APK）：GoodHub 启动 → `scanLocalPlugins` 经 `<queries>` 命中 dummy 插件（action+meta-data）；chat_page/gateway 调试页挂载后 `dummy__slowEcho` / `dummy__reverseDemo` 可调用；`reverseDemo` 触发宿主 `samplingRequestHandler` → `answerReverse` 回程 → 插件 future 解析（反向请求 e2e 闭环）。

## 4. 实施记录（2026-10-12）

- `BinderTransport.kt`：`object BinderTransportBridge` 加 `DISCOVERY_CHANNEL` / `DISCOVERY_ACTION` / `META_*` const；`discoveryChannel` 字段；`packageChangeReceiver`（广播，RECEIVER_NOT_EXPORTED）；`register()` 内建 discovery MethodChannel + 注册广播；`scanLocalPlugins()`（queryIntentServices + GET_META_DATA，默认当前 User 空间，失败返空目录）；`notifyPluginsChanged()`（native→Dart 静默丢帧）。
- `AndroidManifest.xml`：`<queries>` 增 `com.zzh.goodhub.action.MCP_SERVER` intent。
- `local_plugin_discovery.dart`（新）：`LocalPluginInfo` + `LocalPluginDiscovery` 单例（`scan()` / `changes` 流 / `createClient()`）；Dart 未就绪时 native 通知静默丢帧。
- `chat_page.dart`：`_send` 装配前 `localPluginDiscovery.scan()` 并入 `locals`；HTTP 端点循环后挂载本地插件为 `McpToolFace`（best-effort，失败 TrackNote 告警）；`clients` 统一循环已接管 `onServerRequest(sampling)`，本地客户端自动获接线；本地-only 用户（endpoints 空但 locals 非空）可进入装配。
- `gateway_loop_debug_page.dart`：加 `_localPlugins` / `_selectedLocal` 字段 + `_scanLocal()`；UI 加「扫描」按钮 + 本地插件下拉；`_run` 选中本地插件时以 `McpClient.binder` 替 `McpClient.http`，`face.serverId` 取插件 id。

## 5. 后续 / 范围说明

- **设备 e2e 待补**：T-sdk-1/2（插件）+ T-trans-2/3/4（宿主）均已就绪；真机闭环需同机装 goodhub + sample-dummy-plugin 两 APK + 设备（T-trans-2/3 既定待办）。
- **「ServerEndpointStore 系统托管分区」v1 落地口径**：本任务把系统托管端点实现为「装配期运行时 face」（不持久化到用户手填 `mcp_servers.json`）——零配置、随包变更重扫即刷；与 §4 语义一致（不进用户配置流程）。后续若需跨会话缓存/审计，可再加 persist 分区（非本任务范围）。
- **tools/list_changed 下行（§9.2）**：包变更目前触发 Dart `changes` 流，但 chat_page 装配为会话粒度、未订阅该流做热推送；PC 侧 `tools/list_changed` 主动下行归 G 系列网关（未在本任务范围）。
- **安全闸门（§1.2.6）**：当前发现即挂载（默认 `signature` 私有生态零弹窗，第三方走信任卡片白名单的 UI 接线尚未落地）；信任卡片白名单为独立安全任务，不阻塞本发现链路。
- **T-sdk-2 反向请求 e2e 现已闭环**：宿主侧（T-trans-3 discover/answerReverse + 本任务 onServerRequest 接线）与 SDK 发射端（T-sdk-2）齐备，待设备验证。
