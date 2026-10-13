---
status: active
updated: 2026-10-13
---

# goodshare 本地 Binder 插件 PoC · 阶段一评估报告（goodhub 宿主侧视角）

> 评估对象：goodshare 已实现的 Binder 插件 PoC（改造清单 #1），对照 goodhub 契约 SSOT
> [`thirdconnect.md`](./thirdconnect.md)（TC1~TC14）与 goodhub 宿主侧已实现代码
> （`lib/mcp/transport/binder_transport.dart` + `lib/mcp/local_plugin_discovery.dart` +
> `android/.../BinderTransport.kt` + `MainActivity.kt`）。
> 立场：goodhub 通用宿主，goodshare 走与第三方一致的本地插件通道，不特制适配。
> 本文为**只读评估**：goodshare 代码默认不改；必须修的 bug 仅指出 file:line + 改法，交回 goodshare 侧。

## 0. 结论速览

| 维度 | 结论 |
|---|---|
| goodhub 宿主侧 | **已完整实现并接线**：Dart `BinderTransport`/`LocalPluginDiscovery` + 原生 `BinderTransport.kt`（状态机/挂起队列/5s 冷启/DeathRecipient/后台线程 call/onEvent 主线程桥）+ `MainActivity` 注册 + AIDL 同包 `com.zzh.goodhub.mcp`。`chat_page`/`gateway_controller` 已调 `scan()`+`createClient`。**Phase 2「实现 host」实质已就绪**，剩余=真机验证+挂载 ToolRouter |
| goodshare PoC 契约合规 | AIDL/manifest/Service 与契约**逐条对齐**；`handleJsonRpc` 覆盖 initialize/tools/list/tools/call/resources/prompts/通知/反向响应 |
| 🔴 必须修（goodshare） | **（1）`McpBinderService.call` 的 `resultFuture.get()` 无超时**→ Dart 卡死则宿主 Binder 线程永久挂死；`ai_suggest_tags` 经 Binder 会阻塞 ~90s 违反 §1.2.3。**（2）未声明 `signature` 权限**（§1.2.6 安全闸门缺位） |
| 🟡 真机风险 | 双 isolate 并发开同一 `goodshare.db`（WAL）的「database is locked」竞争；`ready` 等待 10s vs goodhub 冷启 5s 不匹配 |
| 🟢 不在 PoC 范围 | `_async`/sampling-via-Binder（#4/#5 批次）、`resources/subscribe`（Binder 路径未接 `_changesSub`）、PC 网关迁移（#7） |

## 1. 逐条对照 thirdconnect（相关条款）

