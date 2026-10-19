---
status: draft
updated: 2026-10-19
---

# Prompt 管理：全局 + 按服务 + 切换联动

## 1 背景与目标

用户诉求三分：① 每个 MCP 服务有自己的 prompt；② 存在全局 prompt（用户可建/编）；③ 切换到某 MCP 服务后自动切换 prompt 面。准入评估（solution-admission）判定 **S1 局部能力补全**：结构已有承接（SkillRegistry 三层 + CoW 管道），不引入新容器/新状态，六条否决信号全不命中。

## 2 现状承接（不改结构）

| 诉求 | 现状落点 | 差距 |
|---|---|---|
| 按服务 prompt | `cow_sync.dart` CoW 同步 → appScoped Skill（`cow/<name>`，绑 serverId）；`SkillRegistry.forServer()` | 无结构差距（Tier 2 server 天然无 prompts 面） |
| 全局 prompt | `SkillScope.global`（常驻注入，300 Token 硬预算，来源含 user） | 缺 user 来源全局 prompt 的 UI 管理/落盘入口 |
| 切换联动 | system 尾部 Run 边界重算（`chat_run_orchestrator` assembleSystemTail）；工具面三段式已随私有槽位重排（`tool_router.dart`） | appScoped 注入按 `router.serverIds` 全量注入，**未按激活私有槽位过滤** |

## 3 方案（三件事）

1. **私有槽位过滤注入（易变度分层）**：appScoped skill 注入集从「公共 + 全部已连 server」改为「公共 server 的 appScoped + 当前激活私有槽位的 appScoped」，并按易变度重排拼接序：`base 角色指令 → Global Skills（300 Token 闸）→ mountedSection/workspace 指令 → 公共 server appScoped → 私有槽位 appScoped → On-Demand/激活清单 → 记忆尾`。**空槽位确定性渲染**：无激活私有域时该块严格渲染为空串；**块内零歧义强规则**：全局/公共/私有段一律按 `'${s.serverId ?? 'global'}:${s.name}'` 字典序排序（**null 归一化**——global 段 serverId 为 null，裸插值产出 `'null:name'` 是未定义抖动源；`forServer` 保注册顺序，跨轮注册序变化即字节漂移）；段间统一 `\n\n` Join，空列表恒返回 `""`，禁悬挂换行；禁嵌时间戳等动态量。
2. **同拍原子变更**：切私有域时 `ToolRouter.focusedSchemas()`（工具尾块）与 `SkillRegistry.composeSystemPrompt()`（skill 尾块）在同一 Run 边界同时生效——缓存前缀渲染序为 `tools → system → messages`（Anthropic 官方口径：改工具定义失效全部缓存），两块分轮变会各断一次，必须合并为**单次重前缀**。
3. **user 全局 prompt 管理入口**：补 `SkillSource.user` × `SkillScope.global` 的 UI 编辑/持久化链路（受 kGlobalSkillBudgetTokens=300 注册闸约束，超限 fail-fast 不裁剪）。

**对齐 D-H 隐私模型，接受切换当轮全量重前缀**：底层 `agent_loop.dart` D-H 发送边界投影在切域时会把已让位私有域的历史 `tool_call`/`tool_result` 替换为 `redacted_private_tool` 占位桩——历史消息本就会被隐私策略改写，不牺牲工具调用质量（原生强类型 inputSchema / PermissionGateway L2 / HydratingExecutor 注水）去强求「历史纯追加」的虚假 100% 命中。低频切换（单槽位制）下单次重前缀是可接受代价。

### 3.4 透明面：提示词总览（2026-10-19 用户诉求「这些不太透明」）

三件事落地后，全局 prompt 与 MCP 服务 prompt 对用户仍不可见（注入发生在 system 尾块，用户无从得知实际生效面）。补**只读总览**——零写面，编辑仍归设置页两段（`UserPromptsSection` / `CowSection`），防双入口漂移：

