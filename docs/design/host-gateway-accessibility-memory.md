---
status: active
updated: 2026-10-23
---

# Host 网关架构 · 访问性模型 · 记忆捎带提取（设计演进 SSOT）

> 本文档是 2026-10-15 一轮架构推演的**唯一 SSOT**：从「默认 private 的 SDK 配置契约」出发，逐步收敛到「访问性模型的两维解耦」「Host 作为聚合反向代理网关」「记忆 In-band 捎带提取」三段结论。代码引用锚定当前 `lib/` 状态（`lib/mcp/server_endpoints.dart`、`lib/coordinator/tool_router.dart`、`lib/gateway/*`、`lib/sandbox/memory_store.dart`、`lib/coordinator/context_governor.dart`、`lib/coordinator/agent_loop.dart`）。memory 只记状态与指针，落地决策以本文为据。

## 0. 三段结论速览（TL;DR）

1. **访问性 / 隐私分层**：外部 MCP 服务只分 `private` / `public` 两档；`host`（宿主内置能力）**不在 `ServerEndpoint` 模型里**，由客户端以 `HostNativeTools` 注入。两维解耦 = Provider（host / external）× Tier（private / public）。
2. **Host = 聚合反向代理网关**：goodhub 既是下游子服务的客户端，又是对上的标准 MCP 服务端代理；四项治理（命名空间虚拟化 / 工具面虚拟化 / 调用拦截 / 遥测脱敏）收口在网关层。`GatewayController`+`GatewayHandler` 已是实体。
3. **记忆 = In-band 捎带提取**：在模型最终自然语言轮尾部用 `<workspace_update>` 标签捎带提取背景事实，省掉二次模型调用；goodhub 现有 `MemoryStore` / `context_governor` / `agent_loop` 已覆盖约 80% 基础设施，真实缺口集中在 Demuxer 与会话级 store。

> **Scope 边界（方案 B 轻量约束 · 防误判）**：本文档是「Host 网关 / 访问性 / 记忆」架构推演 SSOT（覆盖 §1 访问性模型、§2 Host 网关、§3 记忆 In-band、§7 缓存、§9 边界防御、§10 系统补全），**不等于**「纯 Chat 消息气泡渲染层」。其落地由 `epic: chatmessage` 承接，但该 epic 执行范围仅限 **§3 记忆 In-band 捎带提取（含 G1~G8 中流式 / 存储相关项）及其依赖（§1 数据模型、`§2 tool_router` 三段式重构）**；纯网关服务端（`lib/gateway/*` 内部行为）、命名空间虚拟化等对上游逻辑作为**依赖跟踪**，不归本 epic 所有。

---

## 1. 访问性模型（Accessibility / Privacy Tier）演进

### 1.1 起点：默认 private 保安全闭环 + SDK 配置契约

把「默认 private」从产品决策收敛为 **SDK 配置契约**：

- **数据模型层（沉默即安全）**：`accessibility` 缺省 = `private`；`fromJson` 缺字段 / 非法值一律兜底 `private`，不抛（延续「配置面宁空勿炸」）。
- **配置作者层（显式即契约）**：SDK 注册面把「可访问性」做成**显式必选项**（radio 默认勾私有 + 隔离说明文案），不让开发者「省略就过」。缺省兜底只用于向后兼容旧配置。

```dart
// lib/mcp/server_endpoints.dart —— 演进前的两档设想
enum ServerAccessibility { private, public }
```

关键正交性（SDK 文档必须点明）：`accessibility` = **固有属性**（属于谁的隐私域）；`enabled`（`server_endpoints.dart:43`）= **运行时挂载态**。两者正交：「是私有的」与「当前是否挂载」无关。

### 1.2 三层语义细化与其陷阱

曾细化出 `private` / `host`（仅 goodhub 可见）/ `public` 三档，但暴露两个问题：

- **Dart 保留字**：`enum` 成员不能叫 `default`（用户口语里的「default 级别」），代码内需改名（`host`），产品文案仍可写「默认（仅 goodhub 可见）」。
- **两个「默认」混淆**：兜底缺省值（`private`）vs 名为 `default` 的访问级别（`host`）——必须拆开，否则后人误以为 `default` 是兜底值。

### 1.3 关键解耦（锁定结论）

> **MCP 客户端提供的服务是 host 级别；MCP 服务端提供的只有 public 和 private。**

这句话把架构边界彻底理顺——之前所有冲突源于把「能力由谁提供（Provider）」与「外部服务怎么分档（Tier）」混在同一个枚举。解耦后：

| 维度 | 取值 | 谁决定 | 是否进用户配置面 |
|---|---|---|---|
| **Provider** | `host`（客户端内置）/ `external`（外部服务端） | 架构固定 | `host` 不可配置 |
| **Tier** | `private` / `public` | 用户配置 | 仅 `external` 有 |

红利连锁：Dart 保留字冲突消失（枚举回到二进制）；「用户误配 host 权限」隐患消失（`host` 根本不在 `ServerEndpoint`）；goodshare「该 public 还是 private」两难重构为「宿主能力走 `HostNativeTools`，goodshare 只是普通外部端点」；UI 表单只剩二选一且 `private` 默认勾选。

### 1.4 最终数据模型（落地准则）

```dart
// lib/mcp/server_endpoints.dart
enum ServerPrivacyTier { private, public } // 缺省兜底 = private

class ServerEndpoint {
  final String id;
  final String name;
  final String endpoint;
  final ServerPrivacyTier tier;   // 外部服务仅有 private/public
  final bool enabled;
  // ...copyWith / toJson('tier': tier.name) / fromJson(缺省→private)
}
```

- 序列化：`fromJson` 缺字段 / 非法 → `ServerPrivacyTier.private`（兜底，不抛）。
- `host` **不进** `ServerEndpoint`；宿主能力通过 `HostNativeTools.schemas` 注入（见 §2.4）。
- 现有约定已印证：`tool_router.dart:57-59` 的 `serverFor(name)` 对**无前缀**的宿主本地工具返回 `null`——宿主工具从一开始就不走外部注册表，新模型只是把它显式化为注入点（动态路由 `switch_server`、权限确认卡 `PermissionGateway`、工作区沙箱 IO）。**宿主工具在本机 ToolRouter 调度路径下必须保持无前缀**，否则破坏 `tool_router.dart:12-13`「本地结果不落池」语义；网关投影面（对 PC 的暴露面）改用系统保留命名空间 `host__`，以虚拟服务形式挂载——裁决与实现见 `docs/design/host-tools-gateway-export.md`。

### 1.5 goodshare 迁移结论

新模型下 `host` 不进注册表，goodshare **不能是 host 级**。决定：**作为普通外部 `ServerEndpoint` 迁移，`tier: public`**（最小改动、行为兼容：它原本就是常驻可混用的主服务），同时把真正的宿主能力（`switch_server` / 权限 / 工作区）抽成 `HostNativeTools`。

