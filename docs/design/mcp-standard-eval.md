---
status: active
updated: 2026-10-19
---

# goodhub MCP 实现 · 官方标准合规评估（2025-06-18）

> 评估对象：goodhub 自身 MCP 实现的完整度，对照 MCP 协议规范 **2025-06-18**。
> 范围：`lib/mcp/`（客户端角色，连 goodshare 远端 + 同机 Binder 插件）与 `lib/gateway/`（服务端角色，把聚合工具面以 Streamable HTTP 暴露给 PC/局域网客户端）。
> 立场：goodhub 是「聚焦自身产品边界、已双向落地的 2025-06-18 子集实现」，对标对象不是通用 MCP Inspector / Claude Desktop。
> 本文为只读评估：结论以代码实证为准（逐条附 file:line）；取舍项标注原因。

## 0. 结论速览

| 维度 | 结论 |
|---|---|
| 角色 | **双角色**：既是 MCP 客户端（连 goodshare / 本地插件），又是 MCP 服务端（gateway 暴露聚合工具面给 PC） |
| 协议版本 | 客户端 `lib/mcp/server_capabilities.dart:11` 与服务端 `lib/gateway/mcp_gateway_handler.dart:75` 均为 `2025-06-18`，已对齐 |
| 消息层 | JSON-RPC 2.0 强类型（`lib/mcp/json_rpc.dart`）✅ |
| 传输 | Streamable HTTP（POST + SSE）+ 同机 Binder AIDL ✅；**无 stdio（刻意取舍）** |
| 核心原语 | Tools / Resources / Prompts 客户端侧全实现；Sampling 反向请求已实现并声明 ✅ |
| 服务端面 | gateway 仅暴露 **tools-only**（`initialize()` 仅声明 `tools: {listChanged:true}`） |
| 真缺口（剩余） | **OAuth 2.1 动态鉴权**——仅「连更广公网 server 生态」时阻塞；分页（nextCursor）与 elicitation 已于本轮补齐（见 §2 / §8） |
| 已修正项 | 此前「initialize 不声明 sampling capability」不符点已在当前代码修复（`lib/mcp/mcp_client.dart:117`） |

## 1. 角色定位（修正前置）

goodhub 不是纯客户端。除 `lib/mcp/` 客户端外，`lib/gateway/` 是一个完整内嵌 MCP 服务器：

- Streamable HTTP：`POST /mcp`（按 Accept 回单 JSON 或 SSE 帧）+ `GET /mcp`（SSE 通知下行）——`lib/gateway/gateway_server.dart`
- 会话：initialize 下发 `Mcp-Session-Id`，后续请求须回带（缺失/未知 → 400）——`gateway_server.dart:125/139`
- 方法：initialize / ping / tools/list / tools/call ——`gateway_server.dart:130/145/149/153`
- `notifications/tools/list_changed` 经 GET SSE 下行 ——`gateway_server.dart:279`
- 入站安全：`Authorization: Bearer <token>` 校验 ——`gateway_server.dart:107`
- 附带：环路防护、单 server 并发背压、跨源 `$ref` 防火墙、每连接私有投影隔离 ——`lib/gateway/mcp_gateway_handler.dart`

## 2. 客户端侧能力矩阵（goodhub 作为 client 连 remote server）

| 维度 | 官方 2025-06-18 | 实现 | 落点 |
|---|---|---|---|
| 协议版本 | 2025-06-18 | ✅ | `server_capabilities.dart:11` |
| JSON-RPC 2.0 | ✅ | ✅ 强类型请求/响应/通知 | `json_rpc.dart` |
| 传输 Streamable HTTP | ✅ | ✅ POST 请求 + GET SSE 订阅 | `transport/mcp_transport.dart` |
| 传输 同机 Binder | （扩展） | ✅ AIDL 零端口 | `transport/binder_transport.dart` |
| 生命周期 initialize / initialized / ping | ✅ | ✅ | `mcp_client.dart:114/128/306` |
| Tools list / call | ✅ | ✅ | `mcp_client.dart` + `coordinator/tool_router.dart` |
| Resources list / read / subscribe / unsubscribe / updated | ✅ | ✅ | `mcp_client.dart:310/329/410/421` |
| Prompts list / get | ✅ | ✅ | `mcp_client.dart:361/377` |
| 流式 progress | ✅ | ✅ 分帧解析 | `mcp_client.dart:160` |
| 取消 cancelled | ✅ | ✅ 已接线 | `coordinator/mcp_tool_face.dart:223` |
| Sampling 反向请求 | ✅ | ✅ 引擎单发 + 配额分池 | `sampling.dart` |
| client capabilities 声明 sampling | ✅ | ✅ 按 `samplingEnabled` 条件声明 | `mcp_client.dart:117` |
| 分页 nextCursor | ✅ | ✅ listResources/listPrompts/listTools 游标循环翻页（向后兼容无分页 server） | `mcp_client.dart` `_listPaginated` |
| elicitation 反向请求 + UI | ✅ | ✅ 能力声明 + 交互卡表单（TrackElicitation） | `mcp_client.dart` `_answerElicitation` / `elicitation_card.dart` |
| 鉴权 静态凭证 | ✅ | ✅ X-Api-Key / Bearer | `transport/mcp_transport.dart:78` |