- **落点**：记忆看板第 4 Tab「提示词」（`lib/ui/sections/prompts_overview_section.dart`），两分区同屏：
  - **全局 Prompt**：`builtinSkills()` 官方预置 global（恒在、常驻——最不可见的内置 prompt 首先可见）+ `UserGlobalPromptsStore` 落盘直读（user 来源 × global——与 `buildBaseSkillRegistry` 同源，落盘即注册面）；与 App 启动同源、**不依赖会话**，卡片带 `N/300 Tokens` 水位（`core/tokens.dart` 单源）与更新时间；
  - **MCP 服务 Prompt**：连接态 `SkillRegistry.appScoped()`（窗口经抽屉注入 `skillsProvider: () => session.skills`——其 globals()/appScoped() 反映当前已连接服务与静态预置，与具体会话内容无关；服务**连接**后**实际注入面**，含官方预置 + CoW 同步，徽标标注来源/服务/模板版本/本地覆写）；注册表不可用（看板先于连接打开）→ 回落 `builtinSkills()` appScoped（官方预置恒在）+ `CowOverridesStore` known_versions + overrides **落盘基线**（有本地覆写者展示覆写正文——持久生效内容；未覆写模板正文来自服务端、不落盘，走占位说明，明示「连接后展示实际注入内容」）。
- **确定性**：卡片行按 `serverId:name` 字典序（与 `composeSystemPrompt` 段内排序同口径），注册序/文件枚举序不外泄。
- **容灾**：两个 store 损坏备份路径明示（对齐 P2-1 口径）；面板级错误态 Rose + 重试，不打死看板。

## 4 备选方案评估：Tool-Search / Meta-Tool 代理模式（已否决，留档）

外部提议：顶层 tools 永久只注册 `search_tools` + `execute_mcp_tool` 元工具，具体工具按需经消息历史暴露——缓存零击穿、历史 Append-Only。**判定：否决，不作引入**，理由：

1. **问题不存在**：goodhub 从未全量注册工具——`DiscoveryExecutor` JIT 两级发现已是「半元工具」模式（`get_connected_apps` / `activate_server_tools` 常驻，激活后才挂具体 Schema），方案一解决的是我们没有的问题；
2. **频繁切换下汇率不划算**：一次切换省下的尾部缓存 miss（≈ 尾块 × 1 次，缓存价 ≈ 1/10 正常价）抵不过每个冷工具 +1 次完整模型往返；切换越频繁冷调用越多，越亏；
3. **参数幻觉**：模型不见完整 inputSchema，通用转发器不校验形态，错误直达 MCP server；
4. **门禁稀释**：PermissionGateway per-tool L2 裁决、HydratingExecutor 按 targetResolver 跨源注水，通用执行器压扁成一条通道，安全面重做；
5. **历史垃圾**：每次切换的 schema 说明永久留在 messages，频繁切换用户上下文膨胀更重（与该方案自述优点相反）；
6. **双路分支**（准入信号 #3）：与现有 DiscoveryExecutor 并存即两条工具暴露路径。

**收敛条件（何时重评）**：单服务工具量级涨到几十个且检索意图明确时，在 `DiscoveryExecutor.activate_server_tools` 内加 **query 过滤参数**（激活时只挂命中子集进槽位）——复用现有通道的 S1 局部补全，仍不引入第二条路。

## 5 非目标

- 不做 prompt 覆盖 server 版本管理（CoW 已有 override 通道）；
- 不动 tools/resources 注入语义；
- 不引入新持久层（复用 skill 现有存储）。

## 6 验收口径

- 切换私有域（use_server）后下一 Run 的 system 尾部只含新槽位的 appScoped skill，公共面不变；
- 公共服务工具面与 skill 面同步增减，无孤儿注入；
- user 全局 prompt 建编删走通，超 300 Token 被拒且有可见通告；
- 提示词总览（记忆看板第 4 Tab）：全局 Prompt 落盘面与 MCP 服务 Prompt 活态注入面可见；无活态会话时展示落盘同步基线并明示差异；
- **cached_tokens 量化观测**：以 API 返回的 cached_tokens 度量切换轮重前缀成本与缓存命中基线（非切换轮应接近全量命中）；
- 架构护栏 `toolbox run arch-guard` 与 `analyze` 通过。

## 7 远期演进项（不随本 epic 实施）