```dart
// server_endpoints.dart 迁移点（约 :158-159）
ServerEndpoint(
  id: _legacyId, name: 'goodshare', endpoint: endpoint,
  hasKey: key != null && key.isNotEmpty,
  tier: ServerPrivacyTier.public, // 非 host；普通外部服务，常驻可混用
)
```

> 开放项：若后续确认 goodshare 本质就是 goodhub 后端宿主，可走「能力并入 `HostNativeTools` + 从 `ServerEndpoint` 列表移除」的纯架构路径（方案 b），但属后续决策，不阻塞当前落地。

### 1.6 `tool_router` 对接（关键改动点）

`tool_router.dart` 当前两处语义需对齐新模型：

- **`focusedSchemas()`（:83-87）当前是独占式**——聚焦后只返回该 server、踢掉其他。新模型改三段式：**host（常驻）+ 全部 public（常驻）+ 单一 active private**。
- **新增 `activePrivateServerId` 单一槽位**；`activatedServers`（:43）只收 public 挂载。**私有+私有严禁由构造保证**（单一槽位天然互斥），无需额外闸门。
- **`execute` 的 focus 拦截（:116-123）改写**：只拦「另一个 private 抢占同一槽位」，不拦 public（否则破坏「公共常驻」）。
- 同步对齐 JIT `use_server`（`discovery_executor.dart:152-197`）的聚焦逻辑，避免「聚焦 public 反而把其他 public 踢掉」。

> `tool_router` 实例随会话建（`tool_router.dart:8`），但 `GatewayController.shared` 是全局单例（`:39`）。投影状态（activePrivateServerId / workspaceId）本质上是**会话级**，需从全局单例拆出——见 §2.4 投影平面隔离。

---

## 2. Host 作为聚合反向代理网关

### 2.1 拓扑与角色定位

> 若 MCP 客户端同时兼作服务端，**Host 服务就是对其他 MCP 服务的代理**。

```
┌──────────────────────────┐
│  调用端 (LLM / Consumer)  │
└───────────┬──────────────┘
            │ 单一标准 MCP 连接 (SSE / stdio)
            ▼
┌────────────────────────────────────────────┐
│        Goodhub Gateway (Host 宿主服务)       │
│  [安全与投影引擎] 上下文脱敏 / 记忆隔离 / 私有互斥锁 │
│  [统一工具面] HostNativeTools + Public 转发 + Private 转发 │
└──────┬──────────────────────┬──────────────┬──────┘
       ▼                      ▼              ▼
  Public MCP              Private MCP        Private MCP
 (Web Search)          (Repo A 激活)      (DB B 挂起)
```

- 外部调用方眼里：只有一个名为 `Goodhub Host` 的超级 MCP 服务端（实体即 `GatewayHandler.initialize()` 声明的 `serverInfo.name = "GoodHub Gateway"`，`mcp_gateway_handler.dart:54-60`）。
- goodhub 自身：既是子服务的**客户端**（建连 / 心跳 / 协议转换），又是对外的**服务端代理**。

### 2.2 网关四项核心职责

| # | 职责 | 含义 |
|---|---|---|
| 1 | **命名空间虚拟化** | 向下抓子服务原始工具，向上打命名空间（`srv_x__tool`），向内按前缀路由剥离后转发。 |
| 2 | **动态工具面虚拟化** | 对外 `tools/list` = Host 内置 + 全部 Public + 当前激活 Private；未激活 Private 在协议层「不存在」。 |
| 3 | **访问控制 / 调用拦截** | 调用未激活 / 隔离态私有工具 → 网关处截断，返回标准 JSON-RPC 错误（如 `403 locked`），绝不漏发后台。 |
| 4 | **状态感知 / 数据脱敏代理** | 旁路监听 tool_call/result：抽取事实沉淀背景；切换 Private 域时对历史敏感调用脱敏存档。 |

> **HITL 权限门禁已落地（非缺失项）**：职责 3 的「调用拦截」与 L2 确认卡已由 `PermissionGateway`（`lib/coordinator/permission_gateway.dart`）+ `GatewaySecurity` 实现——`L1ReadOnly/L2Write` 双源裁决（C2）、`GateDelegate.confirm` 异步挂起确认卡、会话豁免（C7）、拒绝包装为 `ToolResult(isError:false)` 回传模型自我纠偏。本 SSOT 不再将其单列缺失模块。

### 2.3 与现有代码的映射（已落地部分）

| 职责 | 现有实体 | 状态 |
|---|---|---|
| 聚合单入口 / 命名空间 | `GatewayHandler.toolsList()`（`mcp_gateway_handler.dart:63-72`，`<server_id>__<tool>` 前缀聚合） | ✅ 已有 |
| 按前缀分发 | `GatewayHandler.toolsCall()`（`mcp_gateway_handler.dart:77-171`，剥前缀→face.client） | ✅ 已有 |
| 目录变更广播 | `notifyToolsListChanged()`（`:50`，`notifications/tools/list_changed` 经 SSE 下行） | ✅ 已有 |
| 入站安全闭环 | `GatewaySecurity`（L2 确认卡 + PII 出站 + ops.log，注入于 `gateway_controller.dart:42`） | ✅ 部分 |
| 协议归一 / 能力缓存 | `GatewayController._assemble()`（`gateway_controller.dart:107-184`，`negotiate()`+`listTools()` 缓存） | ✅ 已有 |
| 宿主元工具 | `DiscoveryExecutor`（无前缀 `get_connected_apps`/`activate_server_tools`/`use_server`，`:40-45`） | ✅ 仅内部运行时 |

**缺口**：`tier` 字段与工具面屏蔽未实现（`toolsList` 无差别暴露全部 face）；网关侧「未激活私有→403 锁」拦截缺失；`use_server` 当前是独占聚焦（`:152-197`），与「public 常驻 + 1 private」矛盾。

### 2.4 Host 扩展定义（最终落点）

> **Host（goodhub 宿主）= 在 MCP 拓扑中扮演的聚合反向代理 / 智能网关。** 协议上向所有上游呈现为唯一标准 MCP 服务端（`GoodHub Gateway`），连接上同时是下游所有子服务的客户端。本质是把「协议收敛、命名空间虚拟化、上下文投影、策略执行」收口在唯一边界。

Host 由两个正交平面构成（代码已隐含但未显式化）：

- **连接平面（Connection Plane）**：全局共享，负责 negotiate / 心跳 / 能力缓存（`GatewayController._assemble` 装配 `faces`）。
- **投影平面（Projection Plane）**：**每工作区 / 会话隔离**，持有 `{activePrivateServerId, publicServerIds, workspaceId}` 状态，决定当前虚拟工具面与记忆分区。

扩展定义必含的 5 个维度（用户模型未覆盖、代码揭示必须）：

