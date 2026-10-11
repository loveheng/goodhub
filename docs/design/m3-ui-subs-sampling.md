---
status: draft
updated: 2026-10-11
---

# M3 施工设计：UI 全量 · Subscriptions · Sampling

> 里程碑范围锚点：[architecture.md §6 分期路线](../product/architecture.md)。本文件是 M3 的内容 SSOT（范围/施工分解/定稿即写即落），memory 只记状态与指针。
> 立项：2026-10-11，自 M2.5（m2-5-skill-refstore）收官移交。状态 `active`——**T1~T5 实施完毕**（2026-10-11，双仓全绿 + 真机联调第二批大部通过，勾稽见 §5）；待补：$ref 句柄注水真机路径（待端侧摘要器实证）。

## 1. 范围（五项，来源标注）

| # | 项 | 来源 | 边界注记 |
|---|---|---|---|
| 1 | AgentLoop 事件流扩展（`LoopToolProgress`）+ 操作轨卡状态机全量 | M2.5 T7 归位 | `Running(progress)` 态 + 疑似卡死阈值；progress SSE 收侧（`callWithProgress`）已就绪，缺宿主呈现面。D2 拍板语义：心跳帧与卡死判定正交 |
| 2 | `$ref` put 端接线（Skill 编排） | M2.5 T3/T4 归位 | RefStore 现只落不取的另一半——工具出参转句柄的写入端；联调第二批场景（$ref 注水）依赖此端 |
| 3 | 跨源授权卡 UI | M2.5 T4 归位 | `CrossSourceDelegate` 现缺省 fail-closed 无 UI 通道；授权卡 preview 300 字符封顶已由 T3 钉死；真场景需多 Server 接入 |
| 4 | Skill 覆写编辑 UI（服务大厅） | M2.5 T6 归位 | `CowOverridesStore`/`CowSyncService` 已落地（覆写优先/一键重置/major 告警三分支），缺编辑面；`create_skill` 本期仍剥离（architecture §1：M3+ 带内容审计门禁复评） |
| 5 | Subscriptions + Sampling（配额制） | architecture §6 | goodshare capabilities 未声明（契约 §3.6 明确归 M3+）；宿主侧 sampling 消费 + resources/subscribe 订阅 |

联调第二批场景随 #1/#2 排（M2.5 联调遗留）：L2 确认卡（M2 已验，M2.5 未动网关不重测）、progress 药丸中途帧、$ref 注水。

## 2. 现状取证（2026-10-11，M2.5 交付面）

- **协商**：`ServerCapabilities` 防御解析（字段缺省 = 无能力 = Polyfill）+ `negotiate()` 握手缓存幂等；Tier 1 = prompts+resources 齐；sampling/subscriptions 不入判定不入 capabilities。
- **progress**：`callWithProgress` SSE 流式分帧收侧（progress 帧即达即回调/心跳忽略/空行断帧/无终帧抛协议违规）+ 单 JSON 回退；`McpToolFace.onProgress` 通道（null 不注入 token，opt-in）；debug 页药丸仅 done 态最小呈现。
- **$ref**：`RefStore`（`$ref:<server>:<id>` 句柄、TTL 30min 联动删 tmp、>1MB 落盘 fail-fast）+ `HydratingExecutor` 同源静默注水 + 查无立即 isError + 跨源缺省 fail-closed——put 端（出参 → 句柄）未接线。
- **Skill**：`SkillRegistry` 三级 + `activate_skill` 元工具本地拦截 + builtinSkills 四条 + `CowSyncService`（prompts → `cow/<name>` appScoped、min_hub_version 闸、major 告警三分支）——覆写编辑无 UI。
- **goodshare**：Tier 声明 tools+prompts+resources；prompts/resources/SSE 帧流已提交（3e1094f）；sampling/subscriptions 零实现。

### 2.1 评审轮取证补遗（2026-10-11，三路并行取证）

