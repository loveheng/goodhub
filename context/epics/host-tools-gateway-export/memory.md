---
dev-loop: memory
format: v1
epic: host-tools-gateway-export
total-merged: 1
last-merge: 2026-10-23
---

# host-tools-gateway-export

- [挂载] docs/design/host-tools-gateway-export.md

## 决策（已拍板）

- **装配路线**：`HostTransport implements McpTransport` → `McpClient` → `McpRuntime.mount(serverId:'host')` → `faces['host']`，复用既有挂载原语；网关核心分流零改动。保留字断言依赖 `HostTransport` 类型判定，故实现顺序为「先 HostTransport、后断言」。
- **策略投影**：`single` / `pruned` / `full` 三策略，URL 参数与代码枚举同名字面量；`initialize` 期解析 URL query 绑定进会话 handler（`ProjectionPolicy` 为不可变值对象，经 `forSession(policy:)` 传入），后续请求忽略 URL；目标未挂载返 `-32602` Fail-Fast；策略不可中途变更（沿用「PC 无权改写宿主状态」裁决）。
- **四级过滤铁律**：visibility 海关 → 私有投影防火墙 → 策略过滤 → 命名格式化；元组级结构化过滤，禁字符串 `startsWith`（否则 `host__other__tool` 类畸形名会被 `parsePrefixedToolName` 判 null）。**海关对激活私有域豁免**（2026-10-23 修「能调不能看」反向不对称：`serverId == activePrivateServerId` 不做 shared 收窄——single/private 指向私有域时目录面=调用面，设计稿铁律节同轮同步）。
- **命名空间**：本机 ToolRouter 调度无前缀；网关 `full`/`pruned` 用 `host__`；`single` 对外剥前缀，入站「先解析、后判定」补齐（已带正确前缀原样放行 → 幂等；他服务前缀拒绝；工具名含 `__` 返 `-32602`）。
- **`single` 投影即调用边界**：拒绝投影集外调用（含未投影的私有工具），系统工具零泄漏（不列出 + 调用显式拒绝）。属策略级拒绝，与「声明非 ACL」（约束 visibility 标记）不冲突。
- **Allowlist**：`kHostExportAllowlist` 静态注册表，严禁宿主 executor 全量透传；登记项逐条配齐 hints / visibility / tags；工具名禁含 `__`（**保底放单测断言**，不落运行期 throw）；空面合法不报错、仅 DEGRADE 留痕，拒塞 `host_ping` 类空操作工具。
- **pruned 保守白名单**：指定 tag 时未打标一律剔除；tags 是静态声明非运行时成本信号；当前仅宿主侧生效，不阻塞 SDK。
- **广播降噪**：`tools/list_changed` 走会话投影差分（重算投影与上次快照比对，无变化即抑制）。
- **SSOT 联动**：`docs/design/host-gateway-accessibility-memory.md` §1.4 无前缀约束已收窄至本机调度域；架构债 #15（保留命名空间无防护）随保留字断言结项。

### PR1-3 落地增补（2026-10-23）