1. **双表面一致性**：外部网关面（`:8766/mcp` → `GatewayHandler.toolsList`）+ 内部对话运行时（`ToolRouter.focusedSchemas`）共用**单一投影核心**，否则会「外部网关能看私有工具、内部聊天反而看不到」。
2. **连接平面全局 / 投影平面按工作区隔离**：投影状态从全局单例拆出，避免多并发工作区串域。
3. **协议收敛与能力协商**：Host 把几十种协议 / 端口归一成一个标准端点。
4. **`tools/list_changed` 是 reactive 契约**：`notifyToolsListChanged` 已是切换私有域时通知上游刷新工具面的机制。
5. **宿主元工具双表面暴露**：`switch_server`/`inspect_context` 必须在 `GatewayHandler` 也暴露（或网关侧直接处理 `use_server`），否则外部 LLM 客户端卡死在单私有域。

---

## 3. 记忆提炼：In-band 捎带提取

### 3.1 方案概述与性价比

在**模型最终自然语言轮末尾**用 `<workspace_update>` 标签捎带返回提取的背景事实（一次性 JSON），省掉「额外异步小模型调用 / 二次 Token」。优势：0 额外网络调用、0 额外前缀 Token、强因果一致性（模型刚生成完回复、决策记忆热度最高）。

### 3.2 协议设计（严格置于尾部的 XML 隔离标签）

```
[System Prompt 附加指令]
在你的自然语言回复完成之后，评估本次对话中用户明确指定或确认的
【硬性约束、关键决策、业务实体定义】。在最末尾用 <workspace_update>
标签输出 JSON；若本轮无新事实或仅为闲聊，输出空标签 <workspace_update>{}</workspace_update>。

<workspace_update>
{ "facts": [ { "key": "tech_stack.db", "value": "PostgreSQL",
  "scope": "public",  // 或私有 MCP ID: "srv_github"；或 "user" 全局
  "action": "upsert" } ] }   // upsert | remove
</workspace_update>
```

铁律：**仅在向用户输出最终自然语言解答的末尾附加**；发起 `tool_calls` 时严禁输出该标签（避免 content 为空时强求提取）。

### 3.3 流式分流 FSM（避免 JSON 闪烁在气泡）

客户端需带**前缀安全缓冲**的有限状态机（借鉴 Cline / Roo / Claude Artifacts）：

- `NORMAL`：未遇 `<` 直接流向 UI；遇 `<` 暂停输出，挂起 `<` 起字符入 pendingBuffer 进 `CHECKING`。
- `CHECKING`：pendingBuffer 仍是 `<workspace_update>` 前缀 → 继续 Hold；完全匹配 → 切 `IN_METADATA` 清空缓冲；匹配失败（用户正常打了 `<tag>`）→ 把缓冲 flush 给 UI 回退 `NORMAL`。
- `IN_METADATA`：拦截所有字符入 jsonBuffer，直到匹配 `</workspace_update>` → 触发完成回调。
- **缓冲区上限 = startTag.length（约 18 字符）**，超长未匹配立即 flush，既无闪烁也不误吞正常 `<`。