- **T1 传输级缺口（主要工程量）**：goodshare 无 GET SSE 下行通道（非 POST 一律 405，`mcp_server.dart:76-79`；progress 仅请求作用域内夹带，`_streamingToolCall:146-199`）——订阅主动推送无承载面；server→client 反向 request 全仓零路径，宿主 `callWithProgress` 收侧仅认 `notifications/progress` 帧（`mcp_client.dart:160-169`），其余帧一律按响应解析——sampling request 帧会被误当畸形响应，须先建双向分派。
- **capabilities 声明点**：goodshare `initialize` 内联返回（`mcp_server.dart:203-214`），守卫钉子 `test/mcp_server_test.dart:222` 断言无 sampling（T1 翻转）；宿主 `ServerCapabilities` 仅三字段（`server_capabilities.dart:20-39`），isTier1 = prompts+resources 齐，加字段不动 Tier 语义。
- **T2 现状**：AgentLoop 事件四类 sealed、工具执行裸 await 全链零超时（`agent_loop.dart:184`）；progress 收侧/onProgress 通道/药丸映射已就绪但仅 done 态最小呈现；TaskLoopService 5s 心跳是服务端租约语义，与工具级卡死判定正交无耦合。
- **T3 现状**：`RefStore.put` lib/ 零调用（仅测试）；摘要化回填已落「宿主注：原文未入上下文」标记（`context_governor.dart:22-26`，注释明言 $ref 引用归 M3）——put 端自然挂点。
- **T4 现状**：服务大厅不存在（lib/ 仅 main.dart + debug 页）；`CrossSourceDelegate` 仅 debug 页内联闭包无具名类；`CowMajorJumpDelegate` 接 null（静默保留+刷基线）；装配链唯一落点 debug 页（Gateway → RefStore → HydratingExecutor → SkillActivationExecutor）。
- **契约落点**：ai-app-split.md §3 节号至 §3.9，新节自 §3.10 起（「M3 增量」编号风格）；§3.6「sampling/subscriptions 不声明」/§3.8「无 subscribe」须同批修订；ai-dev-spec §4 无配额类既有立法（仅耗时操作 Job 化口径），新增约束须同步 goodhub `coding-standards.md` §7 采纳条款。

## 3. 施工分解（注记已落评审轮，拆解即开工）

依赖排序初排（#1/#2 是宿主呈现主线，#5 是 goodshare 协议线，两者可并行）：

| 任务 | 内容 | 仓 |
|---|---|---|
| T1 | goodshare subscriptions + sampling capabilities 与 server 实现（配额制）+ 契约扩展（ai-app-split.md 新节） | goodshare |
| T2 | `LoopToolProgress` 事件流 + 操作轨卡状态机全量（Running(progress)/卡死阈值）+ 联调第二批场景接线 | goodhub |
| T3 | `$ref` put 端接线（工具出参 → RefStore 句柄，Skill 编排消费） | goodhub |
| T4 | Skill 覆写编辑 UI（服务大厅）+ 跨源授权卡 UI | goodhub |
| T5 | 收官：双仓全量验证 + 真机联调第二批 | 双仓 |

### T1 注记（goodshare：subscriptions + sampling + 契约扩展）

