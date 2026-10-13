---
status: active
updated: 2026-10-13
---

# goodshare 本地 Binder 插件 PoC · 评估结论与修改请求（goodhub → goodshare）

> 背景：goodhub 已完成通用本地插件宿主侧实现，对照 goodshare 已交付的 Binder 插件 PoC（改造清单 #1）做了阶段一只读评估。
> 契约 SSOT：goodhub 仓 `docs/design/thirdconnect.md`（TC1~TC14）；任务源协议 SSOT：goodshare 仓 `docs/design/ai-app-split.md`。
> 立埸：goodhub 是通用 MCP 宿主，goodshare 走与第三方一致的本地插件通道，不特制适配。
> **本文目的**：列出 goodshare 侧必须修的 bug + 需评估的真机风险，请 goodshare 评估并落地修改，回填结论。

---

## 0. 总体结论

- goodhub 宿主侧（Dart `BinderTransport`/`LocalPluginDiscovery` + 原生 `BinderTransport.kt` + `MainActivity`）**已完整就绪**，可进真机联调。
- goodshare PoC 与契约 **AIDL/manifest/Service 逐条对齐**，协议主干可通。
- **但有 1 个致命 bug、1 个安全缺位必须 goodshare 改**，另有若干真机风险需评估。

---

## 1. 必须修改项（goodshare 侧，请确认并落地）

### 🔴 Bug1（致命，宿主稳定性）— `call` 无 per-call 超时

- **文件**：`android/app/src/main/kotlin/com/zzh/goodshare/McpBinderService.kt`
- **位置**：`call()` 内 `val result = resultFuture.get()`（约 line 70）。
- **现象**：若 Dart `handleJsonRpc` 因任何原因不回（工具死锁、引擎异常），该 Binder 线程**永久阻塞**，对应请求 future 永不完成，宿主侧该调用卡死。
  另：`ai_suggest_tags` 等带 sampling 的工具同步执行约 **90s**，经 Binder 同步回传直接违反契约 `§1.2.3 <5s` 预算。
- **改法（请二选一或叠加）**：
  1. **加超时（最低成本，建议先做）**：`resultFuture.get(5, TimeUnit.SECONDS)`；catch `TimeoutException` → 返回带请求 `id` 的标准 JSON-RPC error：
     ```json
     {"jsonrpc":"2.0","id":<请求id>,"error":{"code":-32000,"message":"MCP Binder call timeout"}}
     ```
     注意：需先从 `jsonRpcRequest` 解析出 `id` 再回显（见 Bug3）。
  2. **根本解（#4/#5 批次）**：对长工具（含采样）在 `mcp_server.dart` 的 `tools/call` 立即回 `{"result":{"_async":true}}`，真实结果稍后经 `onEvent` 推同 `id` 终帧，使 `call` 永远秒回。
- **优先级**：🔴 联调前建议修（否则异常路径/长工具会挂死宿主线程）。

### 🟠 Bug2（安全闸门，§1.2.6）— 未声明 signature 权限

- **文件**：goodshare `AndroidManifest.xml`（Service 块）+ goodhub `AndroidManifest.xml`（由 goodhub 侧补）。
- **现象**：Service `exported=true` + 公开 action，**未**加 `android:permission="com.zzh.goodhub.permission.MCP_SERVER"`（signature），goodhub 也无 `<uses-permission>`。当前**任何 app 都能 bind**。
- **改法（双方各一半）**：
  - goodshare 新增：
    ```xml
    <permission android:name="com.zzh.goodhub.permission.MCP_SERVER"
                android:protectionLevel="signature"/>
    ```
    并在 Service 上加 `android:permission="com.zzh.goodhub.permission.MCP_SERVER"`。
  - goodhub 侧会同步加 `<uses-permission android:name="com.zzh.goodhub.permission.MCP_SERVER"/>`。
  - **约束**：两 app 必须**同签名**发布（同机 debug keystore 一致即可），否则 `sameSignature=false` 走信任卡片分支（PoC 暂无该 UI，需补或暂以签名对齐兜底）。
- **优先级**：🟠 PoC 联调不阻塞（exported 仍可 bind），但**上线前必须补**。

### 🟡 Bug3（轻微，可观测性）— error 帧 id 恒 null

- **文件**：`McpBinderService.kt` `errorJson(id=null,...)`（约 line 157-158）；`mcp_server.dart` 解析失败分支 `_rpcError(null,...)`（约 line 373/376）。
- **现象**：基础设施错误（解析失败、超时）不回显请求 `id`，goodhub 侧难以关联对应请求。
- **改法**：基础设施错误也尽量先 `jsonDecode` 取 `id` 后回显。
- **优先级**：🟡 低，可随 Bug1 顺手改。

---

## 2. 需 goodshare 评估的真机风险（请评估并给结论/工时）

### R1 — 双 isolate 并发写 `goodshare.db`（WAL）竞争（🟡）

