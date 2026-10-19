---
dev-loop: task-card
format: v1
epic: thirdconnect
task: T-sdk-1
status: done
tc: TC14
depends: []
blocks: [T-trans-2]
updated: 2026-10-12
---

# T-sdk-1：插件侧 SDK MVP 最小骨架

> 归属：TC14 通用插件接入 SDK（thirdconnect epic）。契约 SSOT：docs/design/thirdconnect.md §1.2.2（AIDL）/ §1.2.7（SDK 红线）/ §11（TC14 SDK）。
> 定位：独立的 Kotlin/Android 模块 `goodhub-mcp-plugin-core`，提供插件端最简运行底座；作为 **T-trans-2（宿主 BinderTransport）的真机联调靶子**。

## 1. 任务定位与交付物

- **任务编号**：`T-sdk-1`（插件侧 SDK MVP 最小骨架）
- **角色边界**：SDK 仅实现 `IMcpChannel.Stub`（server 端）；client 端连接生命周期（§9.1 状态机 / `PendingRequestQueue`）属 GoodHub 宿主，SDK 不 `bindService`、不持 `DeathRecipient`（§11.3 五处纠正·1）。
- **独立性**：纯 Android 原生（Pure Kotlin + AndroidX），**零 Flutter 依赖**，第三方原生 App 零负担依赖（§11.4 三档接入·Android 原生）。

### 交付物
1. `IMcpChannel.Stub` 服务基类：`GoodHubPluginService`
2. 基础注解：`@McpTool` 与 `@Param`
3. 运行时轻量反射派发器（生成 `tools/list` Schema，把 `tools/call` 路由到目标 Kotlin 函数）
4. 配套验证靶子：`sample-dummy-plugin`（仅提供 `echo` 与 `add` 两个轻量工具的测试 APK）

## 2. 落地红线（做与不做，卡死边界）

1. **Schema 生成方式（避免过度设计）**
   - **做**：v1 运行时 Kotlin 反射提取函数名 / 参数名 / 基础类型（`String` / `Int` / `Boolean`），拼装符合 MCP 规范的 JSON-RPC `tools/list` 结果。
   - **暂不做**：暂不引入 KSP 编译期代码生成，避免立项初期陷于 Gradle 插件 / 注解处理器配置泥潭。

2. **遵守 §1.2.7 红线（严格对齐规范）**
   - **异常隔离**：目标业务函数内部抛出的任何未捕获异常，必须在 Stub 层拦截并转译为标准 JSON-RPC `-32603` 错误帧，严禁未受检异常穿透致宿主跨进程 Crash。
   - **命名与路由**：SDK 只读取并上报 `SERVER_ID`（来自基类构造入参），严禁 SDK 内部自作主张做包名拼接或命名主权仲裁（属宿主侧职责，§9.3）。

3. **大报文与异步降级兜底**
   - 同步 `call` 超时防线：方法耗时或返回内容较大，优先支持返回 `{"_async": true}` 轻量分支骨架（§1.2.2）。
   - 复杂 `mcp-blob://` 的 `FileProvider` 权限授权穿透标记为 **T-sdk-2** 进阶任务；T-sdk-1 阶段先跑通小报文（< 128KB）纯内存通道（TC9 警戒线）。

4. **独立于 Flutter**：纯 Android 原生（Pure Kotlin + AndroidX），不依赖任何 Flutter 引擎组件。

## 3. 推荐推进节奏

```
[T-sdk-1: 插件端 SDK 骨架 + Dummy APK]
                  │
                  ▼ (产出联调靶子)
[T-trans-2: 宿主端 BinderTransport + 挂起状态机]
                  │
                  ▼ (端到端真机联调跑通)
[T-trans-3 / 4: PackageManager 动态发现与热插拔]
```

## 4. 验收标准

- Gradle `assembleDebug` 通过：`:plugin-core` 产出 `goodhub-mcp-plugin-core.aar`；`:sample-dummy-plugin` 产出可安装 APK。
- `sample-dummy-plugin` 安装后声明 `action="com.zzh.goodhub.action.MCP_SERVER"` + meta-data `SERVER_ID` / `SERVER_TITLE`，可被 GoodHub（T-trans-4 后）自动发现。
- 反射派发器对 `echo` / `add` 生成正确 `tools/list`，`tools/call` 正确路由；业务异常隔离转 `-32603`。
- 作为 **T-trans-2 真机联调靶子**：宿主 `BinderTransport` 可 bind 该 APK 的 Service 并完成 `initialize` / `tools/list` / `tools/call`。

## 5. 落点（与 SSOT 对齐）

- 契约：docs/design/thirdconnect.md §1.2.2（AIDL）/ §1.2.3（Binder 约束）/ §1.2.7（SDK 红线）/ §11（TC14 SDK）。
- 模块位置：仓库内独立 Gradle 工程 `android-sdk/`（`goodhub-mcp-plugin-core` 库 + `sample-dummy-plugin` 应用），**不并入** Flutter `android/` 模块，以免污染宿主构建。AIDL 包名固定 `com.zzh.goodhub.mcp`，放置于 `src/main/aidl/com/zzh/goodhub/mcp/`。

## 6. 实施记录（2026-10-12）

- 落盘独立 Gradle 工程 `android-sdk/`：`:plugin-core`（库）+ `:sample-dummy-plugin`（应用），AGP 9.1.0 / Kotlin 内置（AGP 9 不再需要 `org.jetbrains.kotlin.android` 插件）/ minSdk 34 / compileSdk 35；复用 Flutter `android/` 的 Gradle 9.3.1 wrapper。
- AIDL 契约（§1.2.2）已打进 SDK：`plugin-core/src/main/aidl/com/zzh/goodhub/mcp/IMcpChannel.aidl` + `IMcpCallback.aidl`，包 `com.zzh.goodhub.mcp`，钉死 `call` / `registerCallback` / `answerReverse` / `onEvent`。
- 交付物全部落地：
  1. `GoodHubPluginService`（`IMcpChannel.Stub` server 端基类，仅实现 Stub，不 bind/不持 DeathRecipient）
  2. `@McpTool` / `@Param` 注解
  3. `ToolDispatcher` 运行时反射派发器：生成 `tools/list` Schema + 路由 `tools/call`；业务异常隔离转 `-32603`（§1.2.7）；仅上报 `SERVER_ID`（构造入参，命名不上仲裁）；`_async` 轻量骨架（`@McpTool(async=true)` 立即回 `{"_async":true}`）；< 128KB 纯内存通道
  4. `sample-dummy-plugin`：仅 `echo` / `add` 两工具，Manifest 声明 `action=com.zzh.goodhub.action.MCP_SERVER` + `SERVER_ID` / `SERVER_TITLE`
- 构建验证：`./gradlew :sample-dummy-plugin:assembleDebug` → `BUILD SUCCESSFUL`；产出 `sample-dummy-plugin-debug.apk`（2.4M）+ `goodhub-mcp-plugin-core` AAR。合并 Manifest 已核验契约对齐 §1.2.1。
- 真机联调靶子就位：待 T-trans-2 宿主 `BinderTransport` 实现后，bind 该 APK Service 完成 `initialize` / `tools/list` / `tools/call` 端到端验证。
- 后续：SDK 单测（派发器 / 异常隔离）建议补 `androidTest` 或 host 侧脚本；`mcp-blob://` 大报文与 `_async` 真实投递留 **T-sdk-2**。