| 条款/节 | goodshare PoC 状态 | 缺口/风险 | 依据 |
|---|---|---|---|
| §1.2.1 Action+meta-data | ✅ Service 声明 `MCP_SERVER` action + `SERVER_ID=goodshare`/`SERVER_TITLE=GoodShare` | — | goodshare `AndroidManifest.xml:60-72` |
| §1.2.1 `<queries>` | ✅ 声明该 action（Android 11+ 可见性） | — | goodshare `AndroidManifest.xml:90-92` |
| §1.2.2 AIDL 接口 | ✅ `IMcpChannel{call/registerCallback/answerReverse}` + `IMcpCallback.onEvent` oneway，与契约逐字一致 | — | goodshare 两份 `.aidl` vs thirdconnect §1.2.2 |
| §1.2.2 角色边界（§11.3·1） | ✅ 仅实现 Stub；不 bindService/不持 DeathRecipient | — | `McpBinderService.kt:19-24,41` |
| §1.2.3 线程 | ⚠️ goodhub 侧 `submitCall` 在后台线程跑 `ch.call`（不 ANR）✅；但 goodshare 侧 `call` 阻塞 `get()` 无超时（见 §3 Bug1） | 宿主线程合规；插件缺超时 | goodhub `BinderTransport.kt:343-357`；goodshare `McpBinderService.kt:70` |
| §1.2.3 事务大小 | ⚠️ 大结果（get_item 图片 4MB）仍走 String 回传，Binder 事务上限风险——但属 #3 批次（mcp-blob），PoC 未含 | 已知、非 PoC 阻塞 | goodshare eval #3 |
| §1.2.3 调用预算 <5s | ❌ `ai_suggest_tags` 同步采样 90s；PoC 未实现 `_async` → 经 Binder 会阻塞 | 必须改（#4/#5）或 PoC 联调禁用该工具 | `mcp_server.dart` `_dispatch` tools/call 无 sampling 回调 |
| §1.2.4 发现 | ✅ goodhub `scanLocalPlugins()` 扫描 action+读 meta-data+签名；goodshare 声明齐全 | — | goodhub `BinderTransport.kt:157-189` |
| §1.2.5 随调随起 | ✅ `BIND_AUTO_CREATE` + `onCreate→initEngine`（headless FlutterEngine） | 冷启延迟：headless 引擎 ~数百 ms~2s，`ready` 等待 10s vs 宿主 5s 超时（§3 Bug1 备注） | goodshare `McpBinderService.kt:96-136` |
| §1.2.6 鉴权/签名 | ⚠️ 走同签名零弹窗前提=两 app 同签名；PoC 未声明 `signature` 权限+goodhub 未持 uses-permission→当前任何 app 可 bind（exported） | 安全闸门缺位（§3 Bug2） | 两边 Manifest 均无该权限声明 |
| §2 initialize | ✅ 返回 protocolVersion/capabilities/serverInfo/instructions | — | `mcp_server.dart:296-308` |
| §3 命名前缀 | ✅ goodshare 暴露裸名；goodhub `ToolRouter` 加/剥 `goodshare__` 前缀（宿主侧已做） | — | goodhub `tool_router.dart`（前缀路由） |
| §4 发现/激活（宿主内） | ✅ JIT 元工具/系统托管端点由 goodhub 负责，goodshare 无需实现 | — | goodhub `local_plugin_discovery.dart` |
| §5 反向请求/进度 | 🟡 通道已通（pushEvent→onEvent→answerReverse 接线存在），但工具侧 `_async`+sampling 帧未发（#4/#5） | PoC 仅连通管道，未端到端 | goodshare `McpBinderService.kt:115-126,87-93`；`mcpBinderMain` answerReverse |
| §9.1 冷启动状态机 | ✅ 宿主侧 IDLE→CONNECTING→READY→DEAD + 挂起队列 + **5s 冷启超时** + rebind，全部实现 | — | goodhub `BinderTransport.kt:223-401` |
| §9.3 命名碰撞 | ✅ 宿主以 packageName 物理主键，sameSignature 标记 | — | goodhub `BinderTransport.kt:142-152,174` |
| §10.1 TC9 数据面 | ⏸️ mcp-blob 降级属 #3 批次，PoC 未含 | 已知 | goodshare eval #3 |
| §11 TC14 SDK | 🟡 goodshare 手搓 AIDL（SDK 未交付），契约对齐但建议后续迁 `@McpTool`（#2） | 非阻塞 | goodshare eval #2 |
| TC10/11/12/13 | 属 goodhub 网关/架构侧，与插件 PoC 无直接接口依赖 | — | — |

## 2. 重点评估（用户指定四项）

### 2.1 headless 引擎→第二 Dart isolate + 双 Repository + sqlite WAL 安全性
- **事实**：`mcpBinderMain()` 起独立 `FlutterEngine`+独立 `Repository()`+`McpServer`（与 MainActivity 主 isolate 各一套）。两 isolate 各自 `openDatabase('goodshare.db')` → **两个独立原生 SQLite 连接指向同一 WAL 文件**。
- **风险（🟡 真机验证）**：WAL 允许多读+单写；但两个*独立连接*并发写会争写锁，超 `busy_timeout` 抛 `SQLiteDatabaseLockedException`/"database is locked"。goodshare eval §2 称「WAL 下安全」偏乐观——WAL 不消除跨连接写竞争。
- **验证项**：真机联调时让 goodshare UI 与 Binder 调用**并发写**（UI 加 item + 同时 MCP `add_item`/`get_item`），抓 goodshare logcat 看是否报 locked。
- **缓解建议（交 goodshare）**：binder isolate 走读为主；或全仓 DB 访问经单 isolate actor 串行化；或 sqflite 打开时显式 `singleInstance`/提高 busy_timeout。

### 2.2 随调随起（app 被杀后被 bindService 拉起）是否真成立
- **机制成立**：`BIND_AUTO_CREATE` + Service `onCreate→initEngine→executeDartEntrypoint(mcpBinderMain)`。进程被杀后 goodhub 下次 `call`→状态机 DEAD→`startBind`→系统重建进程并拉起 Service。✅
- **但有两点摩擦**：
  1. headless FlutterEngine 冷启有真实延迟（插件注册全量跑），首调需等 `ready`。
  2. `ready` 内部等待 **10s**（`McpBinderService.kt:44`），而 goodhub 冷启超时 **5s**（`BinderTransport.kt:54,296-310`）→ 首调在 5s 被 goodhub 判 DEAD+failPending，goodshare 仍在等；好在 goodhub DEAD→下次 send 自动 rebind，二次调用自愈。功能不阻塞，但首调必败一次。
