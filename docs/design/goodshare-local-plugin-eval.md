---
status: active
updated: 2026-10-13
---

# goodshare 接入本地插件机制 · 评估文档（goodhub 宿主侧契约对照）

> 用途：goodshare 当前仍作为 **HTTP MCP server**（`:<port>/mcp`）被 goodhub 远端配置接入。本文供 goodshare 侧评估「改造为 goodhub **本地 Binder 插件**（同机零端口、系统自动发现）」所需工作与风险。goodhub 侧契约唯一 SSOT = [`thirdconnect.md`](./thirdconnect.md)（已对齐 TC1~TC14）；任务源高阶协议 SSOT 在 goodshare 仓 `docs/design/ai-app-split.md`。
> 立场：goodhub 是**通用 MCP 宿主**，不针对 goodshare 特制适配；goodshare 走的是与 todo 等第三方一致的「本地插件」通用通道。

## 1. 现状 vs 目标

| 项 | 现状（HTTP MCP server） | 目标（本地 Binder 插件） |
|---|---|---|
| 接入类 | 远端服务（Streamable HTTP，手动填 `id/endpoint/token`） | 本地插件（Binder/AIDL，零网络） |
| 端口 | 监听端口 | **Release 绝对零端口** |
| 发现 | ⚙ 手填端点，存 `ServerEndpointStore` | 系统级自动发现、零配置热插拔 |
| 鉴权 | `X-Api-Key` 请求头 | 同签名 `signature` 权限，零弹窗 |
| 生命周期 | 常驻监听，与 activity 耦合（历史 T7 实测） | 平时休眠、随调随起 |

> 注意：goodhub 节点卡面板的「Server 节点」分区**只列手填的远端 HTTP 端点**；本地插件自动挂载**不进该清单**（面板空态文案已写明「本地插件自动挂载不在此列」）。goodshare 改本地插件后，将走自动发现通道而非这张手填卡。

## 2. goodshare 必须实现的清单（对照 `thirdconnect.md §1.2`）

### 2.1 声明与元数据（§1.2.1）
- `AndroidManifest.xml` 声明 `exported` Service + `action="com.zzh.goodhub.action.MCP_SERVER"`。
- meta-data：`com.zzh.goodhub.SERVER_ID`（如 `goodshare`）、`com.zzh.goodhub.SERVER_TITLE`（如 `GoodShare`）。
- Android 11+ 在 `<queries>` 声明该 action，否则收不到 `PACKAGE_ADDED/REMOVED` 广播（§1.2.4 发现）。

### 2.2 AIDL 通道（§1.2.2，钉死契约）
- `IMcpChannel`：`String call(String jsonRpcRequest)`（同步 JSON-RPC，用于 `initialize/tools/list/tools/call/resources/*/prompts/*`），及 `registerCallback` / `answerReverse`。
- `IMcpCallback`：`onEvent(String jsonRpcMessage)`（插件 → GoodHub 单向事件，进度/反向请求）。
- AIDL 包名固定 `com.zzh.goodhub.mcp`。
- **接入 SDK 透明化（§1.2.7 / TC14）**：goodhub 提供 `goodhub-mcp-plugin-core`（独立仓 `loveheng/goodhub-mcp-sdk`，Maven 坐标 `com.zzh.goodhub.mcp:goodhub-mcp-plugin-core`），goodshare 只需 `@McpTool` 注解 + 可选 `@McpTool(timeout=...)`，AIDL/路由/异常对 goodshare 透明。**优先走 SDK，不要手搓 AIDL。**

### 2.3 Binder 调用约束（§1.2.3，红线）
- 线程：`channel.call` 必须派发到后台线程（Kotlin `Dispatchers.IO`）；主线程同步 `call` 超 5s 触发 ANR。
- 事务大小：单进程 Binder 缓冲约 **1MB**，单条 `call` 请求+响应建议 **< 512KB**；大 `resources/read`/批量改返回内容 URI / `ParcelFileDescriptor`。
- 调用预算：`call` 应 **< 5s** 返回；更长 → 走 `_async`（立即回 `{"_async":true}`，真实结果稍后由 `onEvent` 推同 `id` 终帧）。
- 错误映射：崩溃/Binder 断连 → `DeadObjectException`/`RemoteException` → GoodHub 自动 rebind，传输层错误不得伪装成 JSON-RPC error。