- **三源装配**：`gateway_controller._assemble` 在本地插件 + 手填端点之后**末位**装 `faces['host']`（`McpClient(HostTransport)` → `McpRuntime.mount(serverId: kHostServerId, opsLog: opsLog, release: client.close)`）。末位 = 联邦面在前、`host__` 工具面尾部追加，`tools/list` 输出序稳定；每次装配（含包变更重扫）一并重挂——与其他源同构零特殊分支（host 面无传输资源，重挂成本可忽略）。审计由 face 自带（`serverId=host`，即设计稿「按 serverId=host 记账」的落点）。
- **执行端口 owner 住 coordinator**（新增 `lib/coordinator/host_tool_invoker.dart`）：`HostToolInvokerPort.invoke` + `assembleHostToolInvoker({memoryStore, resourceStoreResolver?})` 组装「记忆工具面（+ 可选本地资源工具面）」。网关只调一行——避免 gateway 逐个直连 `memory_tool_executor` / `local_resource_tool_executor`（白名单只 +1 件，`index.md` §1.4 类别 5 已登记）；且 `ResourceStore` 类型不出现在网关代码里（gateway → resources 本就非允许出向）。
- **无裁决铁律**（实证结论）：网关入站链路的 L1/L2 **已**由 `GatewaySecurity.guard` 在 `GatewayHandler.toolsCall` 层完成，annotations 取自 host 合成面（门禁 1 强置正是在此生效）——故 invoker 链内**严禁**再挂 `PermissionGateway`，否则 PC 会看到两次确认卡。invoker 也不自做审计（face 已记 `host`；记忆工具自身仍记 `local`，属既有行为）。
- **资源面降级**：resolver 抛错（平台通道缺失/目录不可写）→ `[DEGRADE]` 留痕 + 不挂资源工具面，**host 面照常装配**、记忆工具面不受影响；resolver 返 null 同理。非数据面降级，不阻断。
- **注入位**：`hostExportAllowlist`（默认生产静态表，单测可注非空面）+ `hostInvokerProvider`（默认 `GatewayController.defaultHostInvoker`，公开静态以便测试还原）；两者皆入 `tearDown` 还原（shared 是进程级单例）。
- **[实证修复] SSE 单帧必须带空行**：`sendStream` 只吐 `data: {...}` 一行会让 `callWithProgress` 的逐行累积永不 flush → 抛「流结束但无 result 帧」。PR1-3 的网关端到端用例当场暴露（tools/call 返回 isError），已改为 `['data: $body', '']`（同 `BinderTransport._emitFrame`），并在 `host_transport_test.dart` 补真实协议层 `callWithProgress` 回归钉子。

### PR1-1/PR1-2 落地增补（2026-10-23）

- **Allowlist 交付即空面（零登记）**：宿主现有能力（记忆读写 / 内部配置 / 未沙箱化工作区 IO）对外均属隐私降级，按设计稿「默认不登记」逐条评估后再入表——PR1-1 不擅自挑一个隐私相关工具凑数。空面在 MCP 下合法（`tools/list` 空数组 + `[DEGRADE]` 留痕）。**登记首项须同轮过三关**：① 产品价值 ② 隐私影响评估 ③ 单测断言「Allowlist 至少含一个 shared 且 `readOnlyHint: true` 的条目」。
- **门禁 1 判据**：「含 `readOnlyHint` **或** `destructiveHint` 键即视为已声明」——`{readOnlyHint:false}` / `{destructiveHint:false}` 都是显式破坏性声明，**不被强置覆盖**（否则工具面 L1/L2 语义反直觉）；只有两者皆缺（或只有 `title` 等无关键）才强置 `destructiveHint:true`。
- **门禁 2 范围扩到三个**：控制面黑名单 = `get_connected_apps` / `activate_server_tools` / `use_server`（非只 `use_server`）——前者泄露宿主私有槽位与激活集状态，后两者改写它；PC 侧私有投影切换的正道仍是 `gateway__select_private`。字面量在 mcp 域本地声明（arch-guard R5 禁 import coordinator）+ 单测与 `DiscoveryExecutor` 常量同步断言防漂移；`tools/call` 命中同样 `-32602` 显式拒绝。
- **保留字断言必须三处同点**：`McpRuntime.assemble` 的端点 / 本地插件两段是**直挂循环、不经 `mount`**（只在 `mount` 设防会被手填端点绕过去），故 `assertServerIdMountable`（静态）在 `mount` 入口 + 两段循环各设一处；`assemble` 命中按 DEGRADE 跳过 + danger 通告 + client 立即 close（宁缺勿炸：一条误配端点不炸掉整轮聊天装配）。异常类型 `ReservedNamespaceException` 落 `core/errors/mcp_error.dart`——`McpException` 是 `sealed`，跨库不可扩展。
- **能力声明克制**：`initialize` 只声明 `tools`（`listChanged:false`），**不声明 sampling / resources**——声明 sampling 会让 `McpToolFace` 对本服务强制走流式 `callWithProgress`；声明 resources 会让协议层建 GET SSE 监听。流式路径按 Binder 同款 Polyfill 口径回单帧，`getStream` 抛 `UnsupportedError` 退化为不监听。
- **端口纪律**：宿主执行面经 `HostToolInvoker` typedef（裸名 + 入参 JSON → `core/tool_result.dart` 的 `ToolExecutionResult`）注入，mcp 域零反向 import coordinator/llm；本传输无独立 dispose，释放唯一入口 = owner 调 `client.close()`。