- **厂商原生 defer_loading 能力门控**：Anthropic 官方 `defer_loading` + tool search——延迟工具不进系统前缀，模型按需发现后以 `tool_reference` 块内联对话历史，前缀不动、缓存保留、支持严格语法约束。goodhub 为 BYOK 多 provider，不押注单家特性；当 `cached_tokens` 实测显示切换成本显著、且引擎/Provider 明确支持该原生协议时，按能力门控（与 sampling/网关能力协商同族）协商启用，不作为全局写死方案。
- **Warm Private Slot（热备私有槽位）**：高频交替切域（如 3 轮内 A/B 往返）场景下，装配面维持双私有槽位静态并集 + 尾部聚焦引导行，把重前缀从 N 次降到 1 次。**当前不做**：多槽位并集打破 `focusedSchemas()` 单槽契约，属 S2 结构引入；且 D-H 打桩每轮切域照打，收益被削。触发条件 = 实测高频交替切域且 `cached_tokens` 证明切换成本显著，届时重新过准入闸。

## 8 运行时弹性与护栏（防御性扫描裁决，2026-10-19）

外部防御性工程扫描 8 项，裁决：**采纳 5、收窄 2、否决 1、大半已被现有机制覆盖**。

### 8.1 已有机制覆盖（不重复建设）

- **断连韧性**：D18 断连处置（取消在途+回告不重放）、D17 重连差分清洗（下线工具剔除）、`tool_router` 路由目标缺失 isError 不抛穿执行环、UI TrackNote 回告——连接层生命周期已闭环（`connection_manager.dart`）。
- **流式中断**：Abort 级联①②③（引擎取消→MCP cancelled 通知→face 取消在途）+ P0 尾帧铁律（正常/Abort/异常三路清缓冲）已定义。
- **命名冲突**：`SkillRegistry.register` 重名抛异常拒绝 + CoW 撞名先到先得并通告——注册表唯一闸保证 `### Skill:` 标题物理唯一，模型端无同名混淆。**否决** `<serverId>.<skillName>` 物理前缀改造（无谓重工）。

### 8.2 采纳补全

1. **私有槽位指针联动断连（僵尸槽位自愈）**：D17/D18 需联动 activeSlot——激活中的私有服务掉线且重连失败时，槽位指针降级置 null，下一 Run 自动降级纯公共模式（空串渲染，§3.1），并经 `connectionReport` 端口抛出可见通告。禁止幽灵上下文（死服务的 appScoped prompt + 空工具继续注入）。**Run 边界快照隔离**：断连置空只写 pending 标记，Run 边界统一收敛生效（对齐 memory_governor 单向栅栏模式）；正在执行的 Run 内部始终消费其启动时捕获的不可变槽位快照，严禁 Run 中途变异造成状态撕裂。
2. **切域事务提交点**：提交点 = `use_server` 的 **`ToolResultMessage` 成功落入会话历史快照之后**（而非底层 RPC 返回即提交——RPC 成功与历史写入之间插 Cancel/闪断会产生未闭环历史，D-H 投影扫描到无配对 tool_result 的历史调用会错乱）。提交前 Run 中途取消/失败槽位指针不变；提交后取消/失败**不回滚**（切换是显式意图，D-H 投影下一 Run 按新槽位对齐）。
3. **user 全局 prompt 存储损坏 fail-closed**：解析失败不抛穿启动，隔离损坏文件返回空表 + 非阻塞系统级通告「配置损坏已隔离，建议重置」。
4. **Token 水位计（UI）**：编辑框实时展示 `N/300 Tokens`，超限实时变红并禁用保存按钮；拦截时严禁清空输入框（对齐 ux-hardening 语气纪律）。**单源约束**：UI 水位计算必须复用 `core/tokens.dart` 字符级粗估纯函数（与 kGlobalSkillBudgetTokens 注册闸同源），禁止 UI 侧另写字符估算（如 `length/4`）造成前后端口径漂移。
5. **存盘边界清洗**：user prompt 存盘前转义/剥除伪造系统边界标记。清洗范围两层：① XML/HTML 级（`</system>`、`<tools>` 等）；② **本系统真实边界语法**（更致命——它们是组装层与 D-H 的真实分区语法）：行首 `### Skill: ` 标题（伪造即注入假分区）、`[System Notice:` 前缀（伪造即冒充 D-H 系统通告，见 `agent_loop.dart` kSyntheticMaskedNotice）。防用户内容破坏 system 分区结构与系统通告信任；不做过度内容清洗（单用户本地 app，用户即主体）。**落地口径**：`lib/coordinator/user_prompt_store.dart` `sanitizeUserPromptContent` 纯函数——危险标记统一**转全角**（`<`→`＜`、行首 `#`→`＃`、`[`→`［`），视觉近零差异且不再是精确标记；返回清洗计数供 UI toast 可见通告（`已清洗 N 处伪造边界标记`）。行内/缩进非行首 `#` 等正常内容零清洗（防过度），已清洗文本二次过闸幂等。

