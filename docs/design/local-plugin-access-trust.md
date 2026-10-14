---
status: active
updated: 2026-10-14
---

# 本地插件接入规范：私有插件 vs 第三方插件（信任分级 SSOT）

> 定位：GoodHub 本地 Binder 插件（同机零端口）的**接入与信任分级规范**。把插件按信任来源分两类——**私有插件（同签名生态）**与**第三方插件（信任卡片白名单）**——分别给出接入方清单与宿主侧行为。传输/AIDL/协议细节 SSOT = [`thirdconnect.md`](./thirdconnect.md)（§1.2）；本文只立「谁来接、怎么信、怎么管」。
> 实现 SSOT：`android/.../BinderTransport.kt`（扫描+指纹提取）、`lib/mcp/local_plugin_discovery.dart`（`LocalPluginInfo`）、`lib/mcp/trusted_plugins.dart`（白名单持久化）、`lib/ui/trust_plugin_dialog.dart`（信任卡片）、`lib/ui/chat_page.dart` ⚙ 设置（信任管理面）、`lib/gateway/gateway_controller.dart`（网关侧闸门）。

---

## 0. 两类插件的判定与总差

宿主 Kotlin 层扫描插件时提取其签名证书 SHA-256，与宿主自身签名集合比对：

- **私有插件**：`sameSignature = true`（插件签名与 GoodHub 同证书）→ **零弹窗自动信任**，不走白名单。
- **第三方插件**：`sameSignature = false`（含指纹缺失——未取到签名一律按第三方，严禁假阳）→ 首次接入弹**信任卡片**，确认后包名入白名单持久化，后续自动信任。

| 维度 | 私有插件（同签名） | 第三方插件 |
|---|---|---|
| 信任判定 | 宿主签名集比对，零人工 | 信任卡片人工确认（包名 + SHA-256） |
| 首次接入 | 零弹窗直接挂载 | 弹卡；拒绝/关闭 → 不挂载，可稍后 ⚙ 再开 |
| 持久化 | 不入白名单 | `SharedPreferences` 白名单（`goodhub.trusted_plugins`） |
| 撤销 | 不适用（换签名即失效） | ⚙ 设置面板开关撤销 |
| 网关 headless 场景 | 自动挂载 | 未信任则跳过（`[DEGRADE]` 留痕），信任后下次装配生效 |
| 权限模型 | 插件声明 `signature` 权限，宿主 `<uses-permission>` 请求 | 公开 Action，无 signature 门槛，全靠信任卡片 |

## 1. 宿主侧信任闸门（运行时行为，钉死）

1. **发现**：`BinderTransport.scanLocalPlugins()` 经 `PackageManager.queryIntentServices` 扫描（`MATCH_CURRENT_USER`，thirdconnect §9.4），对每个插件产出 `LocalPluginInfo`：`serverId / serverTitle / packageName / serviceClassName / signatureSha256 / sameSignature`。`transportId = local:<pkg>_<serverId>`。
2. **判定严格性**：`sameSignature` 仅布尔 `true` 生效；`signatureSha256` 取不到 → 空串且按第三方。脏数据（字符串 `"true"` 等）不得当作同签名（防绕过信任卡片，单测锁定）。
3. **挂载闸门**（聊天页装配与网关装配同口径）：`sameSignature || trusted.isTrusted(pkg)` 才挂载。第三方未信任 → 聊天页弹信任卡片；网关（无 UI）headless 跳过并 `[DEGRADE]` 日志，不阻塞其余插件。
4. **信任卡片**：展示插件名、包名、签名 SHA-256（monospace 指纹）；「信任并挂载」→ `TrustedPlugins.add(pkg, sha, title)` 持久化（含指纹/展示名/时间，供审计与撤销）。
5. **管理面**：⚙ 设置面板列出全部已发现插件；同签名项开关置灰锁定（不可撤销同签名信任）；第三方项可勾选/撤销，撤销即下次装配摘除。
6. **审计**：信任/撤销操作进 `ops.log` 留痕；命名冲突仲裁按 thirdconnect §9.3（PackageName 物理主键、冲突降级、禁静默覆盖）——**与信任分级正交**：冲突降级不改变信任状态。
7. **per-plugin 挂载开关（预留，未实现）**：现状装配为「全量扫描 + 信任闸门过滤」，无单插件挂载开关；远端节点已有 M4-T5 `enabled` 口径（`ServerEndpointStore` + `_send` 装配过滤）。本地插件对齐该语义：`LocalPluginInfo` 增开关位（同签名也可摘）→ 聊天页 ⚙ 开关 → 装配与网关两处闸门加 `enabled` 过滤 → 摘除后向 PC 下行 `tools/list_changed`（§6 机制复用）。落地前，定点操作单插件走前缀路由（`tools/call` 带 `<server_id>__<tool>`）、JIT `activate_server_tools(server_id)` 与 **`use_server(server_id)`（已实现，2026-10-14）**——聚焦独占指定服务，聚焦面经 `ToolRouter.focusedSchemas()` 下发，传 `all` 恢复全量。