### PR2 落地增补（2026-10-23）

- **三级纯度分工**：`projection_pipeline.dart`（纯函数 + 不可变值对象，零 IO，可独立单测）→ `mcp_gateway_handler.dart`（只接线：`policy` 字段 + `project()` 作为目录/差分/入站三处**同一投影源**）→ `gateway_server.dart`（只在 `initialize` 期绑定）。三处共用一个投影源是「目录看得到、调用被拒」不一致的结构性根除。
- **`full` 策略逐条等价**（默认暴露面零回归）：目录形态不变（仅**序稳定化为字典序**——既有测试全用 `contains`，未受影响）；入站语义**逐字不变**，含「缺服务前缀 = isError 内容回填」而非协议级 error。投影只收窄目录面，不改既有调用语义。
- **协议级 vs 策略级拒绝的分工**（设计稿未细化，本轮拍板）：走 `-32602` 的只有两类——`single` 入站补齐后**仍失败**（工具名自身含 `__`，畸形名）+ `initialize` 期非法字面量/目标未挂载；其余拒绝（他服务前缀、投影集外调用、系统工具、`full` 缺前缀）一律 **isError 内容回填 + 可自纠话术**，与既有防火墙风格一致，且不向 PC 泄露协议细节。
- **投影集签名按 `serverId/bareName`**（不含对外前缀）：故 `single` 与 `full` 对同一批工具签名相同——差分广播只认**集合变化**，天然覆盖「`single` 会话对无关服务变更无感 / `full` 会话对私有域变更无感」两类噪音。会话建立时 `markProjectionBaseline()` 打基线，避免首次目录变更必然触发一次无意义广播。
- **入站边界实时重算**：`_isProjected` 不读目录快照，每次 tools/call 现算投影——face 重扫后即刻生效，杜绝陈旧快照误拒。
- **系统工具的策略相关性**：`gateway__select_private` 在 `full`/`pruned` 追加、`single` 隐藏（不列出 + 调用显式拒绝）；系统工具不计入投影集签名。

### Allowlist 首项登记（2026-10-23 · PR3）

- **首项 = `get_host_status`**（用户拍板选第三条路径：新建只读工具而非放行既有隐私能力）。返回宿主身份 / MCP 协议版本 / 平台 / 时区 / 语言区域——**零隐私**（不含用户数据、服务清单、私有槽位态）+ **有真实推理增益**（PC 据此对齐回答语言、时区、协议兼容判断），不违反「拒塞 `host_ping` 类空操作工具」。
- **被否决候选（留档防重蹈）**：`query_memory`/`update_memory` 撞「记忆读写默认不登记」条款——是否向外部 AI 暴露宿主长期记忆属**产品定位**问题，须单独立项，不在工程侧顺手放行；`read_local_resource` 网关侧语义不成立（`resource_id` 来自聊天附件上下文，PC 连接不持有）；`get_connected_apps` 等三件已拉黑。
- **[结构修正] Allowlist 降为「导出策略声明」，schema 单点拥有**：原设计让登记项自带 `description`/`inputSchema`，会与执行器的 schema 形成**双源**（且 mcp 域禁 import coordinator，无法直接取）。改为：登记项只声明「谁能导出 / 什么 visibility / 什么 tags / annotations 覆盖」，描述与 schema 由执行面经 `HostSchemaResolver`（`{'description','inputSchema'}` JSON 形状）供给；装配层一次产出两个端口 `HostToolPorts{invoke, schemaOf}`，杜绝两套装配产出不一致的 schema 面。
- **版本必须真值**：占位版本会让 PC 的协议兼容判断产生误导，故在 `app/service_directory.dart` 新增应用级 `appVersion()`（缓存 + `appVersionOverride` 注入位 + 平台通道缺失时 DEGRADE 返 `unknown`）；UI 侧 `about_section` / `update_page` 的自读版本**后续可一并收敛**（本次未动，避免扩大改动面）。
- **§6.2 主体矩阵无需改**：执行主体经既有链路推导（入站审计 `server='gateway'` + face 自审计 `server='host'`），本工具不是网关系统工具、无特权写操作，故不新增主体枚举值；`PermissionGateway.localReadOnlyTools` 台账亦明确「不再参与裁决」，只读白名单口径未变。
- **§5.7 自查清单落地**：注册（Allowlist 登记项）→ 主体矩阵（见上，无需新增）→ 强类型参数 Schema（`{type: object}` 零参，`dynamic` 零使用）→ 契约测试（`test/coordinator/host_status_tool_test.dart` 9 例：描述引导 / 零隐私禁漏 / hint 契约 / 透传不吞工具 / 缺省走真值）。