### 8.3 收窄采纳

- **user 全局 skill 命名规约**：user 来源全局 skill 建议加 `user/` 前缀（与 `cow/` 对称），利用既有唯一闸，不加新机制。
- **缓存失配分层哈希（debug）**：debug 模式输出三层校验哈希——Prefix-Hash（base+Global）/ Middle-Hash（mounted+公共 appScoped）/ Tail-Hash（私有槽位块），未命中时日志标注 `[CACHE_DIFF]` 定位到层；挂 debug_run_orchestrator 事件流。

### 8.4 否决

- **强制全量刷新开关（bypass cache flag）**：Provider API 无「跳过缓存」参数（Anthropic 缓存 TTL 自动过期、OpenAI 无 bypass）；强制 miss 只能靠改变请求字节。调试定位需求由 8.3 分层哈希覆盖。

## 9 实施顺序与验证清单（单测为验收硬钉子）

### Phase 1：纯结构与排序重整（无行为变更）

- [ ] 重构 `composeSystemPrompt`：`mountedSection` 调整到公共 appScoped 之前（§3.1 易变度序），入参显式分离 `publicServerIds` 与可选 `activePrivateSlotId`；
- [ ] 排序单测：乱序注册的 Skill，断言输出顺序与 `'${s.serverId ?? 'global'}:${s.name}'` 严格一致（含 global 段 null 归一化用例）；
- [ ] 空槽单测：`activePrivateSlotId == null` 时私有块渲染 `""`，整段无 `\n\n\n` 连带空行与悬挂换行；
- [ ] 护栏：`toolbox run arch-guard` + `flutter analyze` 0 warning / 0 issue。

### Phase 2：私有过滤、联动断连与 User 全局 Prompt

- [x] 同拍原子接入：`chat_run_orchestrator` 构建 `ChatRunPlan` 时，`focusedSchemas()` 与 `composeSystemPrompt()` 传入**同一份** `activePrivateSlotId` 不可变快照；
- [x] 切域事务单测：`ToolResultMessage` 落入历史快照前 Abort → 槽位保持原状；成功写入后 Abort → 槽位已切新 Server；
- [x] 断连联动单测：激活私有服务掉线 → pending 置空 → 下一 Run 纯公共模式（空串渲染）+ 通告；Run 中途断连不影响本 Run 快照；
- [x] 存储容灾测试：手工损坏 user prompt 存储文件 → 启动不抛异常、返回空表、触发隔离通告；
- [x] 边界清洗单测：含 `### Skill: `、`[System Notice:`、`</system>` 的 user prompt 存盘后被转义/剥除；
- [x] user 全局 prompt 管理入口：`UserGlobalPromptsStore`（原子写 + 损坏隔离备份）+ `UserPromptsSection` 设置段（建编删 + `N/300 Tokens` 水位计单源 + 超限禁用保存 + 清洗计数通告）+ `buildBaseSkillRegistry` 装配管道（注册闸 fail-fast 跳过通告）；
- [x] 透明面（§3.4）：记忆看板第 4 Tab「提示词」只读总览（`PromptsOverviewSection`：全局 Prompt 落盘面 + MCP 服务 Prompt 活态 `appScoped()` 面 / CoW 落盘基线回落）；底层补 `SkillRegistry.appScoped()` / `CowOverridesStore.knownNames()` 两个只读投影；
- [ ] 端到端 Telemetry：真实模型抓取 `cached_tokens`——同一私有域连续交互接近全量命中；切域当轮记录重前缀流血值；切后第 2 轮恢复高命中。