## 2. 接入后的最低服务义务（钉死）

> 信任闸门通过≠接入完成。插件挂载后必须在 AIDL 通道上正确应答以下 JSON-RPC 方法，否则视为**不合格插件**（工具面为空/调用报错）。协议细节 SSOT = thirdconnect §1.2.2/§2/§3。

### 2.1 必须实现（M0 底线，缺一不可）

| 能力 | 要求 | 违约后果 |
|---|---|---|
| `initialize` 应答 | 在 `IMcpChannel.call` 内返回 `capabilities` + `serverInfo`（`name`/`version`，可选 `instructions`） | 无法完成能力协商，挂载失败 |
| `tools/list` 应答 | 返回标准 MCP 工具数组，**裸名**（严禁自带 `__` 前缀，宿主自动加 `<server_id>__<tool>`），每个工具带合规 `inputSchema`（JSON Schema） | 工具面为空 = 白挂载 |
| `tools/call` 应答 | 返回标准 MCP content 信封；异常转 JSON-RPC error（建议 `-32603`），**不得**让异常跨 Binder 击穿宿主，也**不得**把传输层错误伪装成业务 error | 调用报错/宿主异常 |
| JSON-RPC 2.0 合规 | 请求/响应/通知均为合法 JSON-RPC 2.0 帧，`id` 关联正确 | 分帧解析失败 |

### 2.2 必须遵守的运行时红线（与 thirdconnect §1.2.3 / §10 同源）

- **`>5s` 长任务走 `_async`**：`call` 内立即回 `{"result":{"_async":true}}`，真实结果稍后经 `onEvent` 推同 `id` 终帧；严禁同步阻塞越 Binder 预算（ANR）。
- **`≥128KB` 大结果走 `mcp-blob://<pkg>/<path>` 句柄**：严禁直接回传大 String（Binder 1MB 事务上限）；严禁 `$ref://` 等非标前缀。
- **线程与事务**：`call` 派发后台线程；单条请求+响应 < 512KB。
- **工具命名不含 `__`**：`server_id` 与工具名各段自身不得含双下划线（前缀路由分隔符）。

### 2.3 可选能力（按需声明，声明即须兑现）

| 能力 | 声明方式 | 兑现义务 |
|---|---|---|
| Tier 1 全量接缝 | `capabilities` 同时声明 `prompts` + `resources` | Skill 模板注入 + 只读资源面须真实可用（仅 `tools` = Tier 2，宿主 Polyfill 接管，无额外义务） |
| 进度上报 | `tools/call` 接受 `progressToken` | 经 `onEvent` 推 `notifications/progress`；宿主原生层 200ms 节流兜底，不推则纯 Loading 态 |
| 反向采样 | 推 `sampling/createMessage` 反向请求 | 按 `id` 经 `answerReverse` 闭环收答；不实现则不推该帧 |
| 任务源（高阶） | 额外实现任务协议 | claim/apply + `$ref` 句柄，SSOT = goodshare 仓 `ai-app-split.md`；非纯 MCP 工具服务范畴 |