### 用户诉求增补：`single` 直连私有服务（2026-10-23）

- **诉求**：「需要通过代理使用私有服务，公共服务不是我想要的」——即 PC 侧只想面对某一个私有服务，不愿被公共面干扰，且不应依赖宿主手动切私有域。
- **裁决（零权限扩张）**：`?strategy=single&server=<私有服务>` 直接把**本连接**投影绑定到该私有服务（连接级），PC 即见无前缀工具面并可实调。**权限集合与既有 `gateway__select_private` 逐条相同**（只改本连接投影，不触碰宿主私有槽位机）——`single` 无需先连 full 再调一次系统工具，且上下文更小。MO6「PC 不得改写宿主状态」与四级铁律均不受影响。
- **配套修正**：Fail-Fast 的「不可访问」半曾按设计稿原文（未挂载**或不可访问**）实现为「私有未激活即 -32602」，与本诉求冲突 → 收敛为「**未挂载才 Fail-Fast**」；私有目标改由连接级绑定保证可达。教训：设计稿那句「不可访问」在「PC 可自选私有投影」的前提下等价于「未挂载」，两者不可同时成立。
- **不变的部分**：宿主默认私有投影（`_hostDefaultPrivateServerId`）与 chat 页绑定链路**零改动**；单连接绑定不外溢（server 层单测断言另一 `full` 连接仍看不到该私有工具）。

### 控制面补齐：列举私有服务 + 切到单个（2026-10-23 用户裁决）

- **新增 `gateway__list_private_servers`**：列出宿主已配置的私有 MCP 服务器（`server_id` / `mounted` / `shared_tools` / `current`）。**只列 id + 在线态 + 只读工具数**——不含凭据、端点、服务自报名（可能含用户命名）或任何服务内容；PC 此前已能在 `select_private` 的拒绝话术里看到私有 id，故**不新增暴露面**。
- **`gateway__select_private` 扩 `scope` 三档**：`single`（只看该服务，剥前缀裸名）/ `private`（缺省，既有行为：联邦面+该私有）/ `full`（只看联邦面）。**推翻了本 epic 早前自拍的「策略不可中途变更」**，推翻理由已写进设计稿：被禁的 `use_server` 改的是**宿主槽位机**（跨 Run/跨会话共享），而此处改的是 **per-connection 投影**——与既有 `select_private` 同性质，权限集合**未扩张**，只是省掉「重连一次」的往返。
- **[自我纠错] single 全隐匿控制面 = 死锁**：实现后立刻被自己的单测抓到——切到 single 后 `scope=full` 回不来（该连接所有 `gateway__*` 都被拒）。修法：`single` 下**只保留 `gateway__select_private` 作唯一出口**，`list_private_servers` 隐匿（已锁定单一目标无需再选）。教训与上轮「私有未激活给空目录无法自救」同源：**任何让 PC 进入受限视图的机制，都必须自带退出通道**，否则就是把用户锁死在视图里。
- **系统工具裁剪位置上移**：`ProjectionFilter.project` 不再按策略裁剪系统工具（改为「调用方给什么就纳入什么」），裁剪责任归 `GatewayHandler.project()`——因为「single 保留哪个」是连接策略问题，不是管道问题。

### 术语纠错：列举工具从「私有服务」改为「全部已挂载服务」（2026-10-23）