- **capabilities 声明**：`initialize` 返回增 `'sampling': {}` 与 `'resources': {'subscribe': true}`；守卫钉子 `test/mcp_server_test.dart:222` 同步翻转。
- **下行通道（主要工程量）**：新增 GET /mcp SSE 长连接承载 server 主动帧（`notifications/resources/updated` 等无请求作用域通知），类头「v1 不做服务端主动推送」注释与 405 分支（`mcp_server.dart:76-79`）同批修订；鉴权沿用 Bearer；重连语义（宿主指数退避重连 + 订阅状态重放）落契约节定稿。
- **sampling 反向请求形态**：**请求作用域内夹带**——server 在 tools/call 的 POST 响应 SSE 流内发 sampling request（id 关联，复用 M2.5 ADR-007 帧间夹带先例），宿主 `callWithProgress` 增 request 分派分支；GET SSE 通道仅承载订阅通知。理由：sampling 天然发生在工具执行期（宿主必然在线），不依赖独立下行通道。
- **最小消费工具（已定并实施）**：`ai_suggest_tags`——同步只读 sampling 工具（读条目正文 → 反向请求宿主 LLM → 同步回建议标签，不落库不入队；落库走 `extract_tags` 异步管线）；真实场景锚点 = M2 摘 LiteRT 后 goodshare 交互流的推理源 + MCP 客户端即时建议；宿主失败降级为结构化 status（不 isError 防熔断误计数）。
- **配额**：宿主侧 enforce（推理资源持有者），server 侧透传超限错误；语义 = §4 D3（已拍板）。等待期禁持 Repository 锁（ai-dev-spec §4 耗时操作 Job 化口径）。
- **契约扩展（已落）**：ai-app-split.md 新节 §3.10（subscriptions）/ §3.11（sampling + 配额语义）；§3.6/§3.8 已同批修订；readOnlyHint 白名单八项（+ai_suggest_tags）；ai-dev-spec §4 无需新约束（sampling 不触 goodshare 写路径，§7 立法前提未变）。
- **宿主配合面（已落）**：`server_capabilities.dart` 增 hasSampling/hasSubscriptions（isTier1 判定不动）；`callWithProgress` 增 server→client request 分派（`onServerRequest` 回程 POST）；`lib/mcp/sampling.dart` 消费面（配额 D3 + createMessage→引擎单发映射）；`McpToolFace` 声明 sampling 即强制流式；debug 页接线（配额页面级内存态）。
- **实施追加发现**：dart:io `HttpResponse.bufferOutput` 默认 true——M2.5 起的 SSE 帧全部缓冲滞留到连接关闭（中途帧/心跳实际从未即时到达），T1 已修（两处 SSE 起始 `bufferOutput = false`），教训入 lessons；联调第二批「progress 药丸中途帧」真机验证时此修复为前置。

### T2 注记（goodhub：LoopToolProgress + 操作轨卡状态机全量）

- **事件流**：`AgentLoopEvent` sealed（`agent_loop.dart:25`）增 `LoopToolProgress` 子类（call + progress/total/message）；数据源 = `McpToolFace.onProgress` 回调桥接入 `run()` 事件通道（StreamController 或执行段闭包 yield），事件序 `Started → Progress* → Finished`；onProgress opt-in 语义保留（null 不注入 progressToken，`mcp_tool_face.dart:94-95`）。
- **操作轨卡状态机**：debug 页 `_CallEntry` 改三段——Started 即插卡（Emerald 执行中）→ Running(progress) 更新（微型百分比，ui-design §3.1）→ 终态锁定（成功/失败/取消，终态灰阶弱化 ui-design §3.2）；色语义沿用 tokens。落点 = debug 页操作轨（正式双轨消息流不在 M3 五项范围）。
- **卡死判定**：AgentLoop 全链零超时现状（`executor.execute` 裸 await）下新增宿主侧 per 活跃调用 Timer——有 progress 通道按「最近 progress 帧」计时、无通道按总时长兜底（取值 = §4 D4）；疑似卡死 = 卡片提示 + Abort 入口强化，不自动中止（写操作半程悬挂，architecture §10 风险）；心跳帧（SSE `:` comment）不作推进证据（D2 正交语义）。**交汇点（T1 评审问答 2026-10-11）：sampling 反向请求在途时须暂停/重置卡死计时**——工具等待的是宿主自己的 LLM（宿主 `onServerRequest` 处理中是宿主可知状态），D4 的 30s 无 progress 帧口径会误报「疑似卡死」；宿主侧感知即可，无需协议变更。附带：sampling 在途期间同流的 progress/心跳帧在 socket 缓冲延迟（不丢失），对 D2 正交语义无影响。
- **Abort 链路补全（architecture §10 级联的 M3 落地段）**：UI Abort → MCP 标准 `$/cancelRequest` 下发 → 卡片 Cancelled 态（区别 Failed）；取消下发失败 `[DEGRADE]` 留痕禁静默。
- **联调接线**：progress 药丸中途帧真机验证（debug 页 onProgress→药丸映射已有，`gateway_loop_debug_page.dart:265-274`）；goodshare 侧已加**真实中途帧源**——sampling 反向请求前发一帧 `请求宿主推理中` progress 通告（T2 已实施）。
- **实施定稿（2026-10-11）**：卡抽象拍板 = 状态机抽组件单实现（`CallCard`，ui-design §3.2 语义色 + 终态灰阶锁定）、不做接口+多实现；`StuckWatcher` 纯类（D4 双档 + sampling 在途顺延）；`run()` 改控制器承载（async* 无法在工具执行 await 期间插入 progress 事件）；abort = 环边界停下（LoopFinished 收尾，在途调用结果照常回填）+ face `notifications/cancelled` 下发（architecture §10 ③，取消失败 DEGRADE 留痕）；附带修复 `notify()` 丢鉴权头（initialized 通知此前每连接必现 401 被 DEGRADE 吞）。