> 宿主侧自动提供、插件**不用做**：前缀加/剥、JIT 激活元工具、L1/L2 权限卡、PII 围栏、审计、热插拔发现（thirdconnect §3 / goodshare-local-plugin-eval §3）。

## 3. 私有插件接入清单（goodshare 等同签名生态）

1. **声明权限（插件侧）**：插件自声明 `<permission android:name="com.zzh.goodhub.permission.MCP_SERVER" android:protectionLevel="signature" />` 并在 Service 上 `android:permission=...`（宿主**只请求不自声明**，#9 §3）。
2. **声明 Service**：`exported="true"` + `action="com.zzh.goodhub.action.MCP_SERVER"` + meta-data `SERVER_ID` / `SERVER_TITLE`（thirdconnect §1.2.1）。
3. **实现 AIDL 契约**：`IMcpChannel` / `IMcpCallback` 按 thirdconnect §1.2.2（建议走 `goodhub-mcp-plugin-core` SDK，§11）；遵守 §1.2.3 Binder 红线（离主线程、<512KB、长任务 `_async`、`mcp-blob://`）。
4. **签名一致**：用与 GoodHub 相同的签名证书打包——同签名判定即由此而来，无任何额外代码。
5. 安装即被自动发现、零弹窗挂载；Release 不暴露任何 HTTP 端口。

> CI 门禁：`test/mcp/local_plugin_manifest_gate_test.dart` 锁宿主 Manifest 前置（`<uses-permission>` + `<queries>` 声明、不自声明 `<permission>`）——误删即红灯，防止真机 e2e 才晚失败。

## 4. 第三方插件接入清单

1. **声明 Service**：同 §3 第 2 条（`exported` + 公开 Action + meta-data）。**无需** signature 权限（任何 App 均可声明，安全完全靠信任闸门，TC4）。
2. **实现 AIDL 契约**：同 §3 第 3 条；强烈建议走 SDK，AIDL/路由/Schema/1MB 降级/异常隔离全部透明化。
3. **用户侧流程（无需插件做任何事）**：安装后 GoodHub 扫到 → 首次使用弹信任卡片（包名 + SHA-256）→ 用户确认 → 入白名单 → 挂载生效。网关场景须先在聊天页/⚙ 完成信任。
4. **可撤销**：用户随时在 ⚙ 撤销，插件摘除；再启用重新弹卡。
5. **SDK 红线（对齐 thirdconnect §1.2.7 / §11.3）**：SDK 不持安全闸门、命名不上仲裁、URI 仅 `mcp-blob://`、`>5s` 自动 `_async`。

## 5. 边界与不做的事

- **指纹缺失不放行**：取不到签名的插件按第三方走卡片，绝不按私有（安全回归红线，单测锁定）。
- **白名单按包名，不按 SERVER_ID**：`SERVER_ID` 仅展示/路由前缀；包名换签名 = 需重新信任（白名单键是包名，指纹更新在 `add` 时覆盖）。
- **同签名不可手动撤销**：信任源是系统签名校验，⚙ 开关置灰；要「不信任」只能卸载插件。
- **跨 User / 双开**：v1 仅当前 `UserHandle` 可见（§9.4），不穿透。
- **远端 HTTP 服务不受本文管**：走 `X-Api-Key` 手填配置（thirdconnect §1.1/§8.1），无信任分级。

---

## 6. 卸载与热更新生命周期

> 宿主 `BinderTransport` 注册 `PACKAGE_ADDED` / `PACKAGE_REMOVED` / `PACKAGE_REPLACED` 三广播（data scheme `package`），触发 `notifyPluginsChanged()`。这是插件「装完不用重启」的机制底座。