- **实测暴露的问题**：`gateway__list_private_servers` 按端点隐私级别 `tier=private` 过滤 → 只装了本地插件（goodshare 等，**恒 public**）时清单为空，PC 侧 AI 转头让用户去「设置里把端点改成私有」——**工具语义与用户心智错配**。
- **两种「私有」**：① 端点隐私级别（仅手填端点可私有）② 用户口语「我自己单独用的服务」。PC 要的是 ②。
- **改法**：工具改名 `gateway__list_servers`，列**全部已挂载服务**，每条带 `tier`（private/public）+ `source`（`host` / `endpoint-private` / `public`）+ 只读工具数 + `current` / `policy_target`；切换走 `scope=single`（本就允许任意已挂载服务）。**实时现算**，宿主改完配置复查即可，无需重连会话。
- **不变的边界**：仍只列 id / 隐私级别 / 来源 / 计数——不给凭据、端点地址、服务自报名或任何内容。

### `blocked` 诊断段（2026-10-23 · 用户场景：手机装了 goodshare / shiguang 两个 MCP 服务）

- **问题**：本地插件需过信任闸门才进 `faces`。被拦下的插件在清单里**直接消失**，PC 无法区分「宿主没装这个服务」与「装了但没信任」→ 排障被支去错误方向（用户第一反应就是「清单为空」）。
- **改法**：`GatewayController.blockedPlugins`（serverId → 原因）在装配期记账（每次 `_assemble` 重建，重扫即刷新），经 handler 透给 `gateway__list_servers` 的 `blocked` 段；清单为空时也返回该段而非「宿主什么都没装」。
- **隐私边界**：只给**路由前缀 id + 原因**；**不给包名 / 签名 / Service 类名**——包名才是真正的 app 身份泄露面（可枚举手机装了哪些 MCP 服务）。id 本就出现在工具名前缀与既有拒绝话术中，不新增暴露面。

### 网关设计核查与 P0 修复（2026-10-23）