### T3 注记（goodhub：$ref put 端接线）

- **挂点 = context_governor 摘要化路径**：M2 已落「宿主注：原文未入上下文」标记（`context_governor.dart:22-26`）——T3 把宿主注升级为真句柄：原文 > 1000T 摘要化时原文落 `RefStore.put`（API 已有，`ref_store.dart:116`），回填 = 摘要 + 「完整原文可用 `$ref:<server>:<id>` 注水」句柄注记。与 governor 1000T 阈值共用一套判定，不新增第二阈值。
- **对齐 architecture §9**：句柄是模型侧行话，翻译责任在网关侧——put 端落 RefStore/HydratingExecutor 同域，McpToolFace 保持纯传输层不动。
- **闭环消费**：builtin skill `ref-pipeline`（`skill_registry.dart:141-179` 四条之一）文案与 put 端语义对齐核查（拆解时核对）；联调场景 = 大出参 → 句柄 → 下游工具入参注水（HydratingExecutor 读端已实现）。
- **边界**：摘要化失败 E1 兜底路径（保留原文发送）不落句柄——原文已直传，无需池化。
- **实施定稿（2026-10-11）**：`AgentLoop` 增 `refStore`/`refServerId` 参数（单 Server 阶段恒 'goodshare'，多 Server ToolRouter 时随连接装配，与 face.serverId 同口径）；`_governedContent` 摘要化成功路径 `store.put` + 宿主注升级句柄注记（含用法引导「把句柄原样作为下游工具入参传引用」）；落池失败降级为无句柄注记（摘要照常，[DEGRADE] 留痕）；`refStore` 缺省维持 M2 引用标记形态。debug 页同一 RefStore 实例接进 AgentLoop（与 HydratingExecutor 读端同池、Session 粒度 finally 即焚）。ref-pipeline builtin 文案核查：已是句柄纪律语义，无需改。测试四例：句柄生成+读端回读闭环 / E1 失败不落池 / 阈值下不落池 / 缺省回归。

### T4 注记（goodhub：Skill 覆写编辑 UI + 跨源授权卡 UI）