- **安装即挂载**：`PACKAGE_ADDED` → 重新扫描，新插件按 §1 闸门（同签名直接挂；第三方弹卡/网关跳过）进入装配。
- **卸载即摘除**：`PACKAGE_REMOVED` → 目录移除 + Binder 断连（`DeathRecipient` 感知）；白名单条目**保留不删**（重装同签名包自动恢复信任）。
- **更新（`PACKAGE_REPLACED`）**：重新扫描并重做三件事——① `SERVER_ID` 冲突重仲裁（§9.3）；② 指纹更新：白名单 `add` 以最新 SHA-256 覆盖；③ **换签名的更新**视为新来源：私有换签名 → 降级为第三方走信任卡片，第三方换签名 → 需重新确认（指纹比对口径见 §5）。
- **Schema 热同步**：插件目录刷新后，网关向 PC 主动下行 `notifications/tools/list_changed`（thirdconnect §9.2，G1~G5），防止 PC 缓存滞后误调已删工具。
- **运行中断连**：插件进程被杀/崩溃 → `DeathRecipient.binderDied` 标记离线，下次调用 `BIND_AUTO_CREATE` 自动 rebind（thirdconnect §1.2.3 / §9.1），上层无需干预。

## 7. 协议与 SDK 版本兼容

- **MCP 协议版本**：统一 `2025-06-18`（`kMcpProtocolVersion`）。`initialize` 应答的 `protocolVersion` 与宿主不一致 → 挂载失败 + `ops.log` 留痕，**严禁静默按旧版本硬连**。
- **AIDL 契约版本**：`IMcpChannel`/`IMcpCallback` 方法签名即契约，变更必须 SDK 升版且向下兼容（thirdconnect §11.5）；宿主按方法存在性探测（`asInterface` 后调用失败即判定契约不符，摘除该插件而非崩溃）。
- **SDK 版本绑定**：`goodhub-mcp-plugin-core` 版本绑定 MCP 协议版本 + AIDL 契约版本；插件侧禁止绕过 SDK 直改 AIDL 私加方法（宿主不识别的额外方法不影响，但不得改变既有方法语义）。
- **降级策略**：新宿主遇旧插件——旧插件未实现的新能力（如 progressToken）按「声明即须兑现」反推：没声明就没义务，宿主走 Polyfill/Loading 兜底（§2.3）；旧宿主遇新插件——宿主忽略不认识的 capabilities 字段，不拒绝挂载。

## 8. 第三方插件验收与调试

### 8.1 接入前验收 checklist（发布前逐项自测）

1. 真机 e2e：安装 → 自动发现 → （第三方）信任卡片 → 工具面出现在列表。
2. `tools/list` 返回裸名 + 合规 `inputSchema`；无空 schema 工具。
3. `tools/call` 正常路径 + 业务异常路径（返回 JSON-RPC error，不崩宿主）。
4. 红线自测：构造 `>5s` 工具验证 `_async` 终帧回推；构造 `≥128KB` 返回验证 `mcp-blob://` 句柄可被宿主解包。
5. 声明的可选能力逐项兑现（§2.3：声明了 prompts/resources/sampling 就要有真实实现）。
6. 卸载/重装/更新各走一遍（§6 生命周期不残留死状态）。

### 8.2 常见接错排查表

| 症状 | 首查点 |
|---|---|
| 工具面为空（挂载了但没工具） | `tools/list` 未实现/返回格式错；`SERVER_ID` meta-data 缺失（空 id 直接跳过，gateway_controller 同口径） |
| 信任卡片不出现 | 插件被误判同签名？检查打包签名是否与宿主相同；反之调试期绕卡片：先在 ⚙ 手动信任 |
| 网关场景工具缺失 | headless 无 UI 弹卡：未信任第三方插件被跳过（`[DEGRADE]` 日志），先在聊天页信任 |
| 调用 ANR/超时 | `call` 阻塞主线程或超 5s 未回 `_async`（§2.2） |
| `TransactionTooLarge` | 大结果未走 `mcp-blob://` 句柄（§2.2） |
| bind 抛 SecurityException | 私有插件漏声明 `<uses-permission>`/`<queries>`（宿主侧 CI 门禁已锁，插件侧 Service 权限名须一致） |