- **核查结论**：设计→实现主干已对齐（三源装配 / 四级过滤铁律 / 会话策略绑定 / 控制面三档 scope / 保留字门禁）。核查出的实现级缺陷集中在**文案层**而非逻辑层。
- **P0（旧工具名残留）**：`gateway__list_private_servers`（术语纠错前的旧名）残留在 `select_private` 描述 / `server_id` 参数描述 / 未挂载拒绝话术 / single 裁剪注释共 4 处 → PC 侧模型读描述后会照抄调用一个**不存在的工具**（幻觉调用源）。已统一改现名 `gateway__list_servers`（代码 4 处 + 设计稿 1 处 + 测试注释 1 处）。
- **防漂移铁律（新增）**：面向 PC 的系统工具文案禁引用**未声明**的 `gateway__*` 工具名——挂两条断言（`systemToolJson` 全文案扫描：出现的 `gateway__xxx` 须属已声明集合；运行时拒绝话术须指向现名）。教训：工具名是 PC 侧模型的唯一契约面，**文案里的悬空引用＝幻觉调用源**；改名类变更必须同轮扫全文案并挂断言钉子。
- **P1 两项已修（2026-10-23 核查轮）**：① **POST SSE 的 15s Keep-Alive 真 progress 帧**——`McpGatewayServer.keepAliveInterval` 可注入（默认 15s），`progressToken` 优先回显客户端 `_meta.progressToken`、缺省用请求 id；JSON（非 SSE）模式无法注入（响应体须整体写出，中途插帧破坏 JSON 单体语义）；回归钉子 `test/gateway/gateway_server_test.dart`「TC12 Keep-Alive」（**撤修复即红已实证**）。② **投影管线口径校准**——`ProjectionPolicy` 类注释改为「会话内可由本连接 `gateway__select_private(scope=…)` 改写」（推翻早前「策略不可中途变更」）；`isAccessible` 文档改为「= 已挂载」（私有服务走**连接级绑定**，无需宿主先激活）；Fail-Fast 错误话术只说「未挂载」，不再把 PC 排障支去「先激活」这条不存在的路。
- **Keep-Alive 分两通道（口径决策）**：GET 订阅通道用 `: keep-alive` **注释帧**（不计入 MCP 帧，仅喂 TCP 计时器——订阅通道无请求语义，注释帧最安全）；**tools/call 通道用真 `notifications/progress` 帧**（承载 progress 语义、PC 按 MCP 帧解析；`progressToken` 优先回显客户端 `_meta.progressToken`、缺省用本次请求 id）。**JSON 单体响应无法中途插帧**（插帧破坏 JSON 语义）→ 该模式的长调用仍有 60s 风险，靠下游 progress 与上游超时兜——已写进代码注释与设计稿，**不假装已覆盖**。
- **产品裁决落地（2026-10-23，用户拍板）· 网关鉴权默认安全化**：原「Token 留空 = 不鉴权」是**默认**行为，且网关默认监听 `0.0.0.0:8766` → 同局域网任意主机可无鉴权访问只读工具面（L1 工具不弹确认卡）。改为：**默认自动生成配对 Token**（32B `Random.secure` → base64url 无填充，起服必带 `Authorization: Bearer`），免鉴权降级为**显式**逃生口（关「自动生成」+ 留空；仅建议 ADB 转发；意图落盘 `gateway.token.authMode`，防下次开启被自动补 Token 静默推翻）。决策与生成下沉为纯函数 `lib/gateway_api/gateway_token.dart`（`resolveGatewayToken` / `generateGatewayToken`），UI 段只做编排 + 落盘 + 回填，并配「显示 / 复制 / 重新生成」控件（配对 Token 原本恒隐藏且无法复制 = 用户没法把它交给 PC）。**未采纳备选**：「仅 loopback 监听」开关——局域网直连是主用法，不可作默认。
- **剩余未修项**：设计稿已锁定但未落地项（重名仲裁 / 数据面 `mcp-blob://` / Tier B stdio / 原生 200ms 节流 / `:gateway` 双进程），见 `docs/design/thirdconnect.md` §9.3 与 §10.1~§10.5。
- **排障口径（本地 MCP 服务接不进网关时的三步，PC 侧 `gateway__list_servers` 清单为空必查）**：① 插件须在 `AndroidManifest.xml` 声明 `com.zzh.goodhub.action.MCP_SERVER` + meta-data `SERVER_ID` / `SERVER_TITLE`（否则 `discover` 扫不到）；② 同签名自动信任，**非同签名第三方须先在宿主聊天页或 ⚙ 设置 → 本地插件信任一次**（网关 headless 无 UI，无法弹信任卡片）；③ 信任后重调 `gateway__list_servers` 即可看到（实时现算，无需重连）。
- **[note] 存量 flaky**：全量测试曾观测到 1 次偶发失败（用例名未捕获，其后连跑全绿、无法复现）；新增测试的临时目录清理已改「先 `ioDrained` 排空再删」，但**不能断定归因**（疑既有 flaky），未登记为债，留待复现时定位。

### 无线「过段时间连接自动掉」修复（2026-10-23）

- **症状**：无线（局域网）使用一段时间后，PC 侧连接自动掉。三因定位：
  - **① 会话生命周期（确定性缺陷，两种表现）**：GET SSE 订阅一断即**销毁整个会话** → PC 复用旧 sid 吃 `400 unknown Mcp-Session-Id`；纯 POST 客户端 10min 无请求 → idle GC **删掉 sid** → 同样 400。两者同源：**把「连接存活」与「会话有效」绑死**。
  - **② `stop()` 并发改表崩溃（既有潜伏）**：边遍历 `_sseSubs` 边 `await resp.close()` → SSE 断连回调并发改该 map → `Concurrent modification`（由本次新增钉子当场抓出）。
  - **③ Doze 限网（G4 遗留项）**：电池优化白名单从未申请——历史「Doze 下 HTTP 200」是 **adb 写白名单**验证的，真机用户路径从未开过；息屏后系统限网 → 表现为掉线。