**原子提交（借鉴 Aider dirty-json）**：未收到严格闭合 `</workspace_update>` 前**绝不**写 `MemoryStore`；闭环三步校验——① 捕获 Close Tag，② 正则清洗（剥离 ```` ```json ```` 包裹），③ `jsonDecode`，`FormatException` **静默丢弃 + Debug 日志，绝不上报中断 UI**。

**中止规则（tool-call 轮硬压 FSM，数据完整性护栏）**：文本 delta 与 tool_call delta 是分离事件流（`agent_loop.dart:265` emit `CloudTextDelta`；`:279` `calls = acc.toolCalls`），FSM 无法在流中预知本轮是否为 tool-call 轮，故守卫必须挂在**轮结算**处——`calls.isEmpty`（`:280`）才允许提交；一旦 `calls.isNotEmpty`，即便模型偶发吐出残缺 `<workspace_update>` 字符，也调用 `demuxer.cancelCommit()` **清空累积的 `jsonBuffer` / `pendingBuffer`、绝不写 `MemoryStore`**。已 emit 给 UI 的普通文本不动（正常展示），仅丢弃结构化片段。此规则杜绝 tool-call 轮误提交污染记忆。

### 3.4 现有基础设施盘点（已覆盖约 80%）

| 设计要求 | goodhub 现状 | 落点 |
|---|---|---|
| 分层作用域存储 | `MemoryStore` scope 正则 `^(user\|srv:[A-Za-z0-9_-]+)$`（`memory_store.dart:461`） | user + srv ✅；session ❌ |
| 预算截断 KV 注入 | `memoryView({budgetTokens, serverScopes})`（`memory_store.dart:240-268`） | ✅ |
| 提示词缓存友好顺序 | `memoryPromptSection` 注释「落位组装尾部…护住前缀缓存」（`memory_store.dart:546-547`） | ✅ 既定原则 |
| 撤销 / 编辑 | `deleteEntry` / `updateEntry`（`memory_store.dart:277-310`） | ✅ 后端已有，差前端胶囊 |
| 双轨历史（本地不裁 / 发送边界治理） | `trimMessagesToWindow`「本地历史不裁」（context_governor.dart:3-4, :41） | ✅ 缺 scope 投影 |
| 流式 delta 钩子 | `if (e is CloudTextDelta) emit(LoopTextDelta(e.text))`（agent_loop.dart:265） | ✅ 挂 FSM 位置 |
| 终局轮才提取 | 自然结算分支 `calls.isEmpty`（agent_loop.dart:280-292），tool-call 轮 content 常空 | ✅ 对应「最终语言轮」 |
| 异步小模型管线先例 | `OnDeviceResultSummarizer`（context_governor.dart:75-98） | ✅ 证明副模型管线可行 |

### 3.5 真实缺口（必须新建 / 改造）

- **G1 语义 key 映射**：JSON 带 `key`/`value`/`action(upsert|remove)`，但 `MemoryStore` 是内容追加 + 锚点 id 模型（`remember(content, scope)`，`memory_store.dart:163`），无语义 key。需在落盘前按 key 查重实现 upsert/remove，或新建**按 key 的轻量 KV 子 store**。
- **G2 Demuxer / FSM 未写**：需新建 `WorkspaceStreamFilter` 并两处接线——包住 `agent_loop.dart:265` 的 `emit(LoopTextDelta)` 做实时分流；在 `calls.isEmpty` 分支（`:282-283`）把 `acc.text` 内标签段剥掉再入历史（否则结构化 JSON 污染 canonical 历史）；**并在 `calls.isNotEmpty` 分支调用 `cancelCommit()` 清空 FSM 累积缓冲、禁止提交**（§3.3 中止规则），堵住 tool-call 轮偶发吐出残缺标签导致的误提交。
- **G3 会话级（workspace）store 缺失 —— 最大缺口**：现有 `MemoryStore` 经 `underSupportDir` 挂在**应用支持目录**（`memory_store.dart:137-138`），是 **app 全局级**（user + srv:），**无 per-conversation 层**。占比最大的「任务临时决策（Session Fact）」需挂在当前对话工作区下——这正是前序「对话工作区」设计未落地的 `workspace_states` 表。本需求的会话事实落点 = 该缺失 store。
- **G4 scope 校验 + 「public」映射**：模型可能幻觉 scope，须校验 `scope ∈ {user, srv:<当前激活私有 id>, session/workspace}`；现有 `_scopeRegExp` 只认 `user|srv:`（`memory_store.dart:461`），需扩展会话域（如 `session` / `ws:<convId>`），并把 JSON 的 `"public"` 映射为「本会话域」（跨所有服务器可见、非用户全局）。此步同时是 §2 隔离矩阵「私有记忆分区」的强制落实点。
- **G5 工具 Schema 键序归一（P0 缓存杀手）**：`CloudToolSchema` 缺规范 `toJson`，且 MCP 返回的 `parametersSchema` 键序不可控；须在 Dart 层实现递归字典序排序，否则前缀缓存命中率为 0。详见 §8.2 改动点 3。
- **G6 FSM 生命周期与取消回滚（P0 数据安全）**：用户 Stop / 网络中断时 `pendingBuffer` / `jsonBuffer` 残留致下一轮脏解析；须在 `_aborted` 挂接 `fsm.discard()`。详见 §9.2。
- **G7 输入端特异性标签转义（P1 防注入）**：用户输入中 `<workspace_update` 转义为 `&lt;workspace_update`；输出统一升级为带静态版本号 `<workspace_update_v1>`。详见 §9.3。
- **G8 移动端前后台生命周期探针（P1 稳定性）**：缺 `WidgetsBindingObserver` 钩子；App `resumed` 须主动 ping 探针 + 失效静默重连防 SSE 假死。详见 §10.1。

### 3.6 长对话 Token 控制（留状态快照，非日志）

「留状态快照（KV）不留心路历程（Log）」判断正确，`MemoryStore.memoryView` 已是此机制（预算内保留最新、丢最旧，`memory_store.dart:254-259`）。两点须说清：

1. **它不是语义覆盖，是追加 + 按预算丢最旧**。精确 `upsert` 覆盖（PostgreSQL 16.0 始终占 ~20 token）需 G1 的 keyed 映射才能做到，否则同 key 多次变更会追加成多条旧条目被预算淘汰、中间短暂膨胀。
2. **三生命周期分层**：`user`(全局)✅、`srv:`(MCP)✅、**`session`(会话)❌**——仅 session 缺失（G3）。不补则「任务临时决策」要么污染全局记忆、要么无处可落。

| 决策类型 | 典型示例 | 存储位置 | 生命周期 |
|---|---|---|---|
| 任务临时决策 (Session Fact) | 每页 20 条、此接口用 POST | 当前对话工作区（G3 新增） | 仅本次对话 |
| 环境 / 工具配置 (MCP Scoped) | 私有库分支 staging-v2 | `srv:<id>`（已有） | 用该 MCP 即生效，切走隐藏 |
| 通用习惯 / 全局偏好 (Global) | 前端写 Flutter/Dart | `user`（已有） | 跨会话持久 |

UI 须给用户「确定感与纠错权」：右侧栏 / 抽屉展示已沉淀事实；气泡底嵌胶囊（⚡ 已记录 key=value [✕撤销]），撤销即 `MemoryStore.remove`。

### 3.7 MVP 落地步骤（复用优先）

1. **复用** `memoryPromptSection` + `MemoryStore`（user/srv 两层）直接做注入与撤销后端，**不重写**。
2. **新建** `WorkspaceStreamFilter`（FSM，跨 chunk 安全缓冲 + 闭环原子提交）。
3. **接线** 挂 `agent_loop.dart:265`（分流）+ `:282`（终局剥离）；`onFactExtracted` → 写 store。
4. **补 G3/G4** 新建 per-conversation 事实 KV store（keyed upsert/remove）+ 扩展 scope 正则含 `session`/`ws:`。
5. **Prompt** 尾部追加 `<workspace_update>` 格式铁律（固定区护缓存；含「tool-call 轮严禁输出」）。
6. **验证** 先控制台打印解析结果，确认 UI 气泡无 JSON 残留。

---

## 4. 串联：隔离矩阵 + 记忆分区 + 提取 scope 统一

| 本机制 | 对应前序讨论 |
|---|---|
| 提取 JSON 的 `scope` 字段 | §2 隔离矩阵的「私有记忆分区」——同字段、同边界 |
| 终局剥离 `<workspace_update>` 再入历史 | §2「投影历史」的 canonical 侧（本地留全、发送侧治理） |
| Demuxer 不闪 JSON | §2「流式体验不翻车」 |
| `srv:<id>` scope 隔离 | §1「私有 + 私有严禁」的记忆侧落地 |
| session 级 store（G3） | 前序未落地的「对话工作区」 |

整条链路闭环：SDK 配置定 tier（§1）→ 网关按 tier 虚拟化工具面 + 拦截越权（§2）→ 模型在最终轮捎带提取事实（§3）→ 按 scope 落对应生命周期 store（§3.5/G4）→ 下轮 prompt 尾部注入（§3.4）→ 切换私有域时投影隔离（§2.4）。

---

## 5. 决策记录（ADR 摘要）

| # | 决策 | 理由 | 状态 |
|---|---|---|---|
| D-A | 外部服务仅 `private`/`public` 两档；`host` 不进 `ServerEndpoint` | Provider×Tier 两维解耦，消除保留字 / 误配 / goodshare 两难 | ✅ 锁定 |
| D-B | goodshare 迁移为普通外部 `ServerEndpoint`，`tier: public` | 最小改动、行为兼容；宿主能力另抽 `HostNativeTools` | ✅ 锁定 |
| D-C | 私有 + 私有严禁由 `activePrivateServerId` 单一槽位构造保证 | 无需额外闸门，与 `public` 常驻正交 | ✅ 锁定 |
| D-D | Host 扩展定义含「连接平面全局 / 投影平面按工作区隔离」 | 解决 `GatewayController.shared` 单例与投影态会话级的矛盾 | ✅ 锁定（实现待排） |
| D-E | 记忆走 In-band 捎带提取，非异步小模型 | 0 额外调用 / Token，因果一致；复用既有基础设施 | ✅ 锁定 |
| D-F | 会话级事实 store 须新建（G3） | 现有 `MemoryStore` 仅 app 全局级，无 per-conversation 层；DDL 已定（§9.5） | ✅ 锁定（详见 §9.5） |
| D-H | 切换私有域做历史投影时绝不物理删除 `tool_call`/`tool_result`，保留 matching `id` 替换为合成占位桩 | 防 OpenAI/Anthropic 严格成对校验触发 `400 Bad Request` | ✅ 锁定（详见 §9.1） |
| D-I | 超大工具输出在 `_governedContent` 入口前置物理硬截断 `kToolResultHardCap = 2000 tokens (≈8KB)` | Head 50 + Tail 20 折叠，提供不依赖端侧摘要的确定性保底地板 | ✅ 锁定（详见 §10.4） |
| D-J | 单轮多 `tool_calls` 改 `Future.wait` 并发编排；任一失败须包装为合法错误 `ToolResult` 全量回填 | 绝不向上抛异常中断流；LLM API 要求 100% `tool_call_id` 收到对应 result | ✅ 锁定（详见 §10.2） |
| D-K | 剪枝与负收益消除 | ① 仅留断点 A（静态区），砍断点 B（记忆二次断点）消除 re-cache 写入惩罚；② 砍 `is_locked` 行级锁，`workspace_states` 回归 `INSERT OR REPLACE`；③ Gemini 保持无状态、不建 `CachedContent` 生命周期；④ 当前阶段不引入 MCP Resources(@)/Prompts(/) | ✅ 锁定（详见 §7.5 / §9.5 / §9.4 / §10.3） |

## 6. 开放问题

1. goodshare 到底是「宿主」还是「外部业务服务」？当前按外部 `public` 迁移（D-B），若后续确认是宿主，走能力并入 `HostNativeTools` 路径。
2. 外部 `public` 服务器调用 `host` 工具的拦截边界：`host` 不进外部服务器工具面（工具面暴露层拦截），否则出现「外部服务器间接读宿主内部能力」越权。
3. 多模型一致性：hybrid 引擎下不同模型对尾部 XML 标签遵从度不同，须 fallback（解析失败静默丢弃，已有 DEGRADE 容错传统）。

---

## 7. Prompt Caching（前缀缓存）落地评估

> 用户提出「严格最长前缀匹配 + 静态→动态分层 + 跨厂商折让」五铁律。本节能否落地，取决于 goodhub 实际装配顺序与是否显式标缓存断点。代码锚点：`chat_page.dart:1025-1032`（System 重组）、`agent_loop.dart:235-239`（System→history→User）、`memory_store.dart:546-547`（记忆置尾）、`chat_page.dart:997-1002`（工具序）、`gateway_server.dart:165/226`（仅 HTTP `no-cache`）、`context_governor.dart:41-57`（滑窗裁剪）。

### 7.1 装配现状取证

- **System 每轮重组**（`chat_page.dart:1025-1032`）：`skills.composeSystemPrompt(_systemPrompt, serverIds) + mountedSection + memSection`。块内序：角色静态 → skills（mountedSection）→ 记忆（memSection 尾部）。
- **消息序**（`agent_loop.dart:235-239`）：`System → history → User`。
- **工具序**（`chat_page.dart:997-1002`）：`focusedSchemas() → DiscoveryExecutor.staticSchemas() → skills.activationToolSchema() → MemoryToolExecutor.toolSchemas()`。
- **记忆置尾护缓存**（`memory_store.dart:546-547`）：动态增长面放尾部，护住前缀。

### 7.2 五铁律对照

| # | 铁律 | goodhub 现状 | 结论 |
|---|---|---|---|
| 1 | 前缀不夹动态参数 | `_systemPrompt` 是 `static const`；`_fmtTime`（`chat_page.dart:283`）仅 UI 气泡用；记忆置尾部 → 静态前缀字节稳定 | ✅ 已满足（待核 `composeSystemPrompt` 不注入时间戳） |
| 2 | Schema 确定性序列化 | `focusedSchemas()` 在 `use_server` 切换时整段重排；`activatedServers` 集合迭代序随成员变化可能漂移 | ❌ 缺口（见 §7.4 G-Tools） |
| 3 | 跨厂商 ≥1024 门槛 | 未主动把静态前缀堆过门槛；短会话 System 可能 <1024 不触发 | ⚠ 观察项 |
| 4 | 阶梯式打标 | `trimMessagesToWindow`（`context_governor.dart:41-57`）是**滑窗丢弃最旧轮** → 每 `windowRounds` 轮历史块整体平移，缓存边界失效 | ⚠ 与阶梯式相反（见 §7.5 权衡） |
| 5 | 心跳保活 TTL | 无 | ❌ 缺失（仅长会话大上下文需，低优先） |

### 7.3 致命缺口：未设 `cache_control` 断点

全仓搜 `cache_control` 唯一命中是 `gateway_server.dart:165/226` 的 `HttpHeaders.cacheControlHeader`（SSE 响应的 HTTP `no-cache`），**与 LLM 前缀缓存无关**。即：即便前缀稳定，**Claude 当前零缓存收益**（Anthropic 必须显式标 `cache_control:{type:"ephemeral"}`），OpenAI 仅自动命中 ≥1024 前缀。这是降本第一杠杆。

### 7.4 G-Tools：工具序确定性（随 §1/§2 重构一并修）

新模型「host 常驻 + 全部 public 常驻 + 单一 active private」恰是缓存最优结构。工具序应改为：

```
[ 所有 public 按 (serverId, toolName) 确定性排序 ]   ← 固定前缀，可缓存
→ [ 单一 active private 的 schemas（确定性尾部） ]     ← 切私有域只动此处
→ [ meta / skill / memory 固定尾 ]
```

切换私有域只改尾部 private 块，public 前缀稳定命中；比现有 `focusedSchemas()` 独占式重排（切服务器整段洗牌）大幅改善。需在 `CloudToolSchema` 序列化与 `ToolRouter` 装配两处固化排序（Dart `jsonEncode` 保 Map 插入序，故只要装配序固定即字节稳定）。

### 7.5 用户拓扑 vs goodhub「记忆置尾」的张力澄清

用户拓扑把「workspace 背景」置位置 3（history 前）。goodhub 在**消息层已是 System(含记忆)→history→user**，满足「记忆在 history 前」。张力只在 System 块**内部**：goodhub 把记忆放块尾（动态最后），恰是铁律 1「动态最后」的正确应用，**非矛盾**。最优断点策略：
- 断点 A（唯一）：在「静态角色 + skills」之后、「记忆」之前 → 静态前缀恒缓存（记忆增长不波及）；工具列表独立断点见 §8.1 B2。
- Anthropic 支持多断点（断点 A 静态前缀 + §8.1 B2 工具列表），分别同标；OpenAI 按最长前缀自动命中。

> 断点策略结论：仅留断点 A。记忆随对话自然流淌、不为其建独立缓存，故 In-band 提取改写 `memSection` 不会顶掉断点 A 的静态前缀边界，无 re-cache 写入费倒贴风险。

### 7.6 滑窗 vs 阶梯式权衡

`trimMessagesToWindow` 丢最旧轮换来 token 体积控制（architecture §12 预算纪律），代价是历史块缓存每 `windowRounds` 轮失效一次。System 静态前缀不受影响（始终缓存）。阶梯式冻结能进一步护住历史块，但需多付旧轮 token。**建议**：默认维持滑窗（System 前缀已降本大头）；仅当实测单会话上下文 >30k token 且跨多轮时，评估「前 K 轮冻结为固定块 + 滚动窗口只作用在 K 之后」的混合策略。

### 7.7 计费透明（用户 §四）未落地

无「缓存输入 Token 拆分计费 / 倍率折算」呈现。与 §3 记忆 UI 同属产品增强批，可一并排期（透明化拆分计费最易建立用户成本控制心智）。

### 7.8 落地优先级

| 优先级 | 项 | 落点 |
|---|---|---|
| P0 | LLM 缓存断点（`cache_control` ephemeral / OpenAI 自动） | `CloudChatRequest`/`CloudChatMessage` 增断点字段；System 静态前缀打 A 点 |
| P0 | 工具序确定性（G-Tools） | 随 §1/§2 三段式重构（`ToolRouter` 装配固化排序） |
| P1 | 静态前缀堆过 1024 门槛 | 合并 few-shot / 工具描述，确保短会话也能触发 |
| P2 | 滑窗→阶梯式混合评估 | 仅大上下文会话 |
| P3 | 心跳保活 + 计费透明 | 长会话 / 产品增强 |

> ADR：D-G = 「Prompt Caching 以显式断点 + 工具序确定性为第一杠杆，记忆置尾策略维持（与铁律 1 一致）」——状态 ✅ 锁定方向，P0 待排期。

---

## 8. 改进点登记（Backlog，供整体评估）

> 把 §7 的 P0 落点为可执行的改进条目。每条含：动机 / 改动点（锚定 `lib/` 真实结构）/ 验收 / 依赖。评估文档时据此核对「设计 → 落地」缺口。

### 8.1 P0-CACHE-1：LLM 前缀缓存断点落地

- **动机**：§7.3 致命缺口——全仓未标 `cache_control`，Claude 当前零缓存收益。
- **现状结构**（`lib/llm/cloud/cloud_llm.dart`）：`CloudChatMessage` 为 sealed 类，`SystemMessage` 仅单 `content` 字符串（:79-83）；`CloudChatRequest` 持 `messages` + `tools`（:135-144）；各厂商客户端自行映射线格式。
- **改动点**：
  1. **模型无关层**：`CloudChatMessage` 基类增 `final CacheControl? cacheControl`（默认 `null`=无断点）；`enum CacheControl { ephemeral }`。
  2. **Anthropic 客户端**（`anthropic_chat_client.dart`）：序列化时把 `cache_control:{type:"ephemeral"}` 挂到该消息对应内容块；`SystemMessage` 映射为顶层 `system:[{type:"text",text,cache_control}]` 数组形式（Anthropic system 非 role 消息）。
  3. **OpenAI 客户端**（`openai_chat_client.dart`）：忽略该字段——OpenAI 按最长前缀自动命中（≥1024），只需保证前缀字节稳定（现状已满足：System `static const` + 记忆确定性渲染）。
  4. **断点落位（单请求硬性 ≤3，防超 Anthropic 上限 4 报错）**：以 §7.5「断点 A」为准——**B1 置于 System 块内「静态角色 + Skills 之后、记忆之前」**（记忆增长不顶掉缓存边界，静态前缀恒命中）；`SystemMessage` 拆为 `[静态角色+skills]` + `[记忆]` 两块，Anthropic 每块独立 `cache_control`，OpenAI 侧无差异（自动前缀）。§8.1 初版「单断点置于整个 System 末尾（含记忆）」降级为最简过渡变体，缓存收益略低但实现最简。
  **B2（P0-CACHE-2 落地后）**：`tools` 数组整体末尾标 `cache_control`（`CloudToolSchema` 列表占 1k~3k tokens，打于此可让工具定义稳吃 90% 折扣）；必须与 §8.2 同批（工具序不定则缓存命中即碎）。
  **B3（可选 / 未来）**：历史滑动窗口倒数第 2 轮标断点，保留给未来「阶梯式冻结」（§7.6）——当前默认滑窗不启用。
  5. **断点计数护栏**：组装请求处加断言 `breakpointCount <= 3`（B1+B2 = 2，启用 B3 时 = 3），始终留余量低于 Anthropic 硬性上限 4；超限在开发期即报错 + 记 `[DEGRADE]` 日志，杜绝后续迭代误加第 4、5 个断点导致整请求 `invalid_request_error`。
- **验收**：
  - 同会话第二轮起，Anthropic usage 出现 `cache_read_input_tokens > 0`；首轮出现 `cache_creation_input_tokens > 0`。
  - 无缓存支持的 provider 行为零变化（字段被忽略）。
  - 静态前缀字节一致性单测：同输入两次组装 System 字符串相等。
- **依赖**：§8.2（工具序确定性）同批更优——先固化工具序，再打点，避免断点落在漂移段。
- **风险**：System 拆块增加序列化复杂度。断点上限已升格为硬性 ≤3 护栏（见改动点 5），不再依赖人工守 4 上限；记忆随对话自然流淌、不为其建独立缓存，故 In-band 提取改写 `memSection` 不波及断点 A 静态前缀边界。

### 8.2 P0-CACHE-2：工具 Schema 确定性排序（G-Tools）

- **动机**：§7.2 铁律 2 / §7.4——`focusedSchemas()` 在 `use_server` 切换时整段重排，缓存全洗牌。
- **改动点**：
  1. `ToolRouter` 装配改为三段式（对齐 §1/§2）：`[全部 public 按 (serverId, toolName) 排序] → [单一 active private 尾部] → [meta/skill/memory 固定尾]`。
  2. `CloudToolSchema` 列表序固化（装配序固定即字节稳定，见下 3）。
  3. **`CloudToolSchema` 规范 `toJson` + 递归键序归一（缓存命中的隐藏前提）**：当前 `cloud_llm.dart:115-132` 的 `CloudToolSchema` **无 `toJson`**，序列化在 provider 客户端现拼，且 `parametersSchema` 是上游 MCP 服务端原样返回的 `Map`，键序不可控 → 即便列表序固定，单条 schema 内部字节流仍不恒定，工具缓存命中即碎。落地：① 给 `CloudToolSchema` 加规范 `toJson`，固定一级键插入序 `name` → `description` → `input_schema`；② 对 `parametersSchema` 递归按 key 字典序归一（含 `properties` 内各字段）；③ `annotations` 不进云端序列化（沿用既有本地裁决语义）。
- **验收**：同激活集两次 `toolsProvider()` 输出列表顺序与字节一致；切换私有域时 public 前缀不动。
- **依赖**：§1/§2 三段式重构（`activePrivateServerId` 单一槽位）。

### 8.3 P1-CACHE-3：静态前缀堆过 1024 门槛

- **动机**：§7.2 铁律 3——短会话 System 可能 <1024 不触发缓存。
- **改动点**：合并 few-shot 示例 / 工具描述进静态前缀，确保稳定 >1024 token；measurable via `estimateTokens`。

### 8.4 P2-CACHE-4：滑窗 → 阶梯式混合评估

- **动机**：§7.6——`trimMessagesToWindow` 每 `windowRounds` 轮历史块平移失效。
- **改动点**：仅当单会话上下文 >30k token 时，评估「前 K 轮冻结为固定块 + 滚动窗口仅作用于 K 之后」。

### 8.5 P3-CACHE-5：心跳保活 + 计费透明

- **动机**：§7.2 铁律 5 / §7.7——未落地。
- **改动点**：长会话大上下文后台轻量 Ping 续期缓存；计费流水拆分「常规/缓存」Token 单价或倍率折算。

> ADR：D-H = 「P0-CACHE-1/2 作为首批落地项，断点打在 System 静态前缀；记忆置尾策略维持，双断点拆块留作可选增强」——状态 ✅ 已登记，待排期。

---

## 9. 边界防御与物理落盘契约（生产盲区补全）

§1–§3 定核心逻辑、§4 串联、§5 决策、§6 开放问题、§7 缓存、§8 Backlog 之外，补齐 5 处工程边界与盲区。缺任一处，系统在「用户中断流式 / 切换私有服务触发 API 400 / 恶意注入标签 / 对接非 Claude 模型 / 会话事实落盘」时即崩溃或数据污染。

### 9.1 Tool Pairing 合成桩契约（脱敏投影成对协议）

- **现状已兜住的部分**：`trimMessagesToWindow`（`context_governor.dart:35-57`）裁切点只落在 `AssistantMessage` 边界，**绝不**把 `assistant(tool_calls)` 与其后 `ToolResult` 拆开，故「滑窗裁剪导致 400」已被现有纯函数兜住。
- **真实缺口**：§2.4 投影平面隔离（D-D 待排期）在切换私有域时对历史做脱敏，**绝不能直接物理删除 `tool_call` / `tool_result`**。OpenAI / Anthropic 严格校验成对性——`assistant.tool_calls[].id` 必须被 `role: tool` 的 `tool_call_id` 匹配；删任一方或名字不匹配 → `400 Bad Request`。
- **规范（Synthetic Masking 合成桩）**：网关发送投影脱敏历史时，保留 `id`、替换函数名与参数为占位桩，`tool_result` 严格保留 matching `id` 并填入标准说明常量：
  ```json
  // Assistant 侧：保留 call_id，替换函数名与参数
  { "role": "assistant", "tool_calls": [{
      "id": "call_gh_123", "type": "function",
      "function": { "name": "redacted_private_tool", "arguments": "{}" } }] }
  // Tool Result 侧：严格保留 matching id，内容替换为标准说明
  { "role": "tool", "tool_call_id": "call_gh_123",
    "content": "[System Notice: The output of this private tool execution has been masked because the active workspace domain was switched.]" }
  ```
- **归属**：随 §2.4 / D-D 落地实现，**不阻塞 §3**。

### 9.2 FSM 生命周期与中断清理（Abort & Discard）

- **现状已立的部分**：§3.3 原子提交已规定「未收到严格闭合 `</workspace_update>` 前**绝不**写 `MemoryStore`；`jsonDecode` 失败静默丢弃 + Debug 日志」——黄金法则已立。
- **真实缺口**：`agent_loop.dart:267-277` 的 `_aborted` 分支把部分产出作为普通 `assistant` 消息入历史，但**未重置 FSM 缓冲**；用户点击 Stop / 网络掉线时，挂起的 `pendingBuffer` / `jsonBuffer` 残留，重试会混入新输出 → 脏解析、甚至误提交。
- **规范（FSM 生命周期生命线）**：
  ```
  onUserCancel / onConnectionDrop:
    1. 立即 abort 底层 HTTP/SSE 请求流
    2. discard(fsm.pendingBuffer)   // 丢弃挂起的待判定字符
    3. discard(fsm.jsonBuffer)      // 丢弃未闭合的 JSON 字符
    4. 回滚本轮对 MemoryStore 的一切写事务（§3.3 已限定仅闭合才写，此处为防御双保险）
    5. UI 侧只保留已确认 flush 出来的纯文本内容
  ```
- **黄金法则（重申）**：只有在接收到**严格匹配的 `</workspace_update>`** 且 `jsonDecode` 完全成功后，才触发数据库写事务。

### 9.3 防 Prompt 注入与标签逃逸（Tag Escaping）

- **隐患**：用户手机端输入含 XML 标签的内容（如让 AI 解释含 `<workspace_update>` 的代码）或恶意构造提示词，Demuxer 误把复述内容当元数据 → UI 文本被误吞、状态机被覆写。
- **规范**：
  1. **输入端消毒**：用户 `Message` 组装 Prompt 时，对其中的 `<` 做实体转义（`&lt;`）。效果——只有模型**自身故意生成**的裸 `<workspace_update>` 能触发提取；用户提供的标签被转义后永不命中。
  2. **输出防伪（静态版本化命名空间）**：采用 `<workspace_update_v1>`（**非动态轮次哈希**——模型难稳定复现、易碎）；解析器只认 `v1`，旧/伪造格式一律按普通文本。
  3. **非法作用域丢弃**：§3.5 G4 `scope` 校验已覆盖（模型幻觉 `scope` 直接丢弃），此处引用不重复。
- **结论**：恶意标签经「输入转义 + 命名空间版本化」双重失效。

### 9.4 多 Provider 缓存与工具适配层（Gemini / DeepSeek 等）

- **现状缺口**：§8.1 只对比 Anthropic / OpenAI；`CloudChatClient` 抽象层当前**无 capability 标记位**。
- **规范（ProviderCapability 标记）**：在客户端抽象层（或工厂）增加能力标记：
  ```dart
  abstract class CloudChatClient {
    bool get supportsExplicitEphemeralCache; // 仅 Anthropic = true（ContentBlock 级打点，上限 4）
    bool get requiresDeterministicPrefixOnly; // OpenAI / DeepSeek = true
  }
  ```
  - **Anthropic (Claude)**：显式 `cache_control: {"type": "ephemeral"}`，ContentBlock 级精准打点（受 §8.1 硬性 ≤3 护栏约束）。
  - **OpenAI / DeepSeek**：全自动前缀匹配（门槛 1024 tokens）；客户端**绝不可发送 `cache_control` 字段**（否则 `400`）；仅需确保头部字节绝对恒定（沿用 §8.1 改动点 3）。
  - **Gemini**：仅做无状态标准调用，**不建显式缓存生命周期**（无 `CachedContent` RPC 创建 / TTL 心跳 GC / 显式销毁），缓存收益主动舍去；作为普通 provider 接入即可，不并入两个布尔。

### 9.5 G3 物理 DDL 与覆写约束（会话级事实库）

> **[实现修正 2026-10-15]（pending-confirm CM1 已按默认建议确认走文件型）**：
> 全仓无 sqlite 依赖、`MemoryStore` 为纯文件栈——本节 SQLite DDL 由**文件型
> KV 等价实现**替代（`lib/sandbox/workspace_state_store.dart`：每会话一
> JSON + `SequentialFileWriter` 原子重写 + 读改写串行链）；`INSERT OR
> REPLACE` = 同 key 整行覆盖、`DELETE` = 按 key 删除、`updated_at` = 毫秒
> 时间戳，语义同构零新依赖。若后续出现键序范围查询诉求再评估迁 sqlite3
> （API 不变，改动收敛在单文件）。

- **定位**：G3 会话级事实库 = per-conversation store。按 §3.6 分工，`user` / `srv:` 走**既有 `MemoryStore`**（已实现），本表**只承 `session` 域**——故 DDL 去掉 `scope` 列（或恒为 `session`），避免按 `conversation_id` 分片跨会话/跨服务的 `user`/`srv:` 语义冲突。
- **DDL（修正版）**：
  ```sql
  CREATE TABLE IF NOT EXISTS workspace_states (
    conversation_id TEXT NOT NULL,
    state_key       TEXT NOT NULL,
    state_val       TEXT NOT NULL,
    updated_at      INTEGER NOT NULL,
    PRIMARY KEY (conversation_id, state_key)
  );
  CREATE INDEX IF NOT EXISTS idx_ws_states_lookup
    ON workspace_states(conversation_id);
  ```
- **覆写 / 删除逻辑（SQLite 合法写法）**：YAGNI 行级锁已砍（`is_locked` 整列移除），用户纠错走 UI「删除（✕）」而非锁定；主键冲突即整行替换：
  ```sql
  -- upsert（action = "upsert"）：主键冲突整行替换（SQLite 3.24+ 原生语义）
  INSERT OR REPLACE INTO workspace_states(conversation_id, state_key, state_val, updated_at)
   VALUES (?, ?, ?, ?);
  -- remove（action = "remove"）
  DELETE FROM workspace_states
   WHERE conversation_id=? AND state_key=?;
  ```

---

## 10. 系统级功能补全（移动端韧性 / 并发编排 / 上下文治理）

§9 补齐协议、安全、缓存、状态机边界后，真实移动端 Agent 体系仍有 3 处本期须补模块 + 1 处明确 Deferred（HITL 门禁已落地，见 §2.2 注记，不在此列）。

### 10.1 移动端生命周期与重连韧性（Lifecycle & Reconnect）

- **现状缺口**：全仓无任何 `AppLifecycleState` / `WidgetsBindingObserver` 钩子（`chat_page.dart` 仅用 `WidgetsBinding.instance` 做滚屏回调）；网关层无 ping-on-resume、半开 SSE 探测、unreachable 降级。
- **本该有的机制**：
  1. **生命周期钩子**：监听 `WidgetsBindingObserver`；App 压入后台（`paused` / `inactive`）优雅暂停心跳；恢复前台（`resumed`）时网关主动发轻量 `ping`，失败在 ~200ms 内静默重连。
  2. **优雅降级与熔断**：活跃私有 MCP 不可达 → 标记 `unreachable`，向用户返回可重试提示，并暂时降级为仅运行 Public 工具，不卡死主对话。
- **归属**：网关连接管理层（与 §9.1 投影脱敏、§7 缓存同属基础设施韧性），当前阶段优先补。

### 10.2 并行 Tool 编排与聚合容错（Parallel Orchestration）

- **现状缺口**：`agent_loop.dart:294` 为**串行** `for (final call in calls) { await _executeWithBreaker(...) }`；模型单轮多 `tool_calls` 时用户等待成倍拉长。
- **已具备的部分**：逐调用容错已落地——`_executeWithBreaker`（`:343`）将异常收敛为 `is_error` `ToolResult`；历史侧配对逻辑（`:385-391`）已支持多 `tool_result`。
- **本该有的机制**：
  1. **并发派发**：按命名空间拆分后 `Future.wait([callA, callB, callC])` 并发投递下游对应客户端。
  2. **独立容错与全量回填**：LLM API 要求所有发起的 `tool_call_id` 必须 100% 收到对应 `tool_result`；任一子工具超时 / 崩溃，网关须包装为标准失败 Result（**不得向上抛异常断开流**）：
     ```json
     {"tool_call_id": "call_2", "is_error": true, "content": "Timeout after 5000ms"}
     ```
- **归属**：消息管线核心，当前阶段优先补（与 §9.2 FSM、§3 提取直接挂钩）。

### 10.3 MCP 全协议覆盖（Resources & Prompts，明确不在本期范围 / Deferred）

> ⚠ **明确不在本期范围（Deferred）**：开源生态 95%+ MCP Server 仅实现 `Tools`，不暴露合法 `Resources` / `Prompts`；且资源读取（`read_file` 等）可由标准 Tool 覆盖，平行开 Resource 管道只会加剧移动端 UI 拥挤。Goodhub 本期**专注且仅专注于 Tools 维度**的调度治理；本节仅作未来备查，不进主线 backlog。

- **现状缺口**：SSOT 全程聚焦 `Tools`；官方 MCP 三大支柱的 `Resources`（资源 URI）、`Prompts`（模板 / 斜杠指令）未在网关或文档中建模为一级能力。底层 `server_capabilities` / `sampling` / `progress` 已有 plumbing，但 UI 侧 Resource Picker / Slash Commands 未规划。
- **潜在机制（仅备查，非本期实现）**：
  1. **资源附件栏（Resource Picker）**：输入框 `@` 唤起已挂载 MCP 的 Resources 列表，点击将资源 URI 挂入当前对话。
  2. **斜杠指令（Slash Commands）**：输入 `/` 列出当前激活私有域 + 公共域提供的 MCP Prompts，点击自动补全预置输入，提升移动端打字体验。
- **归属**：明确不在本期范围（Deferred）——生态稀疏 + 移动 UI 拥挤；未来若确有 Resources 型 MCP 接入诉求再评估立项。

### 10.4 超大 Tool Result 网关级硬截断（Tool Output Compaction）

- **现状缺口**：`context_governor` 仅提供模型摘要路径（`_governedContent`，`agent_loop.dart:413-435`）。该路径有两条「原文直出」旁路——`summarizer == null`（纯云 / 测试路径，`:415`）与摘要失败（`:421-422` DEGRADE 保留原文）。即 `fetch_web_page` 返 2w tokens 原始 HTML、`select *` 吐几千行 JSON 时，在缺端侧引擎或摘要失败时**零上限直入上下文**，击穿单轮窗口与预算。模型摘要是「聪明但非硬保证」,缺确定性物理地板。
- **本该有的机制**（确定性硬地板，与摘要正交、始终生效）：
  1. **硬截断层前置**：在 `_governedContent` 入口，无论 `summarizer` 是否可用，先按物理阈值截断，保证最终回填**永不超越上界**。
  2. **物理阈值**：`kToolResultHardCap = 2000 tokens ≈ 8KB`（可调，`T-调参`）。
  3. **Head/Tail 折叠**：超出时保留前 50 行 + 后 20 行，中段插入系统注记：
     ```
     [... Output truncated: 18,400 characters omitted. Use specific filter or offset/limit to read more ...]
     ```
  4. **与摘要协同**：先硬截断保上界；`summarizer` 可用时再对截断块做二次摘要（更省 token）。`summarizer == null` / 失败路径直接采用 head/tail 折叠结果，**不再回退原文**。
- **归属**：上下文治理层（`context_governor` / `agent_loop` 回填前），与 §7 滑窗裁剪、`ToolResultSummarizer` 同域；当前阶段优先补（P0 稳定性，防爆窗）。