## 3. 服务端侧能力矩阵（gateway 暴露给 PC）

| 维度 | 官方 2025-06-18 | gateway 实现 | 落点 |
|---|---|---|---|
| Streamable HTTP（POST + GET SSE） | ✅ | ✅ | `gateway_server.dart` |
| 会话 Mcp-Session-Id | ✅ | ✅ | `gateway_server.dart:125` |
| initialize / ping | ✅ | ✅ | `gateway_server.dart:130/145` |
| tools/list（含 listChanged 声明） | ✅ | ✅ | `mcp_gateway_handler.dart:84` |
| tools/call（SSE 流式 progress） | ✅ | ✅ | `gateway_server.dart:180` |
| notifications/tools/list_changed 下行 | ✅ | ✅ | `gateway_server.dart:279` |
| Resources / Prompts / Sampling | — | ❌ 完全未实现 | `initialize()` 仅声明 `tools` |

> 作为 server，goodhub 只暴露 **tools-only** 面：标准 PC 客户端请求 resources / prompts 会得 -32601；向网关触发 sampling 无意义（网关是工具聚合代理，不是 PC 的 LLM 宿主）。这是角色决定，非缺陷。

## 4. 取舍明细（刻意取舍 vs 真缺口 + 原因）

### 4.1 刻意取舍（与产品边界无关，不修）

| 缺失能力 | 落点事实 | 取舍原因 |
|---|---|---|
| **stdio 传输** | 仅 HTTP + Binder，全仓无 stdio | goodhub 是 Android 宿主，连的是 goodshare（远端 HTTP）与同机 Binder 插件；stdio 需本地子进程（`npx`/`uvx` 起 server），移动端无适用场景；同机零端口需求已由 Binder 覆盖 |
| **completions / complete** | 全局 grep 无匹配 | 补全原语用于 client 向 server 请求参数补全；goodhub 是 AI 宿主自行推理，不向 server 取补全，与「认领任务执行」定位无关 |
| **resources/templates（listResourceTemplates）** | 无匹配 | 模板资源是 server 动态生成资源 URI 的约定；goodhub 只读 resources 且 goodshare 不依赖模板，无需求 |
| **roots** | 无匹配 | roots = client 向 server 暴露本地文件根、让 server 反向读宿主 FS；goodhub 出于移动端沙盒与 PII 隔离刻意不暴露文件根，且「宿主是被读方」与产品边界冲突 |
| **tools/list_changed / prompts/list_changed 消费** | `mcp_client.dart:438` `handleServerNotification` 仅消费 `resources/updated` | 当前连 goodshare + 同机插件，靠重连差分清洗（D17）兜底变更感知；订阅这两类通知增益有限且增加握手状态复杂度；Tier 2 降级已覆盖能力缺失 |
| **服务端仅 tools-only** | `mcp_gateway_handler.dart:84` | 网关是工具聚合代理，PC 只需拿聚合工具调用；resources / prompts / sampling 在网关角色下无意义（网关不持有 prompt / 资源语义，也不应成为 PC 的 LLM 推理宿主） |

### 4.2 真缺口（仅「连更广公网 server 生态」时阻塞）

> 用户已选补齐 **分页（nextCursor）** 与 **elicitation** 两项（实现见 §8）；剩余唯一真缺口为 **OAuth 2.1**。

| 缺失能力 | 影响 | 为何当前不阻塞 |
|---|---|---|
| **OAuth 2.1 动态鉴权** | 连不了 GitHub / Slack 等走授权码 + PKCE + 动态注册的公网 server | 当前只连 goodshare（手动 token）+ 同机插件（同签名），无动态授权场景 |

## 5. 已修正项