- **修法**：① `sid` **长期有效**（永不按时间删，只按 LRU 256 上限淘汰）· SSE 断开**只解绑订阅**（不销毁会话）· idle GC **只回收 handler 内存态**（按需重建，策略与连接级私有绑定从会话条目恢复；代价 = 该连接 L2 豁免集重置）· 心跳写失败即判定订阅已死 → 解绑订阅让 GC 接管（修半开连接的僵尸会话泄漏）② `stop()` 取副本再关闭 ③ 新增原生 `batteryExemptionStatus` / `requestBatteryExemption`（ROM 不支持申请弹窗时降级到白名单列表页）+ Manifest 权限 + 设置页「去设置」提示行（生命周期回查）。
- **核心决策**：会话「有效」与连接「存活」**解耦**——会话条目只按容量淘汰，永不按时间删除（PC 可能任意时刻回来用旧 sid，一旦 400 就是掉线体感）。
- **未覆盖因素（非代码缺陷，需真机确认）**：手机 Wi-Fi **IP 因 DHCP 租约到期而变**（PC 用旧 IP 连不上，同样像掉线）· 部分 ROM 自管后台策略杀进程 · PC 客户端自身保活策略差异。

### 投影策略单轴化（2026-10-23 用户裁决 D1 · P2 收尾）

- **裁决**：策略字面量取**并集** `single | private | full | pruned`，**URL 键与控制面参数统一为 `policy`**（PC 侧只记一套词表）；原两轴并存（`?strategy=…` 与 `scope=…`）易混，且 `pruned` 只在 URL 有、`private` 只在控制面有，语义互不对应。
- **兼容别名（向后兼容，既有客户端零改动继续工作）**：URL 旧键 `strategy=` ≡ `policy=`（同传时 `policy` 优先）；控制面旧参数 `scope=` ≡ `policy=`，但**不进工具 schema** → PC 侧看不到第二套词表。
- **`private` = 联邦面 + 私有叠加**：私有服务须由本连接显式绑定才进投影面（绑定只改本连接投影，不触碰宿主槽位机 → MO6「PC 无权改写宿主状态」不受影响）；`policy=private` 目标非私有或未挂载 → Fail-Fast `-32602`（不静默降级）。
- **`pruned` 仅连接建立期可用**（`?policy=pruned&tag=…`）：连接内切换无 tag 来源 → 控制面显式拒绝并给可自纠话术（改用 `policy=single`）。
- **工具名不改**：`gateway__select_private` 保留（工具名 = PC 侧契约面，本 epic 刚因旧名残留出 P0 幻觉调用）——只收敛参数名与字面量。
- **D3 裁决（同期）**：`mcp_gateway_handler.dart` 的投影接线**不拆**（已 612 行 < 800 软红线；管道纯函数在 `projection_pipeline.dart`、接线在 handler，分层本就正确；边际收益低于搬动 PC 可见语义代码的风险）。
- **门禁**：新增单测 19 例（解析 7 + 控制面 9 + 会话绑定 4，含「工具 schema 只暴露 policy」断言）；analyze 0 issue / 全量 1128 绿 / arch-guard OK / docs-lint OK。

### 架构评估修复轮 + shiguang 真机验收（2026-10-23）

- **评估修复轮**（全系统架构评估后用户验收执行）：D1 单轴化回写不完整 7 处清零（PC 话术旧词表 ×3 / SSOT 文档矛盾 ×4）+ 协议版本双源收敛（handler 改引 `kMcpProtocolVersion`）+ about_section 版本读取收敛 `appVersion()` + #18 续（本机工具链抽 `local_tool_chain.dart`，mcp_runtime 911→864）+ 词表层防漂移断言（变异探针实证撤修复即红）。**教训已升舱为框架级机械件**：drift-guard（引擎全局 / registry 项目 / Dart 镜像 CI），见 epic `meta-upgrade`。
- **shiguang 真机端到端**：single 投影 14 只读工具进裸名面可调、跨服务调用被拒、full 面 `shiguang__` 收窄符合「声明非 ACL」；policy=private 私有域全量进面待宿主配置私有端点后真机验证（代码路径已由单测覆盖）。

## 断点
- [断点] 下一步：装配层合一已落地（Expand+Contract，547 测试全绿）：下一步真机回归——build-apk 装机后验证聊天全链路借用路径（进度 UI/断连通告/sampling），并确认网关停服时共享 face 生命周期（_unmountAll 与在途借用会话的交互）
- [note] 旧名 `gateway__list_private_servers` 已从**代码与设计稿全量清零**（P0 已修，仅历史账与本段留档）；真机验收通过后设计稿 `status` 转 `active`，epic 归档。