- **服务大厅从零建页**：本期落两面板——Skill 覆写管理 + 跨源授权卡接线；Server 节点管理/BYOK 配置面板不在五项范围，页面留导航位（`hybrid_assembly.dart:3` 预留注记不扩范围）。
- **Skill 覆写面**：数据源 `CowOverridesStore`（`cow_sync.dart:87-126`：overrideOf/setOverride/knownVersion/reset）；major 告警三分支 UI 化——`CowSyncService.sync` 接真实 `CowMajorJumpDelegate`（现 null = 静默保留+刷基线），弹卡展示差异 + 用户选择（重置/保留）；min_hub_version 不兼容项（skippedIncompatible）列表态呈现；编辑保存走 `setOverride`，Token 闸复用 SkillRegistry <300T 校验（`skill_registry.dart:59-63`）。
- **跨源授权卡**：`CrossSourceDelegate` 具名组件实现（现为 debug 页内联闭包 AlertDialog，`gateway_loop_debug_page.dart:309-327`）——Amber 警示语义（ui-design :24）+ preview 300 字符（`refPreview` 已有）+ 禁盲签（句柄不可读即拒）；权限级 = §4 D5。
- **装配一致性**：服务大厅与 debug 页共用同一装配链（Gateway → RefStore → HydratingExecutor → SkillActivationExecutor）；生产装配线（hybrid_assembly）不动。
- **实施定稿（2026-10-11）**：服务大厅 `lib/ui/services_hall_page.dart`（新建，CowOverridesStore 可注入）——面板一 Skill 覆写管理（overrideNames/overriddenAt 只读扩展 + 编辑/新建/保存 setOverride + 确认弹卡一键重置 + 空态）；面板二跨源授权语义（D5 恒 L2/禁盲签/不记忆不豁免 + 「去联调页实测」入口）；导航位 BYOK/Server 节点（M3+）。跨源授权卡组件化 `CrossSourceConsentCard`（Amber 竖条语义、禁盲签 preview 空即禁允许、无豁免勾选 D5、终态锁定灰阶审计感），debug 页内联闭包换用。main.dart 增「服务大厅」正式入口。**注记修正**：300T Token 闸只管 Global scope（skill_registry register :59-63），覆写 skill 是 appScoped 无该闸——编辑面保存校验 = 非空 + 10000 字符防呆，不套 300T。**实施发现**：cow_sync `overrideNames` 级联 `..sort()` 挂三元表达式——空表分支对 `const []` 排序抛 UnmodifiableError（页面吞成初始化失败），已修并列注释；widget 测试纪律——页面 _init/store 读写走真实文件 I/O，fake async 不驱动真实事件，须 runAsync 轮询等待窗（pumpAndSettle 只收 fake 帧不等真实 I/O，固定短窗会假失败）。

### T5 注记（双仓收官）

- goodshare：flutter test 全绿 + analyze 0；新增 subscriptions/sampling 测试（capabilities 声明、订阅生命周期与通知、配额超限错误、GET SSE 通道、sampling 反向请求闭环）；守卫钉子翻转复核。
- goodhub：flutter test 全绿 + analyze 0 issue；Tier 2 降级回归（vanilla server 无 sampling/subscribe：isTier1 语义不变、Polyfill 延续、无 progress 工具卡死兜底档生效）。
- 真机联调第二批全可视：L2 确认卡（不重测）/ progress 药丸中途帧 / $ref 注水（put 端接线后真场景：大出参 → 句柄 → 下游工具注水）。

## 4. 前置决策