此前评估曾指出 client `initialize` 不声明 `sampling` capability（规范不符点）。当前代码已修复：`lib/mcp/mcp_client.dart:117` 按 `samplingEnabled` 条件声明 `'sampling': {}`；`samplingEnabled` 由装配层（`McpRuntime.mount` / `assemble`）置 true（调用方均接 sampling handler），诊断用 `server_probe` 保持 false。

## 6. 其他债务

- `lib/mcp/tool_router.dart` 为**未接线**实现（注释明示 F1.9 / P0 唯一实现，仅 test 引用；生产走 `coordinator/tool_router.dart`）。它带海关过滤，因现网 server 普遍不下发标记而不敢启用（启用会全部过滤归零）。属已写未用债务，非 bug。**2026-10-21 进展**：标记口径随插件 SDK 0.2.0 更正为 `_meta.goodhub.visibility`（旧 `annotations["x-mcp-export-to-shared"]` 作废），过滤已接线在对外暴露面（网关 PC 投影），本机链路仍不过滤；本件继续保留待收编（架构债 #9）。

## 7. 结论与建议

goodhub 的 MCP 实现 = 「聚焦自身产品边界、已双向（client + server）落地的 2025-06-18 子集实现」，非通用 MCP 客户端。

- 第一组缺失（stdio / completions / roots / templates / list_changed 消费 + 服务端 tools-only）是**刻意取舍**，与「AI 宿主认领 goodshare 任务」的产品边界无关。
- 第二组（OAuth 2.1 / elicitation / 分页）：**elicitation 与分页已于本轮补齐**（§8）；仅 **OAuth 2.1** 仍为真缺口，仅当要连更广公网 server 生态时才阻塞。
- 建议优先级：**OAuth 2.1** 唯一剩余，扩生态时再投入。

## 8. 本轮补齐（用户请求：分页 + elicitation）

按用户在「刻意取舍 / 真缺口」二选一的取舍，补齐两项真缺口（OAuth 2.1 未选，维持 §4.2 真缺口）；刻意取舍项（§4.1）维持不变。

### 8.1 分页 nextCursor（纯客户端）

- `lib/mcp/mcp_client.dart` 新增 `_listPaginated(method, itemsKey)`：循环发请求带 `cursor`，累积 `itemsKey` 数组直到响应无 `nextCursor`；server 不支持分页时单次全量返回、无 nextCursor，自然一轮结束（向后兼容 Tier 2 / 旧 server）。
- `listResources` / `listPrompts` 改为走 `_listPaginated`；新增 `listTools()`（此前调用方直接 `client.call('tools/list')`）。
- 生产路径 `lib/coordinator/mcp_tool_face.dart` 的 `listTools()` 改为调用 `client.listTools()`，工具清单翻页接入生产。

### 8.2 elicitation（client 分发 + 移动端交互 UI）

- `lib/mcp/elicitation.dart`：新模型 `ElicitationRequest` / `ElicitationAnswer`、委托接口 `ElicitationDelegate`、client 回调适配器 `elicitationRequestHandler`；支持 JSON Schema 字段解析（string/number/integer/boolean + enum、required）。
- `lib/mcp/mcp_client.dart`：`elicitationEnabled` 字段（mirror `samplingEnabled`）、握手 capabilities 条件声明 `elicitation`、`onElicitation` 回调、反向请求路由 `_answerElicitation`（未接线且未声明能力 → 优雅 decline，不悬挂）。
- 装配层 `lib/coordinator/mcp_runtime.dart`：`RuntimeDelegates` 新增 `elicitationDelegate`；`_assembleInner` 在注入委托时置 `elicitationEnabled = true` 并接线 `onElicitation`（无委托 → 保持 false，decline）。
- UI（与 confirm/breaker/fence 同口径的轨道卡）：`lib/ui/components/dual_track_stream.dart` 新增 sealed 子类 `TrackElicitation` 并覆盖 renderEntry / _encode / decode 三处 switch；`lib/ui/components/elicitation_card.dart` 按 `requestedSchema` 动态渲染表单（开关 / 下拉 / 数字 / 文本，必填与类型校验，提交 = accept + content、跳过 = decline）；`lib/ui/components/chat_gate_delegates.dart` 新增 `ChatElicitationDelegate`（插轨 + await 用户填表）；`lib/ui/chat_page.dart` 注入委托。
- 取舍说明（为何默认不声明 / 无委托即 decline）：elicitation 需要有人值守 UI；无人值守场景（gateway 代理、任务页 headless）保持 `elicitationEnabled = false`，server 若发起则收到 decline 帧，不悬挂、不破坏 server 侧超时兜底。