### 2.4 反向请求（§1.2.2 / §4）
- 插件在 `onEvent` 推 `sampling/createMessage` → GoodHub 处理后经 `answerReverse` 回；按 `id` 关联。goodshare 现有采样逻辑需迁移到该闭环。

### 2.5 鉴权（§1.2.6）
- 同签名生态用 `<permission protectionLevel="signature">`，零弹窗。
- 仅当开放第三方时，首次接入走信任卡片（包名 + 签名 SHA-256）白名单。goodshare 作为宿主自家插件，走同签名即可。

### 2.6 任务源协议（§6，可选高阶）
- 若 goodshare 仍要 goodhub **认领并 apply 任务**（claim/apply + `$ref` 句柄），需实现任务协议，SSOT 在 goodshare 仓 `ai-app-split.md`。
- goodhub 侧 `$ref` 句柄 put 端按调用目标 server 解析（`ToolRouter.serverFor`），goodshare **无需关心工具名前缀**。

### 2.7 大结果 URI 降级（§1.2.7 / TC9）
- 统一 `mcp-blob://<pkg>/<path>`，**严禁** `$ref://` 等非标前缀。

## 3. goodhub 自动提供（goodshare 不用做）

- 系统级自动发现、零配置热插拔挂载。
- 工具名前缀 `<server_id>__<tool>` 自动加/剥，goodshare 暴露**裸名**即可。
- 未激活服务拦截 + `activate_server_tools` JIT 元工具。
- 网关聚合（`:8766`）对外暴露时，goodshare 工具随本地前缀聚合进 PC 单入口（goodshare 自身不监听端口）。
- 权限卡 L1/L2、PII 过滤、`ops.log` 审计、订阅/`notifications/resources/updated` 消费。

## 4. 风险与未定项（评估时重点确认）

1. **Binder 1MB 事务上限**：goodshare 现有大资源/批量返回是否超 512KB？超则需改 URI/`ParcelFileDescriptor` 引用，工作量视现状而定。
2. **长任务 `_async` 改造量**：现有 `tools/call` 中超 5s 的调用需改为异步闭环，涉及哪些工具？
3. **节点卡展示位**：本地插件走自动发现通道，与手填 HTTP 端点卡**非同一 UI**；goodhub 侧需确认本地插件节点卡的「在线点/延迟/工具计数/鉴权态」展示位（当前 T5 节点卡仅覆盖手填端点）。**此项是 goodhub 侧待补，goodshare 改造不阻塞，但真机联调需双方对齐。**
4. **PC 网关暴露路径变更**：改造后 goodshare 不监听端口，PC 须经 GoodHub 网关 `:8766` 聚合访问，原直连 goodshare 端口的 PC 配置需迁移。
5. **反向 Server 角色暂缓**（FC6）：goodshare 若依赖 goodhub 反向暴露特权工具，该能力暂缓，触发条件=出现真实需求。

## 5. 评估结论清单（goodshare 侧填写）

| # | 评估项 | 结论(是/否/部分) | 工时估算 | 备注 |
|---|---|---|---|---|
| 1 | 能否移除 HTTP 端口监听、改 Binder Service | | | |
| 2 | 接入 `goodhub-mcp-plugin-core` SDK 可行性 | | | SDK 已独立成仓 `loveheng/goodhub-mcp-sdk`（0.1.0），引 `com.zzh.goodhub.mcp:goodhub-mcp-plugin-core:0.1.0` 即可；goodshare 现有自拷 AIDL + `McpBinderService` 可整体替换 |
| 3 | 大结果是否触发 1MB 事务上限、需 URI 降级 | | | |
| 4 | 长任务 `_async` 改造范围 | | | |
| 5 | 采样反向请求闭环迁移量 | | | |
| 6 | 任务源协议（claim/apply）是否保留 | | | 见 ai-app-split.md |
| 7 | PC 网关聚合访问迁移影响 | | | |
| 8 | 同签名权限零弹窗是否满足 | | | |

> 填完后回 goodhub 侧，双方对齐 §4.3 节点卡展示位与 §4.4 PC 网关迁移，再排真机联调第三批。