- **D1 范围切分（2026-10-11 拍板 ✅）**：一期全做——单 epic T1~T5 一次排完，goodshare 协议线同程做（沿用 M2.5 ADR-007「同程做消解第二排期」先例），联调第二批随 T2/T3 收口。
- **D2 胶囊系统化（2026-10-11 拍板 ✅）**：不纳入本期——保持五项范围。ui-design §3.1 预留的 M3+ 演进（应用内胶囊 → 系统通知/悬浮形态）涉 Overlay 权限与双端纪律（iOS Live Activity 延后），独立评估后另定。
- **D3 sampling 配额语义（2026-10-11 拍板 ✅）**：per-server 滑动窗口次数制——20 次/60min 内存滑动窗口 + 单次输出 maxTokens 宿主硬顶 clamp；不落盘（重启清零，定位防滥用非计费）；超限 = JSON-RPC error（-32000 区间、message 带 hint）；独立临时会话隔离（architecture §15）+ N7 围栏自然覆盖（sampling 走云引擎单咽喉）。（否决：日 Token 预算持久化——无计费场景过度设计；会话级次数——重连即刷新防滥用面弱。）
- **D4 卡死阈值取值（2026-10-11 拍板 ✅；心跳正交语义 = D2）**：双档·仅提示——有 progress 通道 30s 无 progress 帧转「疑似卡死」（与任务心跳 30s 回收线同数量级，契约 §3.3）；无通道工具 120s 总时长兜底；只提示 + 强化 Abort 入口，不自动中止（写操作半程悬挂，architecture §10）；初值 T5 真机调参。（否决：超时自动 `$/cancelRequest`——半程悬挂风险；单档 60s——无 progress 工具误报率高。）
- **D5 跨源授权卡权限级（2026-10-11 拍板 ✅）**：恒 L2 弹卡、会话豁免不适用——豁免按工具粒度（C7），跨源风险在数据面（每张卡句柄内容不同），工具级豁免防不住；与 N7 围栏「显式确认不记忆不豁免」同精神；architecture §9 既定。（否决：同方向会话豁免——粒度与数据面错配；降 L1——违反 §9。）
- **D6 `create_skill` 复评（2026-10-11 拍板 ✅）**：本期不复评维持剥离——五项范围满载；内容审计门禁是独立设计议题（Prompt Injection 提权防护，architecture §3 裁撤理由）；Skill 来源三通道（官方预置 + CoW 同步 + UI 手动编辑）已覆盖 M3 场景，缺位无阻塞；M3 收官按「Skill 上线后真实需求验证」（分期路线）再启。（否决：本期仅出设计稿——无真实场景反推形态易过度设计；本期实现——范围膨胀，D1 五项不含。）

## 5. 验收口径（勾稽 2026-10-11 T5 收官）

- ✅ **双仓全量测试绿 + analyze 0 issue**：goodshare 795 / goodhub 278，双仓 analyze 0（T1~T4 各轮同日 verify 账本齐全）。
- ✅ **守卫钉子复核**：goodshare capabilities 翻转（sampling+subscribe 声明断言）、工具计数 37→38、readOnlyHint 白名单八项、goodhub ServerCapabilities M3 解析组——四钉全在。
- ✅ **Tier 2 降级回归（Polyfill 延续）**：六口径全有测试锚——isTier1 判定语义不变（sampling/subscribe 声明不影响）、vanilla 双 gate 默认关、无 progress 不注入 token（纯 Loading）、无 sampling 不强制流式、无通道卡死 120s 兜底档（StuckWatcher fake_async）、sampling 降级结构化 status 不 isError（goodshare 侧）。订阅消费 UI 归 M3+（gate 字段已测，未实现即天然满足）。
- ✅ **真机联调第二批（CPH2767，同机回环 + BYOK step-3.7-flash）**：
  - ✅ progress 药丸中途帧：`ai_suggest_tags` 卡 Running(progress) `0/1 · 请求宿主推理中`（goodshare 真实中途帧）+ 药丸 Emerald + [ABORT] 入口；
  - ✅ sampling 反向推理闭环：server 反向请求 → 宿主引擎推理 → 回程注回 → `status:ok, tags:[网关联调改写]`，2 轮收尾；
  - ✅ 卡状态机三段 + 确认卡终态锁定 + L2 卡/C7 勾选天然复现（add_item 写操作）；
  - ✅ $ref 注水·E1 兜底路径：摘要化未触达时原文直传（2714 字符 JSON 全文直传入库，模型行为正确、无句柄残留）——设计行为真机可视；
  - ⚠→**推迟裁决（2026-10-11 用户拍板）**：**$ref 句柄注水真机路径暂不补测**——端侧模型接入整体推迟，等全部流程走通后再接端侧（届时端侧摘要器可用即自然解锁句柄链路真机验证）；句柄机制已由单元测试四例钉死（put→read 闭环），E1 兜底路径真机可视确认正确。debug 页预填 prompt 已固化为场景 B 联调文案（含完整条目 id），端侧接入后重跑即测。
- ✅ **M3 capabilities 真机生效**：覆装后 initialize 返回 `sampling:{}` + `resources:{subscribe:true}`（旧版基线无此二项，升级前后对照确认）。