## 9. 威胁模型与安全边界

- **SERVER_ID 伪造/重名劫持**：恶意插件声明他人 `SERVER_ID` 抢工具面。对策 = thirdconnect §9.3：PackageName 物理主键、同签名优先、冲突强制降级后缀、禁静默覆盖 + `ops.log` 留痕。信任分级不解决命名主权，两者正交。
- **工具面注入（prompt injection）**：恶意工具描述/工具结果经 AgentLoop 进入模型上下文，诱导调用危险工具。对策纵深 = 工具描述不进系统提示、L1/L2 权限网关（写操作必须人工确认，读操作双源裁决未知从严）、PII 出站围栏、`hop_count > 2` 防环熔断（thirdconnect §9.5）。**插件不可绕过网关直接触达模型**。
- **未信任插件经 PC 网关透出**：网关装配 headless 跳过未信任第三方插件（§1.3），PC 侧永远看不到未确认工具——不存在「PC 远程触发首次信任」路径。
- **指纹误信**：信任卡片展示 SHA-256 monospace 全指纹，供用户与插件发布方核对；宿主不以指纹前缀/截断做任何自动判定。
- **白名单持久化面**：白名单存 SharedPreferences（非加密目录），泄漏影响 = 攻击者可预置信任条目，但**指纹写入以 `add` 时实扫为准**，包名+签名双匹配才放行，预置条目无法伪造未安装包。



### 附：实现落点

| 规范条款 | 实现位置 |
|---|---|
| 扫描 + 签名 SHA-256 提取 + 同签名判定 | `BinderTransport.kt`（`scanLocalPlugins` / `ownSignatureSha256` / `sha256Hex`） |
| 指纹字段 Dart 解析 / `transportId` | `lib/mcp/local_plugin_discovery.dart`（`LocalPluginInfo`） |
| 信任白名单持久化 | `lib/mcp/trusted_plugins.dart`（`TrustedPlugins`） |
| 信任卡片 UI | `lib/ui/trust_plugin_dialog.dart`（`showTrustCard`） |
| 聊天页装配闸门 + ⚙ 信任管理面 | `lib/ui/chat_page.dart` |
| 网关 headless 闸门（未信任跳过 + DEGRADE） | `lib/gateway/gateway_controller.dart` |
| Manifest 前置 CI 门禁 | `test/mcp/local_plugin_manifest_gate_test.dart`；指纹解析锁定 `test/mcp/local_plugin_signature_test.dart` |
| 传输/AIDL/协议细节（SSOT） | `docs/design/thirdconnect.md` §1.2 / §9 / §11 |
| 包安装/卸载/替换广播（§6 生命周期） | `BinderTransport.kt`（`packageChangeReceiver` ADDED/REMOVED/REPLACED → `notifyPluginsChanged`） |
| `tools/list_changed` 下行（§6 Schema 热同步，规划） | 网关下行通道（G1~G5，thirdconnect §9.2） |
| 协议版本常量（§7） | `kMcpProtocolVersion`（`lib/mcp/mcp_client.dart`）；SDK 版本绑定 thirdconnect §11.5 |
| `use_server` 聚焦元工具（§1.7 替代方案） | `lib/coordinator/discovery_executor.dart` + `ToolRouter.focusedServer/focusedSchemas`（独占守卫）；单测 `test/coordinator/discovery_executor_test.dart` |
| 真机 e2e（§8.1） | `integration_test/goodshare_toolrouter_e2e_test.dart`；Manifest/指纹门禁 `test/mcp/local_plugin_manifest_gate_test.dart` + `local_plugin_signature_test.dart` |