- **事实**：`mcpBinderMain()` 起独立 `FlutterEngine` + 独立 `Repository()` + `McpServer`，与 MainActivity 主 isolate 各一套；两 isolate 各自 `openDatabase('goodshare.db')` → 两个独立原生 SQLite 连接指向同一 WAL 文件。
- **风险**：WAL 允许多读单写，但**两个独立连接并发写**会争写锁，超 `busy_timeout` 抛 `SQLiteDatabaseLockedException` / "database is locked"。「WAL 下安全」的判断偏乐观——WAL 不消除跨连接写竞争。
- **请 goodshare 评估/验证**：真机让 goodshare UI 与 Binder 调用**并发写**（UI 加 item + 同时 MCP `add_item`/`get_item`），抓 logcat 看是否 locked。
- **缓解建议（供参考）**：binder isolate 走读为主；或全仓 DB 访问经单 isolate actor 串行化；或 sqflite 打开时显式 `singleInstance` / 提高 `busy_timeout`。

### R2 — `ready` 等待 10s vs goodhub 冷启 5s 不匹配（🟡）

- **事实**：goodshare `ready` 内部等待 **10s**（`McpBinderService.kt:44`），goodhub 冷启超时 **5s**（`BinderTransport.kt:54,296-310`）→ 首调在 5s 被 goodhub 判 DEAD+failPending，goodshare 仍在等；好在 goodhub DEAD→下次 send 自动 rebind，二次调用自愈。**功能不阻塞，但首调必败一次。**
- **请 goodshare**：将 `ready` 等待收紧到 ≤5s（或文档化「首调可能由宿主 5s 超时触发 rebind」）。

### R3 — 长工具 `_async` / sampling 经 Binder 改造范围（🟡→🔴）

- **事实**：`ai_suggest_tags` 等带 sampling 的工具同步执行约 90s，PoC 未实现 `_async` 闭环，经 Binder 会同步阻塞并违反 `<5s`。
- **请 goodshare 评估**：现有 `tools/call` 中超 5s 的调用有哪些？迁移到 `_async` + `onEvent` 终帧闭环的工作量？在 #4/#5 实现前，联调请**禁用**这些工具（只用短工具 `list_items` 等）。

### R4 — PC 网关聚合访问迁移（🟡，后续批次）

- 改造为 Binder 插件后 goodshare 不监听端口，PC 须经 goodhub 网关 `:8766` 聚合访问，原直连 goodshare 端口的 PC 配置需迁移。请评估影响。

---

## 3. goodhub 侧并行在做的（告知，不阻塞 goodshare）

- `AndroidManifest.xml` 加 `<uses-permission android:name="com.zzh.goodhub.permission.MCP_SERVER"/>`（✅ 已落地，配合 goodshare B2；两包须同签名同批出包）。
- 挂载 `ToolRouter` 真机验证：确认 goodshare 工具真正进 `ToolRouter` 并经聊天任务可调用（不止连通性）。
- 本地插件节点卡 UI 缺口：T5「Server 节点」面板当前只列手填远端端点，不覆盖本地插件——评估是否补本地插件节点卡（在线点/延迟/工具计数/鉴权态）。

---

## 4. goodshare 回填清单（请评估后回复）

| # | 项 | 结论(是/否/部分) | 计划版本/批次 | 工时估算 | 备注 |
|---|---|---|---|---|---|
| B1 | `resultFuture.get()` 加 ≤5s 超时 | | | | 联调前 |
| B2 | Service 加 signature 权限 + 声明 `<permission>` | | | | 上线前 |
| B3 | error/timeout 回显请求 id | | | | 低优先 |
| R1 | 双 isolate WAL 并发写风险评估/验证 | | | | 真机 |
| R2 | `ready` 等待收紧 ≤5s | | | | |
| R3 | 长工具 `_async` 改造范围 | | | | #4/#5 |
| R4 | PC 网关聚合迁移影响 | | | | 后续 |

> 评估/修改完成后，请回 goodhub 侧，并同步更新 goodshare 仓 `docs/design/goodshare-goodhub-local-plugin-eval.md` 与 goodhub 仓 `context/epics/goodhub-local-plugin/devlog.md`（追加 `[验证]` 行）。双方对齐后再排真机联调。

---

## 附：真机联调前置（供参考，不要求 goodshare 现在做）

1. 同机 `flutter build apk --debug` 出两包，**同 debug keystore 签名** → `sameSignature=true`。
2. `adb install -r` 两包；goodshare 至少启动一次（初始化 DB）。
3. goodhub 触发 `localPluginDiscovery.scan()` → 确认 `serverId=goodshare / sameSignature=true` → 自动 bind → state READY。
4. 协议走通（**只用短工具**）：`initialize` → `tools/list` → `tools/call list_items`。
5. 随调随起：`adb shell am force-stop com.zzh.goodshare` → 再次 `tools/list` 应自愈。
6. WAL 并发：UI 加 item 同时 MCP `add_item`/`get_item`，盯 `database is locked`。