- **建议**：goodshare 把 `ready` 等待收紧到 ≤5s（或 goodhub 冷启超时上调）；并以真实设备测「force-stop 后首调自愈」。

### 2.3 call 阻塞 Binder 线程的超时与并发边界
- **宿主侧（goodhub）已合规**：`submitCall` 在 `executor` 后台线程跑 `ch.call`（`BinderTransport.kt:343-357`），主线程不被 `call` 阻塞→不 ANR。并发请求进 `pending` 队列，READY 后按序 `submitCall`（每个独立 executor 任务），多插件/多调用不互相卡。✅
- **插件侧（goodshare）致命缺口**：`McpBinderService.call` 的 `resultFuture.get()` **无超时**（`McpBinderService.kt:70`）。若 Dart `handleJsonRpc` 因任何原因不回（工具死锁、引擎异常），该 Binder 线程**永久阻塞**，对应请求 future 永不完成。且 `ai_suggest_tags` 经 Binder 会同步阻塞 ~90s（sampling 超时），直接违反 §1.2.3 的 <5s。
- **必改**（见 §3 Bug1）：给 `resultFuture.get()` 加超时（建议 5s 对齐预算），超时返回标准 JSON-RPC error（带 id）而非挂死；长工具必须走 `_async`。

### 2.4 meta-data 读取方式
- **职责在宿主**：goodshare 仅在 Manifest 声明 `SERVER_ID/TITLE`；读取由 goodhub `scanLocalPlugins()` 经 `PackageManager.GET_META_DATA` 完成（`BinderTransport.kt:166-182`），并附签名 SHA-256 + `sameSignature`。goodshare 不自读自身 meta-data，分工正确，无问题。✅

## 3. goodshare 必须修的 bug（只读提议，不直接改）

### Bug1（🔴 致命，宿主稳定性）— 无 per-call 超时
- 文件：`android/app/src/main/kotlin/com/zzh/goodshare/McpBinderService.kt`
- 位置：`call()` 内 `val result = resultFuture.get()`（约 line 70）；及 `ready` 等待 `completeFutureOrDefault(false, 10, ...)`（line 44）。
- 现象：Dart 不回→宿主 Binder 线程永久挂死；`ai_suggest_tags` 阻塞 ~90s 违反 §1.2.3。
- 改法：
  1. `resultFuture.get(5, TimeUnit.SECONDS)`（对齐 §1.2.3 预算），catch `TimeoutException` → 返回带 id 的 JSON-RPC error（`{"jsonrpc":"2.0","id":<请求id>,"error":{"code":-32000,"message":"MCP Binder call timeout"}}`）——需先从 `jsonRpcRequest` 解析 `id` 再回显。
  2. `ready` 等待从 10s 收紧到 ≤5s（或保留 10s 但文档化「首调可能由宿主 5s 超时触发 rebind」）。
  3. 根本解：在 `mcp_server.dart` 的 `tools/call` 对长工具立即回 `{"result":{"_async":true}}` 并经 `onEvent` 推终帧（#4/#5 批次），使 `call` 永远秒回。

### Bug2（🟠 安全闸门，§1.2.6）— 未声明 signature 权限
- 文件：goodshare `AndroidManifest.xml`（Service 块 60-72）+ goodhub `AndroidManifest.xml`。
- 现象：Service `exported=true`+公开 action，**未**加 `android:permission="com.zzh.goodhub.permission.MCP_SERVER"`（signature），goodhub 也无 `<uses-permission>`。当前任何 app 可 bind。
- 改法（双方）：
  - goodshare 新增 `<permission android:name="com.zzh.goodhub.permission.MCP_SERVER" android:protectionLevel="signature"/>`，并在 Service 上加 `android:permission="com.zzh.goodhub.permission.MCP_SERVER"`。
  - goodhub `AndroidManifest.xml` 加 `<uses-permission android:name="com.zzh.goodhub.permission.MCP_SERVER"/>`。
  - 注意：两 app 必须**同签名**发布（debug keystore 同机一致即可），否则 `sameSignature=false` 走信任卡片分支（PoC 暂无该 UI，需补或暂以签名对齐兜底）。
- 优先级：PoC 联调不阻塞（exported 仍可 bind），但上线前必须补。

### Bug3（🟡 轻微，可观测性）— error 帧 id 恒 null
- 文件：`McpBinderService.kt` `errorJson(id=null,...)`（line 157-158）；`mcp_server.dart` 解析失败分支 `_rpcError(null,...)`（line 373,376）。
- 改法：基础设施错误也尽量回显请求 id（先 `jsonDecode` 取 `id`），便于 goodhub 关联/排障。低优先级。

### 范围外（非 bug，PoC 设计如此，联调须规避）
- `tools/call` 经 Binder **不要**调 `ai_suggest_tags`/任何 sampling 工具，直到 #4/#5 实现 `_async`+onEvent 帧，否则 ~90s 阻塞。
- `resources/subscribe`+变更推送在 Binder 路径不生效：PoC 构造 `McpServer` 未调 `start()`，故 `_changesSub` 未接（`mcp_server.dart:54`）。Tier-1 资源通知需后续接。

## 4. 真机联调 checklist（Phase 1→2，CPH2767 已在线）

**前置（构建/安装）**
1. 同机 `flutter build apk --debug` 出 goodshare-debug.apk（已出）与 goodhub-debug.apk（含 BinderTransport，本会话已构建）；确认两包**同 debug keystore 签名**→`sameSignature=true`。
2. `adb -s 3B161700Y0600000 install -r` 两包；goodshare 至少启动过一次（初始化 DB）。

**发现与绑定**
3. 启动 goodhub→`MainActivity` 注册 `BinderTransportBridge`；进入触发 `localPluginDiscovery.scan()` 的页（聊天页或网关调试页）。
4. 抓 goodhub logcat 确认 `scanLocalPlugins` 返回 `serverId=goodshare / packageName=com.zzh.goodshare / sameSignature=true`。
5. 触发 bind：goodhub `BinderTransport` 构造即 `bind`→`HostTransport.startBind`→`bindService(BIND_AUTO_CREATE)`；logcat 看 `onServiceConnected`→`registerCallback`→state READY。

**协议走通（重点：只用短工具）**
6. `initialize` → 期望 `protocolVersion: 2025-06-18` + `capabilities` + `serverInfo.name=goodshare`。
7. `tools/list` → 期望 goodshare 裸名工具（goodhub 前缀为 `goodshare__`）。
8. `tools/call list_items`（短工具）→ 期望 content；**禁调 `ai_suggest_tags`**（见 Bug1/范围外）。
9. 抓双向 logcat 留证。

**随调随起验证**
10. `adb shell am force-stop com.zzh.goodshare` → 再次从 goodhub 发 `tools/list`：bindService 应重建 goodshare 进程并应答（验证 §1.2.5/§2.2）。

**WAL 并发验证（§2.1 风险）**
11. goodshare 前台交互（加一条 item）同时 goodhub 发 `add_item`/`get_item`，盯 goodshare logcat 是否 `database is locked`。

**签名闸门（Bug2，上线前）**
12. 验证无 signature 权限时仍能 bind（PoC 现状）；记录上线前需补权限（步骤 3 双方 Manifest）。

## 5. goodhub 侧 Phase 2 剩余（host 已就绪，待收尾）

- **挂载 ToolRouter**：`gateway_controller.dart:117-130` 已 `createClient(info)` 并迭代，需真机确认 goodshare 工具真正进 `ToolRouter` 且可经聊天任务调用（不止连通性）。
- **签名权限**：goodhub `AndroidManifest.xml` 加 `<uses-permission android:name="com.zzh.goodhub.permission.MCP_SERVER"/>`（配合 goodshare Bug2）。
- **节点卡 UI 缺口**：T5「Server 节点」面板只列手填远端端点，**不覆盖本地插件**（前文断点 §4.3）。goodshare 自动挂载后无对应节点卡可视——功能已通但 UI 不可见，需评估是否补本地插件节点卡（在线点/延迟/工具计数/鉴权态）。
- **结果回写**：联调结果（通过/卡点）回 goodshare 侧 `goodshare-goodhub-local-plugin-eval.md` 与 `context/epics/goodhub-local-plugin/devlog.md`（追加 `[验证]` 行）。

## 6. 阶段一裁决

- **PoC 契约合规、可进真机联调**；但 **Bug1（per-call 超时）建议联调前修**，否则 `ai_suggest_tags`/异常路径会挂死宿主线程；其余为后续批次或上线前项。
- goodhub 宿主侧实现完整度超预期（thirdconnect「规划」标注滞后于实际代码），Phase 2 重心从「写 host」转为「真机验证 + 收尾（挂载/权限/节点卡 UI）」。
