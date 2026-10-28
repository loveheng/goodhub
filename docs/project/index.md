---
status: active
updated: 2026-10-23
---

# goodhub · 功能落点索引（数据）

> goodhub 索引数据：代码落点 / 文档落点 / 架构债三表。改前定位查本表；登记纪律与维护协议见 `.agents/skills/goodhub-index/SKILL.md`。

> 本文件是 goodhub 索引**数据**（代码落点 / 文档落点 / 架构债三表）——工程事实住 docs/project/，skill 只放规约。登记纪律与维护协议见 `.agents/skills/goodhub-index/SKILL.md`，表格式机制见全局 `project-index` skill。表随实现增量登记——禁止一次性铺满；**只放「功能 + 落点 + 核心类 + 指针」，施工过程 / 日期叙事 / 即时行数一律不入表**（纪律见 skill）。

## 代码落点

| 功能 | 落点 | 备注 |
|---|---|---|
| MCP 客户端（连接/claim/touch/apply） | `lib/mcp/` | JSON-RPC over Streamable HTTP；契约 = goodshare 仓 `docs/design/ai-app-split.md` §3；tools/call 结果按 MCP content 信封解包 |
| LLM 引擎（端侧 LiteRT-LM / 云端） | `lib/llm/` + `android/`（LlmBridge.kt） | M2 自 goodshare 随迁；proguard keep 教训查 `context/lessons.md` |
| 云端 BYOK 引擎（双协议/SSE 流式/BYOK 配置） | `lib/llm/cloud/` | 密钥走 `core/security/` SecureKeyValue；装配入口 `engineFor` |
| 混合编排 Coordinator（降级状态机/云↔端路由/Agent Loop/MCP 工具面） | `lib/coordinator/` | `HybridCloudEngine` 路由 + `AgentLoop` 工具环（maxTurns=10）+ `McpToolFace`；默认装配 `assembleDefaultHybridEngine` |
| 多插件任务编排（TaskPlan 计划卡 · 写面围栏 · 批量授权 · 台账聚合） | `lib/coordinator/task_plan.dart` + `plan_guard.dart` + `plan_proposal_tool.dart` + `permission_gateway.dart`（planGrant 源）+ `local_tool_chain.dart`（插链）+ `lib/ui/task_plan_card.dart` + `task_result_card.dart`（新，2026-10-24） | 设计 SSOT = `docs/design/task-orchestration.md`；链序铁律 `PlanProposalTool→PlanGuard→PermissionGateway`（经 `composeToolExecutorChain`）；Run 收口 = `McpAssembly.close` → `PlanRunState.endRun`（聚合卡经窗口回调）；step-id Schema 注入仅 App 内聊天工具面，网关投影不见此属性 |
| 任务循环（认领→心跳→回写） | `lib/task/`（TaskLoopService + TaskInference 接口） | 推理期 5s 心跳（契约 §3.3）；apply 产出按 task_action 分叉 summary_md/tags/note；**毒丸防护（§3.12.2-6）**：推理失败须 apply failed 终态，不留 processing 等 30s 回收反复认领 |
| 宿主侧任务消费循环（catch-up / 单飞 dirty / 达顶继续 / 空拉终止 / 熔断 / 算力让路 / 生命周期解绑） | `lib/task/task_consume_loop.dart`（新，2026-10-18） | 契约 = goodshare 仓 ai-app-split.md §3.12（宿主侧消费纪律 8 条）；通道存活与前台忙碌为注入端口（不 import ui/gateway） |
| 任务消费对账账本（按来源服务分组列表 + 自然日过滤，跨会话持久化） | `lib/task/task_consume_ledger.dart`（新，2026-10-18；`underSupportDir` + SequentialFileWriter 原子写） | 条目含 `serverId`（按 MCP 服务领域划分的键，当前恒 goodshare 包名，预留多 server）；`recentEntries`（自然日过滤，>今天隐藏但持久化全量保留）+ `groupedByServer`；聚合降级为组头元信息（不抢眼）；损坏文件返空账 + DEGRADE |
| 任务对账页（侧边栏底部横排工具带入口直达；按服务分组列表为主 + 自然日过滤 + 清空） | `lib/ui/task_ledger_page.dart`（新，2026-10-18）+ `lib/ui/sections/task_ledger_section.dart`（内容 widget，注入位传入账本） | 列表为主、聚合降级为组头元信息（域名 + 组今日计数小字）；按 MCP 服务分组（serverId）；自然日过滤（>今天隐藏）；goodhub-ui §2：零魔法值（ConsoleTokens/Fsz/monoFamily）、内容 widget 有状态段混 `AutomaticKeepAliveClientMixin` |
| 应用级装配：宿主上线接管 goodshare 任务消费（插件识别 / 装配 / catch-up 触发 / 解绑 + 对账记账） | `lib/app/task_consume_bootstrap.dart`（新，2026-10-18；进程级单例 `taskConsumeBootstrap`） | 拉模型地基（§3.12 catch-up）：`main` 启动触发、**非常驻轮询**；窗口层只注入 `isHostBusy` 运行态（chat_page initState/dispose 各 1 行）；识别常量 `kGoodsharePackage`；失败一律 DEGRADE 不阻断启动 |
| L1/L2 权限网关（分类矩阵/确认卡会话豁免/拒绝回填） | `lib/coordinator/permission_gateway.dart` | 装饰 ToolExecutor；拍板 C2/C5/C7 语义 |
| N7 PII 出站围栏内核（正则遮蔽/反向映射/流式还原） | `lib/coordinator/pii_fence.dart` | 拍板 D1-D5；挂点=云引擎装饰器，失败→PiiMaskException 禁静默放行 |
| N7 围栏云引擎装饰器（出站遮蔽/流式还原/拦截分派） | `lib/coordinator/fenced_cloud_engine.dart` + `hybrid_assembly.dart` 接线 | 一次装配=一次 Run 映射会话（调用方按 Run 装配）；PiiFenceDelegate 缺省 null=无人值守 fail-closed，debug 页接 FenceBlockCard 双选项卡 |
| 两步熔断+步数墙排查卡契约 | `lib/coordinator/tool_breaker.dart` + `agent_loop.dart` | BlockDelegate 三操作；拍板 C1/C3 语义 |
| 上下文治理（滑动窗口/工具结果摘要化） | `lib/coordinator/context_governor.dart` + `agent_loop.dart` | 发送边界窗口化（本地历史不裁）+ 回填前端侧摘要化（拍板 E1：摘要化失败保留原文 DEGRADE 留痕）；端侧摘要器 `OnDeviceResultSummarizer` |
| UI 组件（design tokens/药丸/确认卡/排查卡/围栏拦截卡/面板错误行） | `lib/ui/tokens/` + `lib/ui/components/`（含 `panel_error_row.dart` = 面板级错误行唯一实现，设置页与资源中心页共用）+ `lib/ui/gateway_loop_debug_page.dart` | tokens 唯一出处（goodhub-ui skill），debug 页全链接线（拍板 C4 边界） |
| 网关/熔断联调页（L1/L2 网关 + 熔断排查卡验证 + 故障注入 + 脚本引擎 + 跨源/CoW 调试） | `lib/ui/gateway_loop_debug_page.dart`（窗口层：开关收集 + 四 UI 端口 + 事件流→轨道映射）+ `lib/coordinator/debug_run_orchestrator.dart`（挂载→协商→记忆面→网关→注水→引擎→sampling→故障注入→Skills/CoW→AgentLoop 全编排，纯编排零 UI；`_FaultInjector`/`_ScriptedEngine` 可单测件；clientFactory/目录解析器/五 UI 端口注入位） | **红线**：不并回 `McpRuntime.assemble`——生产多 Server 前缀路由+JIT 发现 vs 联调单 Server 裸名+静态 tools 语义不兼容；单测 `test/coordinator/debug_run_orchestrator_test.dart`（事件流契约/故障注入/释放卫生/异常路径） |
| 应用装配入口（引擎预热/记忆清扫/首页挂载） | `lib/main.dart` | 纯装配 |
| 聊天主页（AgentLoop 正式宿主面） | `lib/ui/chat_page.dart`（视图交互与装配）+ `lib/ui/components/chat_composer.dart`（底部输入集群，传数据+回调零依赖私有态）+ `lib/ui/chat_status_controller.dart`（状态带 pill/运行态/已耗时 + 轨道列表 + 滚动锚定/键盘/会话切换生命周期；status/tracks 双 Listenable）+ `lib/ui/components/dual_track_stream.dart`（`TrackText`/`TrackCall` 自管局部渲染）+ `lib/ui/components/status_strip.dart`/`status_capsule.dart` | 交互 SSOT `docs/product/chat-interaction.md`；运行态·轨道·40ms 流控已下沉 controller/组件；**composer「+」= 本次会话统一挂载菜单**（服务绑定 + 附加资源 / 管理资源中心，2026-10-19 收口）；附件行按需展开（仅有待发项时 44dp，空态收 0），药丸默认 1 行不因新增能力占位；**红线**：离开运行中任务有 `PopScope` 确认拦截（abort 即停 + mounted 内落盘部分进度）；回归 `test/ui/chat_status_controller_test.dart` |
| 双轨消息流组件（TrackEntry/渲染映射） | `lib/ui/components/dual_track_stream.dart` | 卡片复用 M2/M3 组件；阅读轨文本走 StreamingRichText；TrackEntry 编解码在 UI 层（静态） |
| Markdown 子集解析器（跨仓共享包） | 外部包 `/home/zzh/app/rich_text/`（`rich_text.dart` 抽象 + `markdown_subset.dart` 实现） | goodhub 渲染器只依赖抽象（`List<RichBlock>`），parse 移调用点 |
| 阅读轨只读渲染器（console tokens 对齐） | `lib/ui/rich_text_view.dart` | 媒体块降级不吞内容；todo 只读字形；MathBlock/InlineMath 降级等宽呈现 |
| 流式性能优化（P0 流控缓冲 + P1 前缀块缓存） | `lib/ui/components/stream_text_buffer.dart` + `lib/ui/components/streaming_rich_text.dart` | 设计 SSOT `docs/design/stream-perf.md`；Buffer 40ms 节拍 + 流结束强制清空；安全切点增量解析 + RepaintBoundary 隔离；等价性 fuzz 门禁 `test/ui/streaming_rich_text_test.dart` |
| 记忆沙盒（三件套/FC1 锚点/scope 三层作用域/预算视图/审计/轮转） | `lib/sandbox/memory_store.dart` | 拍板 D4~D8 见 docs/design/m4.md §4；`underSupportDir` 生产装配 + 启动清扫挂 main |
| 宿主环境事实只读工具（`get_host_status`：宿主身份 / MCP 协议版本 / 平台 / 时区 / 语言区域；**Allowlist 首项**，描述与 Schema 的单点 owner） | `lib/coordinator/host_status_tool.dart`（新，2026-10-23；`HostStatusToolExecutor`，`readOnlyHint:true` → 网关 L1 静默放行）+ `lib/app/service_directory.dart`（`appVersion()` 应用级单入口 + 注入位 + DEGRADE 占位） | 选型与被否决候选见 `docs/design/host-tools-gateway-export.md`「首项登记」；**零隐私约束**（返回体不含用户数据 / 服务清单 / 私有槽位态）由单测钉死；入宿主执行链经 `assembleHostToolInvoker`（`coordinator` 内部引用，网关白名单不扩张）；单测 `test/coordinator/host_status_tool_test.dart` + `test/gateway/gateway_controller_mount_test.dart`（用例 4 端到端） |
| 记忆读写内部工具面（update_memory/query_memory） | `lib/coordinator/memory_tool_executor.dart` | 挂 Gateway 内侧（L2 裁决先于执行）；§5.1 描述引导 + §5.3 快照回显；审计三点合围见 m4.md T2 注记 |
| 会话历史持久化（每会话一 JSON/原子重写） | `lib/sandbox/conversation_store.dart` | CloudChatMessage 编解码在此；恢复降级语义见 m4.md T3b 注记 |
| 串行文件写队列（temp+rename 原子替换） | `lib/core/storage/sequential_file_writer.dart` | coding-standards §3.2 基准件；支持 `settled`/`ioDrained` 确定性握手 |
| 多服务配置面（多端点 JSON + apiKey 安全存储 + 旧键迁移 + enabled 挂载位） | `lib/mcp/server_endpoints.dart`（`ServerEndpointStore`） | 服务全生命周期收敛到设置页 `_nodesPanel`；单测 `test/mcp/server_endpoints_test.dart` |
| 安全存储升级健康检查（flutter_secure_storage 9→11 直升丢密钥显性化：unreadable/discarded 判丢失） | `lib/core/security/secure_storage_upgrade.dart`（`SecureStorageHealth` + `checkSecureStorageHealth` 纯映射单测钉子）+ `lib/ui/settings_page.dart`（`secureHealthOverride` 注入位 + 顶部 `secure-storage-notice` 行） | 节点卡「⚠ 令牌需重新录入」标签按安全存储实际读出判定（`nodes_section` `_authLabel`）；检查只读、失败按正常 DEGRADE 不拖垮页面；单测 `test/core/security/secure_storage_upgrade_test.dart` + `test/ui/settings_secure_notice_test.dart` + `test/ui/server_nodes_panel_test.dart`（令牌丢失组） |
| 节点探活（握手+工具计数计时 / 401/403 鉴权态与离线区分） | `lib/mcp/server_probe.dart`（`ServerProber`/`NodeProbeResult`） | `McpClientFactory` 注入位；探活一次性建 client 用完即弃；单测 `test/mcp/server_probe_test.dart` |
| Server 节点卡面板（端口/延迟/在线点/工具计数/鉴权态/挂载开关/增删改/默认私有钉选渲染） | `lib/ui/sections/nodes_section.dart`（`NodesSection`） | 增删改同 `mcp_servers.json`；探活按需不自动网络化；注入位 `endpointStoreOverride`/`probeOverride`/`autoProbe`；钉选 owner 在 settings_page（`isDefaultPrivate`/`onPinToggle` 透传）；段 State 混合 `AutomaticKeepAliveClientMixin`（滚动不丢态，闸见 `test/ui/settings_sections_keepalive_test.dart`）；单测 `test/ui/server_nodes_panel_test.dart` |
| 本地插件面板（Binder 发现项渲染/信任态 pill/信任卡片入口；零配置自动挂载，不落用户 JSON） | `lib/ui/sections/local_plugins_section.dart`（`LocalPluginsSection`） | 注入位 `localScanOverride`/`localChangesOverride`；单测 `test/ui/local_plugins_panel_test.dart` |
| 设置页（原服务大厅：Skill 覆写管理/BYOK/跨源授权/PC 远程网关/本地插件撤销信任/关于段） | `lib/ui/settings_page.dart`（页面骨架 + 跨段 owner：ListView 顺序/toast/错误行/默认私有钉选持久读写）+ 八段各自落在 `lib/ui/sections/{appearance,byok,nodes,local_plugins,gateway,cow,cross_source,about}_section.dart`（文件头有 scope 边界声明与各段迁移语义）；面板级错误行口径统一于 `lib/ui/components/panel_error_row.dart` | BYOK 多 profile 增删改 + 置顶切换生效（首位=生效对齐 hybrid_assembly；apiKey 走 SecureKeyValue）；「关于」段 = 版本 + 检查更新常驻 + 长按标题进 debug 联调（kDebugMode）；**红线**：入口只在聊天页侧边栏（AppBar 无设置按钮）；单测 `test/ui/byok_panel_test.dart` + `settings_page_test.dart`（关于面板/长按联调/网关面板控件）+ `test/ui/gateway_section_test.dart`（网关段：默认自动生成 Token / 显式免鉴权逃生口 / 用户值优先） |
| 记忆看板（四 Tab 查看/编辑/导出/粉碎 + ops.log 人类可读渲染 + 提示词透明面） | `lib/ui/memory_board_page.dart`（四 Tab：记忆/教训/审计/提示词）+ 第 4 Tab 段 `lib/ui/sections/prompts_overview_section.dart`（只读总览：全局 Prompt = builtin globals 恒可见 + `UserGlobalPromptsStore` 落盘，**与 App 启动同源、不依赖会话**；MCP 服务 Prompt 读连接态 `SkillRegistry.appScoped()`（窗口经抽屉注入 `skillsProvider`——反映当前已连接服务与静态预置，与具体会话无关）或注册表不可用时回落 builtin appScoped 恒在 + `CowOverridesStore` known_versions/overrides 落盘基线（覆写正文直接展示、未覆写模板正文不落盘走占位）；编辑归设置页两段防双入口） | store 编辑面 `updateEntry/deleteEntry/purgeUserScope/listOpsLog/exportAll`（memory_store.dart）；ChatPage 侧边栏入口；单测 `test/ui/memory_board_page_test.dart` + `test/sandbox/memory_board_store_test.dart` |
| token 字符级粗估口径 SSOT | `lib/core/tokens.dart` | 自 context_governor 下沉（层级纪律），governor 原位 re-export |
| 应用内自更新（清单模型/下载校验/安装器/更新页） | `lib/update/` + `lib/ui/update_page.dart` | 入口 = chat_page ⚙ 调试菜单「检查更新」；设计 SSOT `docs/design/self-update.md` |
| 网关策略投影（三策略 `single`/`pruned`/`full` / 元组级四级过滤管道 / 会话绑定策略 / `single` 入站前缀补齐 / 投影差分广播抑制） | `lib/gateway/projection_pipeline.dart`（新，2026-10-23：`ProjectionPolicy` 值对象 + `ProjectionFilter.project` + `resolveInboundToolName`，纯函数无 IO）+ `lib/gateway/mcp_gateway_handler.dart`（`policy` 字段 / `project()` 单一投影源 / `markProjectionBaseline` + `projectionChangedSinceBaseline`）+ `lib/gateway/gateway_server.dart`（`initialize` 期解析 URL query 绑定策略；非法字面量 / 目标未挂载 Fail-Fast `-32602`） | 设计 SSOT `docs/design/host-tools-gateway-export.md`；**单轴化（2026-10-23 裁决 D1）**：字面量并集 `single|private|full|pruned`，URL 键与控制面参数统一 `policy`（旧 `strategy=`/`scope=` 为兼容别名，`scope` 不进 schema） §投影策略规范/过滤铁律/入站补齐/会话绑定；**三级纯度**：管道纯函数 → handler 只接线 → server 只绑定；投影集签名按 `serverId/bareName`结构化（不含对外前缀，故 `single` 与 `full` 同批工具签名相同，差分广播只认集合变化）；`full` 策略目录与入站语义**逐条等价**于既有实现（仅目录序稳定化为字典序）；单测 `test/gateway/projection_pipeline_test.dart` + `test/gateway/projection_session_binding_test.dart` |
| 聚合网关服务器（Streamable HTTP `/mcp` / 会话 / Bearer / SSE 下行 / 15s 心跳） | `lib/gateway/gateway_server.dart` | thirdconnect §7；协议 2025-06-18；**红线**：SSE 起点必设 `bufferOutput=false`（goodshare 同坑已修 + 逐帧计时回归钉子）；**TC12 Keep-Alive 双通道**：GET 订阅 = `: keep-alive` 注释帧（不计入 MCP 帧）/ `tools/call` SSE = 真 `notifications/progress` 帧（`keepAliveInterval` 可注入，默认 15s；`progressToken` 优先回显客户端 `_meta.progressToken`；**JSON 模式无法注入**——响应体须整体写出）；**会话生命周期（2026-10-23 修「无线用久了自动掉线」）**：`sid` **长期有效**（不按时间删）、SSE 订阅断开**不销毁会话**、idle GC 只回收 **handler 内存态**（按需重建，策略与连接级私有绑定从会话条目恢复）、会话表 **LRU 256 上限**兜底；`stop()` 取副本再关闭（边遍历边 `await` 会与 SSE 断连回调并发改表 → Concurrent modification 崩溃，已修）；单测 `test/gateway/gateway_server_test.dart`（含「TC12 Keep-Alive」+「SSE 订阅断开 ≠ 会话结束」钉子，撤修复即红） |
| 网关息屏保活 · 电池优化白名单（状态查询 + 跳系统申请 + 设置页提示） | `android/app/src/main/kotlin/com/zzh/goodhub/GatewayServiceBridge.kt`（`batteryExemptionStatus` / `requestBatteryExemption`，ROM 不支持申请弹窗时降级到白名单列表页）+ `lib/gateway/gateway_service_channel.dart` + `lib/gateway_api/gateway_control.dart` + `lib/ui/sections/gateway_section.dart`（提示行 + 「去设置」按钮 + 生命周期回查） | **G4 遗留项收口（2026-10-23）**：未加白名单时息屏进 Doze 会限网 → PC 侧表现为「过段时间连接掉了」（历史 Doze 验证是 adb 写白名单做的，真机用户路径从未开过）；Manifest 加 `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`；单测 `test/ui/gateway_section_test.dart` |
| 网关配对 Token（生成 + 起服决策 + 设置段控件；默认自动生成，免鉴权降级为显式逃生口） | `lib/gateway_api/gateway_token.dart`（新，2026-10-23：`generateGatewayToken` = 32B `Random.secure` → base64url 无填充；`resolveGatewayToken` 决策 = 输入框有值→用户值 / 留空+自动生成开→生成 / 留空+自动生成关→免鉴权）+ `lib/ui/sections/gateway_section.dart`（自动生成开关 + 显示/复制/重新生成；`gateway.token` + `gateway.token.authMode` 落盘） | **产品裁决 2026-10-23**：消除「Token 留空 = 不鉴权」的**默认暴露**（网关默认监听 `0.0.0.0:8766` → 同局域网任意主机可无鉴权访问只读工具面，L1 工具不弹确认卡）；免鉴权保留为**显式**逃生口（仅建议 ADB 转发）；注入位 `startOverride`/`stopOverride`（沿用 section 的 `xxxOverride` 范式）；单测 `test/gateway_api/gateway_token_test.dart` + `test/ui/gateway_section_test.dart` |
| 网关连接级系统工具（列全部已挂载 MCP 服务 `gateway__list_servers` / 投影切换 `gateway__select_private(scope=single\|private\|full)`） | `lib/gateway/mcp_gateway_handler.dart`（`_handleListPrivateServers` / `_handleSelectPrivate` + `systemToolJson`；`gateway__` 命名空间） | **列全部已挂载服务**（含 public / 本地插件）并标注 `tier`+`source`，只列 id / 隐私级别 / 来源 / 只读工具数（不含凭据、端点、服务自报名或内容），实时现算；切换**只改本连接**投影（与既有 `select_private` 同权限集合，MO6「PC 无权改写宿主状态」不受影响）；`single` 下**只保留 select_private 作退出通道**（全隐匿即死锁）；单测 `test/gateway/projection_server_switch_test.dart` |
| 网关协议处理器（工具聚合 / 前缀分发 / 进度转 SSE / `tools/list_changed`） | `lib/gateway/mcp_gateway_handler.dart` | `GatewayHandler.toolsCall` 剥前缀直达 `face.client`；阻断类结果经 `errorCode` 回协议错误帧 |
| 网关装配与生命周期（双源装配 / 包变更重扫 / 原生前台服务桥 / Wi-Fi IP） | `lib/gateway/gateway_controller.dart` + `gateway_service_channel.dart` + `android/`（`GatewayForegroundService`/`GatewayServiceBridge`） | TC12 FSI 醒目呼叫 = `L2AlertActivity` + `GatewayConsentBridge`；电池优化白名单留真机 |
| 网关入站安全闭环（L1/L2 裁决 / 45s 熔断 / 会话豁免 / PII 出站 fail-closed / 入站审计） | `lib/gateway/gateway_security.dart` | 复用 `permission_gateway.classify` + `DialogGateDelegate`（`appNavigatorKey` 后台弹层）；ops.log 落 `server=gateway`；单测 `test/gateway/gateway_security_test.dart` |
| 网关环路防护（Trace-ID 在途集合引用计数 / `hop_count>0` 闸门 / 上限 2 熔断 / TTL 300s 惰性驱逐） | `lib/gateway/gateway_loop_guard.dart` | 阻断回 JSON-RPC `-32000`；出站 `params._meta` 平级注入 `traceId`+`hopCount+1`；单测 `test/gateway/gateway_loop_guard_test.dart` |
| 网关背压（per-server 并发上限 4 + FIFO 排队） | `lib/gateway/gateway_backpressure.dart` | thirdconnect §9.6；只包真实执行段（L2 确认等待不占槽）；无 429 语义（有界队列 429 已显式关闭，见 architecture 待拍板清单） |
| 本地插件发现（PackageManager 扫描 + 包变更广播 → 运行时自动挂载） | `lib/mcp/local_plugin_discovery.dart` | 产出「系统托管端点」= 装配期运行时 face（不落用户 JSON store，区别于 `server_endpoints.dart`） |
| 同机插件信任（签名 SHA-256 白名单持久化 + 信任卡片 UI） | `lib/mcp/trusted_plugins.dart` + `lib/ui/trust_plugin_dialog.dart` | 同签名零弹窗 + 开发者模式第三方信任卡；gateway headless 跳过；真机自动化 `integration_test/trust_gate_test.dart` |
| Sampling 反向请求（宿主收端 + 反向在途表 + `answerReverse`） | `lib/mcp/sampling.dart` | 配额分池（2026-10-17 instant-sampling 一期）：`pool` params 平级字段（Tier 1 私有，缺省/非 String/未登记名 = 默认池）→ 配额 key `serverKey`/`serverKey:pool`；默认池 20 次/60min、instant 池 60 次/60min；内存态不落盘（restoreHits 跨 pool key 兼容）；caps 白名单单点防伪造池名绕过限额；契约 = goodshare 仓 ai-app-split.md §3.11 |
| 同机 Binder 传输（AIDL 通道 / 状态机 / 挂起队列 / DeathRecipient / 事件回传） | `lib/mcp/transport/`（Dart `BinderTransport`）+ `android/`（MethodChannel 桥；AIDL 契约由 Maven 坐标 `com.zzh.goodhub.mcp:goodhub-mcp-contract` 提供） | TC9 控制面；**插件侧 SDK 与 AIDL 契约已拆独立仓** `loveheng/goodhub-mcp-sdk`（契约物理单副本 = 该仓 `:contract` 模块；宿主经复合构建 / mavenLocal 消费，`toolbox run check-contract-sync` 校验单副本与版本绑定）；≥128KB 的 `mcp-blob://` 数据面未落地（thirdconnect 待办） |
| 宿主虚拟服务导出面（`HostTransport` 伪装 MCP 服务端 / `kHostExportAllowlist` 静态注册表 / 门禁 1 annotations 强置 + 门禁 2 控制面原语黑名单 / `host` 保留字断言 / 网关第三装配源） | `lib/mcp/transport/host_transport.dart`（新，2026-10-23）+ `lib/coordinator/host_tool_invoker.dart`（新，执行端口适配器 + `assembleHostToolInvoker`，**无裁决**）+ `lib/coordinator/reserved_namespace.dart`（`assertServerIdMountable` 独立小件，mount/mountEndpoint/assemble 三路同点设防）+ `lib/core/errors/mcp_error.dart`（`ReservedNamespaceException`） | 设计 SSOT `docs/design/host-tools-gateway-export.md`；**端口纪律**：`mcp` 域禁反向 import coordinator/llm（arch-guard R5/R6），宿主执行面经 `HostToolInvoker` typedef 注入 + `coordinator/host_tool_invoker.dart` 适配（owner 住 coordinator，网关只调一行）；**无裁决铁律**：L1/L2 已由 `GatewaySecurity.guard` 在 `toolsCall` 层完成（annotations 取自合成面），端口内**严禁**再挂 `PermissionGateway`（否则 PC 见两次确认卡）；网关第三装配源 = `gateway_controller._assemble` 末位装 `faces['host']`（注入位 `hostExportAllowlist` / `hostInvokerProvider`）；只声明 tools 能力（不声明 sampling，否则 face 被拖进流式调用）；**Allowlist 首项 = `get_host_status`**（宿主身份/协议/时区/语言只读事实，零隐私 + 有真实推理增益；记忆读写等隐私能力仍默认不登记）；单测 `test/mcp/host_transport_test.dart` + `test/coordinator/mcp_runtime_reserved_id_test.dart` |
| 执行面链装配器（`ToolExecutor` 链**唯一构造入口**：层按「优先级高 → 低」给出、折叠方向固定逐层向外 → 结构上杜绝「inner 指向链中段」丢层） | `lib/coordinator/tool_executor_chain.dart`（新，2026-10-23） | 架构债 #19 根治件；调用点 = `host_tool_invoker` / `local_tool_chain` / `debug_run_orchestrator`；机械门禁 = `arch-guard.sh` R9 + `test/architecture/executor_chain_rules_test.dart` |
| 本机工具执行链组装（T6 链路序唯一 owner：Guarded→Discovery→SkillActivation→Hydration→L1/L2 网关→本地资源→记忆工具→ToolRouter 兜底；`GuardedExecutor` 随迁自此） | `lib/coordinator/local_tool_chain.dart`（新，2026-10-23：`composeLocalToolChain` + `GuardedExecutor` + `LocalToolChain` record） | #18 体量治理续：自 `mcp_runtime.assemble` 抽出（该文件恢复「只减不增」轨迹）；本地资源工具挂 Gateway 内侧（L2 裁决先于执行，对齐记忆工具面）；单测经 `test/coordinator/mcp_runtime_test.dart` 装配基线 + 全量回归覆盖 |
| 网关系统工具面（`gateway__` 命名空间常量 + 系统工具 JSON 声明 + 投影描述文案的**单一 owner**） | `lib/gateway/gateway_system_tools.dart`（新，2026-10-23） | handler 只留接线与连接态（#18 体量治理）；**文案禁引用未声明工具名**（工具名 = PC 侧唯一契约面，悬空引用 = 幻觉调用源）——钉子 `test/gateway/projection_server_switch_test.dart` |
| CoW 模板 → Skill 注入（逐 server 同步 + 撞名跳过通告 + 失败 Polyfill 降级） | `lib/coordinator/cow_skill_sync.dart`（新，2026-10-23） | 从 `mcp_runtime.assemble` 抽出（#18 体量治理）；命名 `cow/<promptName>` |
| 多 Server 路由与 JIT 元工具（前缀隔离 / 激活集 / `get_connected_apps` / `activate_server_tools` / `use_server`） | `lib/coordinator/tool_router.dart` + `lib/coordinator/discovery_executor.dart` | `<server_id>__<tool>`；装配在 `chat_page._send`；**注意** `lib/mcp/tool_router.dart` 为孤立件（仅测试引用，海关过滤规则在其中，待收编 = 活跃债 #27） |
| 工具可见性标记（SDK 0.2.0 `_meta.goodhub.visibility`，private/shared；缺失即 private） | `lib/core/tool_visibility.dart`（枚举 + 解析）+ `lib/coordinator/mcp_tool_face.dart`（tools/list 解析进 `CloudToolSchema`）+ `lib/gateway/mcp_gateway_handler.dart`（对外目录只回 shared） | **声明非 ACL**：SDK 不剔条目、不拦调用；过滤只在**对外暴露面**（网关 PC 投影），本机链路（`coordinator/tool_router`）保持能力全集；旧口径已作废（见 coding-standards §1.1 规则 7）<!-- drift:keep：旧口径特指禁令叙述 -->；单测 `test/core/tool_visibility_test.dart` + `test/gateway/mcp_gateway_handler_test.dart`（F1.9 组） |
| `$ref` 暂存池（内存/文件双介质 / TTL 30min / Session 即焚 / 启动幂等清池） | `lib/coordinator/ref_store.dart` | architecture §9；启动清池 `sweepStartupOrphans` 挂 `main.dart`；单测 `test/coordinator/ref_store_test.dart` |
| 资源中心内核（本地文件库：导入/清单/读全文/改名/删除；text-only + 10MB 上限 + 内容判重复用） | `lib/resources/resource_store.dart`（新，2026-10-18；判重 2026-10-19） | 规格 SSOT `docs/design/resource-center.md`；生命周期=应用级 `underSupportDir/resource_center`；清单 SequentialFileWriter 原子写、损坏返空库 DEGRADE；错误契约 `ResourceStoreException`（code+hint）；**判重两级**：同名加 `(n)` 序号 + 同内容（sha256 字节级，记 `contentHash`）复用既有条目（`import` 返回 `ResourceImportResult` record = `{entry, reused}`；空哈希不参与复用）；与 `coordinator/ref_store.dart` 合流不合并（resourceUri=`local://resource/<uuid>`）；单测 `test/resources/resource_store_test.dart` |
| 资源中心管理页（独立页，**双 Tab**：① 文件资源 ② MCP 工具目录） | `lib/ui/resource_center_page.dart`（页壳，2026-10-19 自设置页迁出，2026-10-21 加 TabBar）+ `lib/ui/sections/resource_center_section.dart`（Tab① 内容 widget）+ `lib/ui/sections/mcp_tools_catalog_section.dart`（Tab② 内容 widget，2026-10-21）+ `lib/app/external_open.dart`（open_filex 平台收敛件） | 入口 = 会话侧边栏底部横排工具带（「设置」右侧，对齐 TaskLedgerPage 先例）；Tab② 取数经 `lib/coordinator/tool_catalog.dart` 收口（段不持领域单例，注入位范式 §8.1）；Tab② 段混 keepAlive（TabBarView 切走保态）；单测 `test/ui/resource_center_section_test.dart` + `test/ui/mcp_tools_catalog_section_test.dart` |
| MCP 工具目录取数收口（已注册服务清单 + 单服务工具拉取；复用 `McpRuntime` 挂载原语，纯浏览拉完即释放，不常驻 face；三态可见性 DTO） | `lib/coordinator/tool_catalog.dart`（McpCatalog + McpCatalogService + McpCatalogTool + CatalogSource）+ 单测 `test/coordinator/tool_catalog_test.dart` | 静态注册态服务 = 本地插件 `localPluginDiscovery.scan` + 远端 `ServerEndpointStore.load`（不依赖连接）；工具 = per-service `mount`/`mountEndpoint` 拉 `tools/list`；`declared` 区分「显式私有」与「SDK<0.2.0 兜底未声明」——对齐 `lib/core/tool_visibility.dart` 兜底口径（UI 三态 pill）；落点需求 = 资源中心 Tab②（MC1~MC4：资源中心第二 Tab / 两层都排 / 三态 / 按服务分组远程私有仅标注） |
| 本地资源读取工具 + 附件绑定（`read_local_resource`；Gateway 内侧 L2 / 64KB 窗口 / 防死循环契约） | `lib/coordinator/local_resource_tool_executor.dart` + `resource_attachment_binder.dart`（新，2026-10-19） | T3：装配期附件全文落 run 级 `$ref` 池（句柄仅合流记账，工具入参=resource_id 防注水击穿窗口）；schema 进 gateway.loadCatalog + toolsProvider；**附件 picker 支持「从系统选择…」直选即收集**（返回 `collected` 标志，入库经 `import` 闸门不旁路，宿主明示 + 可撤销）；单测 `test/coordinator/local_resource_tool_test.dart` + `test/ui/resource_center_section_test.dart` |
| 端侧模型管理链（目录/下载/清单缓存） | `archive/local_model/`（**已归档，非 lib 代码**） | 零接线零测试，端侧推迟拍板未翻转前不复活；复活步骤见该目录 `README.md`；`lib/llm/llm_model.dart` 仍为活代码（被 `llm.dart` 引用） |

## 文档落点

| 主题 | 落点 | 状态 |
|---|---|---|
| MCP 接缝契约（SSOT） | goodshare 仓 `docs/design/ai-app-split.md` | active（跨仓只读引用）；§3.12 任务通知接缝（2026-10-18 新增）= 宿主侧消费循环契约 |
| 宿主自身交互产品设计（聊天/决策卡片/双轨流） | 本仓 `docs/product/chat-interaction.md` | active（交互 SSOT） |
| UI 设计规范（控制台风格 SSOT） | 本仓 `docs/project/ui-design.md`；落点纪律见 `.agents/skills/goodhub-ui/SKILL.md` | active |
| 工程编码基准（规则契约 SSOT，含 MCP 对 AI 接口契约 §5） | 本仓 `docs/project/coding-standards.md`；项目基线数据（内核登记/白名单/超标清单）= 本文件「工程基线数据」 | active |
| 同机互联与网关设计（Binder/UDS/网关/插件 SDK/TC1~TC14） | 本仓 `docs/design/thirdconnect.md` | active |
| 本地插件准入与信任（签名/信任卡片/生态开放度） | 本仓 `docs/design/local-plugin-access-trust.md` | active |
| M4 施工设计（双轨/记忆/多 Server/T4 韧性） | 本仓 `docs/design/m4.md` | active |
| 自更新（整包/清单/串包防御） | 本仓 `docs/design/self-update.md` | active |
| Binder 联调评估与修复请求 | 本仓 `docs/design/goodhub-goodshare-binder-eval.md` + `goodshare-binder-poc-fix-request.md` | active（结果回写投 thirdconnect 域） |
| 端侧 LLM 设计（LiteRT-LM / FoundationModels） | goodshare 仓 `docs/design/on-device-llm.md` | active（跨仓只读） |
| Host 网关架构 · 访问性模型 · 记忆捎带提取（Provider×Tier 解耦 / 聚合反向代理 / In-band `<workspace_update>`） | 本仓 `docs/design/host-gateway-accessibility-memory.md` | active；绑定 epic = `chatmessage`（§3 记忆提取主战场，§1/§2 依赖项）；§1.4 无前缀约束已收窄至本机调度域 |
| Host 原生工具网关导出与策略投影（host__ 虚拟服务 / HostTransport 伪装客户端 / Allowlist 静态注册表 / 四级过滤管道 / 保留字门禁） | 本仓 `docs/design/host-tools-gateway-export.md` | draft |
| 窗口解耦（内核 + 多投影：ServiceDirectory / McpRuntime / ConversationSession） | 本仓 `docs/design/window-kernel-split.md` | 内容 SSOT（架构裁决十二项 §8.1、路线图 §7.5）；施工已由 arch-hardening 承接 |
| 架构债修复施工稿（内核单入口 + 反向边斩断，步 0→3 勾稽） | 本仓 `docs/design/arch-hardening.md` | active；绑定 epic = `arch-hardening`；步 0→3 已完成，剩余 = 真机冒烟验收 |
| 普通用户可用性加固（冷启动/错误自救/术语白话/危险权重/DEGRADE 可见性） | 本仓 `docs/design/ux-hardening.md` | active；epic `ux-hardening` 已收尾归档 |

## 架构债与依赖违例登记（2026-10-16 架构盘点立 · 改相关代码前必读）

> 违例黑名单、依赖方向红灯与施工纪律的**规则 SSOT** = `docs/project/coding-standards.md` §1.0 护栏表 / §1.1（规则链：`window-kernel-split.md` §5 → coding-standards）。本表只作**改前定位速查**；每清零一项，同步更新：① 本表结项归档 ② coding-standards §1.0（如涉新增/清零红灯规则） ③ 设计稿/ epic todos。不在本表之外的散修须先在此登记再动手。**活跃表只留未结项**，已清零项移入下方归档区。

### 活跃债（未结项 · 第一屏只放风险点）

| # | 未结架构债与风险点 | 落点 | 现状与收敛条件 |
|---|---|---|---|
| 11 | 投影平面 `workspaceId` 接线（D-D 投影平面三元 `{activePrivateServerId, publicServerIds, workspaceId}` 缺 `workspaceId`） | `gateway/*`（ProjectionContext） | **已决策·选 B 暂不接线**（arch-hardening #11 决策）：PC 协议 MCP 2025-06-18 initialize 不携带 + 网关侧无消费者；设计预留待产品裁决，`host-gateway-accessibility-memory.md` §2.1 三元目标态维持不改；网关侧接线待 chatmessage 记忆分区工作（`workspace_states`）落地 |
| 20 | 应用级 owner 注册中心（分批收敛） | `lib/app/service_directory.dart`（现 5 个构件 + `resetAllForTest()`） | §S1 **第一批已交付**：取证件 `test/coordinator/multi_instance_lost_update_test.dart` 实证 `CowOverridesStore` / `UserGlobalPromptsStore` 跨实例**静默丢更新**（`MemoryStore` 因读改写整段入队已自保）；两 store 已收进注册中心（应用级单实例 + `*Override` 注入位），三处窗口消费点 + `buildBaseSkillRegistry` + `syncCowSkillsIntoRegistry` 改走注入，窗口层零构造已落机核（`test/app/service_directory_test.dart`）。**第二批已交付**：`ByokStore`（同步访问器，构造无 IO）+ `WorkspaceStateStore`（原每轮发送 new 一份）收进注册中心；机核扩到四类受管 store（联调页按 §1.4 类别 3 豁免）。**经核实不迁**（证据在册）：`TrustedPlugins` 已是进程级单例（future 缓存 + `resetForTest`）、`ConversationStore` 由会话内核 `ChatSessionService` 持有（会话级，非应用级）、`MemoryStore` 会话级且读改写整段入队已自保。**余项**：内核侧 `storeProvider == null` 兼容回退随 S2 profile 化退役 |
| 21 | Run 装配接线副本（**已结项**，结论修正） | `lib/coordinator/run_profile.dart` + `lib/coordinator/reverse_wiring.dart` | §S2 **两期交付**：一期 `RunProfile` 能力上限驱动接线；二期实证「三路并行」的真实第二副本仅为 sampling 接线循环——收口为 `wireSampling()` 唯一实现（网关传排除集 `{kHostServerId}`）；网关 face 本就经共享挂载原语 `McpRuntime.mount/mountEndpoint` 建；任务管道经 `goodshare_task_api` 直连非 MCP 装配面（原「三路」表述有误）。生命周期差异（网关常驻 vs Run 焚）是设计而非债，强并 `assemble` 属过度设计不再立项 |
| 22 | 窗口层内联 Run 编排（两期收口） | `lib/coordinator/chat_send_use_case.dart`（204 行，纯 Dart：`assembleRun` + `run`）+ `ui/chat_page.dart`（1526 行） | §S3 **两期交付**：① plan → 事件消费 → writeback → 收口（`_RunSink` 渲染端口）；② 装配段下沉 `assembleRun`（skills 装载 + 会话绑定 + `McpRuntime.assemble`；注册闸降噪经 `onNoticeOnce` 回窗口；信任闸门留窗口——信任卡片是 UI）。方法体 ~330 行。**余项**：会话复位换 `CancellationToken`、`dual_track_stream` 拆子组件（独立小步） |
| 24 | 装配容器与发送链路保护网 | `test/coordinator/agent_loop_golden_test.dart`（四切片 golden）+ `test/coordinator/mcp_runtime_test.dart`（S0 装配产物等价性组） | §S0 **已交付**：golden 四切片（Happy/Abort/Reject/Watchdog）+ 装配产物等价性（工具面快照顺序敏感 / refStore 隔离 / close 幂等全覆盖）；余项 = `app` 域装配容器单测与页面层覆盖，随 S1 / S3 收口 |
| 25 | CPU 卸载纪律统一化 | `lib/core/concurrency/offload.dart` | §S5 **一期已交付**：`OffloadThresholds`（JSON ≥256KB / 正则 ≥64KB / 加解密 ≥128KB / 入参 ≥1MB 转 TransferableTypedData）+ `shouldOffload` 可判定谓词 + `OffloadPool`（有限并发 2 + 超时守卫 + **僵尸占位**：超时弃等不弃占）+ `offloadIfHeavy`（池满退主 isolate，DEGRADE 留痕）；示范迁移 `pii_fence` / `resource_store`；单测 `test/core/concurrency/offload_test.dart`（7 例）。**余项**：新重活一律经助手（随写随用，无存量迁移债） |
| 26 | §6.2 调用主体一级抽象 | `lib/core/actor.dart` + `mcp/transport/host_transport.dart`（`allowedActors` 必填）+ `gateway/mcp_gateway_handler.dart`（运行时闸） | §S6 **一期已交付**：`Actor`（owner / external(id)，鉴权层推导、禁从载荷读）+ host 导出条目 `allowedActors` 编译期必填 + 网关 `toolsCall` 每请求运行时校验（不满足 → `-32003` 协议级拒绝且零触达执行面）；单测 `test/gateway/host_actor_gate_test.dart`（4 例）。**余项**：Binder 通道主体推导随其调用链接入补；细粒度化依赖鉴权层演进 |


### 已结项归档（只减不增 · 过程细节归 Git log / epic devlog）

- #27 孤立件收编（选 B 保留待接线）：`lib/mcp/tool_router.dart` 海关过滤独立实现 + 单测面，按 SA-Q6 维持「不删不引」，本文件头声明「规则独立镜像，非生产调用面」，决策落 coding-standards §1.1 规则 7 / §5.6；收编进 `coordinator/tool_router.dart` 待 SDK annotations 后按 #9 补强（2026-10-28 结项）

- #1 服务目录三拼收敛（含 gateway 处漏 prefs 迁移活 bug 修复）：`lib/app/service_directory.dart` 唯一 owner（2026-10-16 结项）
- #2/#3 chat_page 装配越权 + 装配第二/第三副本收敛：统一至 `McpRuntime.mount/mountEndpoint` 挂载原语（2026-10-16 结项）
- #4/#5 `mcp→coordinator/sandbox`、`mcp/sandbox→llm` 反向依赖斩断：face 注入 + 端口下沉 core（2026-10-16 结项）
- #6 `ui↔gateway` 跨域环解环：弹层迁 `lib/ui/gateway_consent_dialog.dart`（2026-10-16 结项）
- #7 会话态隔离：per-connection 投影（`forSession()` + 防火墙，`gateway_per_session_projection_test.dart`）+ host-level 默认投影源澄清（2026-10-16 结项；`workspaceId` 接线见活跃债 #11）
- #8 会话态手工枚举消除：收敛至 `ConversationSession`（2026-10-16 结项）
- #9 装配级 / chat_page 级测试基线补齐：`test/coordinator/mcp_runtime_test.dart` 等（2026-10-16 结项）
- #10 全仓并发 flaky 修复：`SequentialFileWriter.settled` + `MemoryStore/WorkspaceStateStore.ioDrained` 确定性握手，706/706 全绿（2026-10-16 结项）
- #12 UI 侧 `dart:io` 存量清零：`update_page.dart` 改持路径 `String`、`error_copy.dart` 判定下沉 `core/errors/transport_error_kind.dart`；R1 白名单维持原 3 项只减不增（2026-10-17 结项）
- #15 保留命名空间无防护：`host` 登记为系统保留 serverId（`mcp/transport/host_transport.dart` 的 `kHostServerId`），`McpRuntime.assertServerIdMountable` 在 mount / mountEndpoint / assemble 三路同点设防（非内置 `HostTransport` 一律抛 `ReservedNamespaceException`），网关 `_assemble` 第三装配源真挂 `faces['host']`（2026-10-23 PR1-2 + PR1-3 结项；设计稿 `docs/design/host-tools-gateway-export.md`）
- #16 直连白名单账实差（UI → 下层域实际边未登记）：`docs/project/index.md` 直连白名单基线改文件级账实（补登 `mcp/elicitation` 三边 / 联调页边 / 配置类窗口边；去掉易腐边数计数）（2026-10-23 审查轮结项）
- #17 产品层 SSOT 与实现反向（出厂特权工具清单 / 回环强制鉴权 / host 导出方向零记载）：`docs/product/architecture.md` §1·§13·§15 与 `docs/product/requirements.md` F1.5·F1.17·F1.20 同轮回写（2026-10-23 审查轮结项）
- #18 文件体量漂移（超标清单项净增长 + 逼近软红线件膨胀）：`mcp_runtime.dart` 抽「保留字断言 / CoW 注入」两独立小件、`mcp_gateway_handler.dart` 抽「网关系统工具面」件（体量恢复只减不增方向，数字以当次扫描为准）（2026-10-23 结项）
- #23 原子写第二实现六处扩散（cow_sync / user_prompt_store / conversation_archive / ref_store / resource_store / server_endpoints）：唯一入口 `KeyedWriteQueue.enqueueAtomicWrite` + arch-guard R10 与 CI 镜像 `test/architecture/atomic_write_rules_test.dart`（2026-10-28 §S4 结项）
- #19 链式装配等价性无通用机械门禁：新增唯一装配器 `lib/coordinator/tool_executor_chain.dart`（结构上不可表达丢层形态）+ 机械门禁 `arch-guard.sh` R9 与 `test/architecture/executor_chain_rules_test.dart`（2026-10-23 结项）
- #13 CI 缺口（无自动化触发入口）：`.github/workflows/ci.yml` 已落地（2026-10-17，commit 25ee53b）——analyze + 全量 `flutter test` + `arch-deps`（跑整个 `test/architecture/`，含 R9 镜像）；台账曾长期滞留未结项，2026-10-23 审查轮取证发现并结项
- #14 GatewayController 无装配注入位：四个注入位（discovery / endpointStore / supportDir / trustGate）+ 网关级断言（重扫释放、起服失败回滚、host 面装配与降级）均已落地；台账曾长期滞留未结项，2026-10-23 审查轮取证发现并结项

## 工程基线数据（coding-standards 配套 · 数据 SSOT）

> 本节是 `docs/project/coding-standards.md` 各契约条款引用的**项目基线数据**；规则正文在 standards，本节只放数据。变更时同轮更新对应条款指针。

### 内核登记表（standards §2.1）

| 内核 | 生命周期层级 | 落点 |
|---|---|---|
| `ServiceDirectory`（服务目录单入口） | 应用级 | `lib/app/service_directory.dart` |
| `McpRuntime`（MCP 侧 Run 级装配唯一入口，含 `ConversationSession`） | 装配 = 应用级 / Run 句柄 = Run 级 | `lib/coordinator/mcp_runtime.dart` |
| `ChatSessionService`（会话内核，transcript 过边界走中立数据） | 会话级 | `lib/coordinator/chat_session_service.dart` |
| `MemoryKernel`（记忆内核，含 `onWriteFailure` 可观测端口） | 会话级 | `lib/coordinator/memory_kernel.dart` |
| `PlanRunState`（多插件任务编排状态：冻结集/台账/配额跨续跑累计；planGrant 本体 Run 级随 Run 焚） | 会话级 + Run 级（`PlanGuard`/`PlanProposalTool` 随链装配） | `lib/coordinator/task_plan.dart` + `plan_guard.dart` + `plan_proposal_tool.dart` |

### 直连白名单基线（standards §1.4 · 只减不增）

> 口径：按**源文件 → 目标域件**逐边登记（禁写边数——计数每次提交都漂移）。核对命令：`grep -rnE "import '(\.\./)*\.\./?(mcp|sandbox|llm)/" lib/ui/`。**新增任何清单外直连即违例**（standards §1.4 类别 4）。

| 类别 | 源文件 | 目标 |
|---|---|---|
| 配置类窗口（§1.4 类别 1 · 管理面直连） | `settings_page.dart` | `mcp/{default_private_server, local_plugin_discovery, server_endpoints}`、`llm/cloud/byok_store`、`core/security/secure_storage_upgrade` |
| | `sections/byok_section.dart` | `llm/cloud/{byok_store, cloud_llm}` |
| | `sections/nodes_section.dart` | `mcp/{server_endpoints, server_probe}` |
| | `sections/local_plugins_section.dart` | `mcp/{local_plugin_discovery, trusted_plugins}` |
| | `memory_board_page.dart` | `sandbox/memory_store` |
| | `resource_center_page.dart` | `mcp/local_plugin_discovery` |
| | `trust_plugin_dialog.dart` | `mcp/{local_plugin_discovery, trusted_plugins}` |
| | `components/server_endpoint_forms.dart` | `mcp/server_endpoints` |
| 聊天窗口存量直连（遗留债） | `chat_page.dart` | `llm/cloud/cloud_llm`、`mcp/{connection_manager, default_private_server, local_plugin_discovery, server_endpoints, trusted_plugins}`、`sandbox/{conversation_store, memory_store, workspace_state_store}` |
| | `components/conversation_drawer.dart` | `sandbox/conversation_store` |
| | `components/session_context_sheet.dart` | `mcp/{local_plugin_discovery, server_endpoints}` |
| 交互组件（2026-10-23 账实补登） | `components/{dual_track_stream, chat_gate_delegates, elicitation_card}` | `mcp/elicitation`（交互协议 DTO 直连） |
| 联调 / spike 页（§1.4 类别 3 豁免 · 登记备查） | `gateway_loop_debug_page.dart` | `llm/cloud/byok_store`、`mcp/{local_plugin_discovery, mcp_client, sampling}` |
| 管理面直连（F16 账实补登 2026-10-24） | `sections/resource_center_section.dart` | `resources/resource_store` |
| | `sections/task_ledger_section.dart` | `task/task_consume_ledger` |

收敛方向 = 经 coordinator 门面（`ChatSessionService` / `McpRuntime` / `ChatRunOrchestrator`）+ 端口回传；每清一边同轮更新本表。

- **gateway → coordinator 执行面白名单（默认拒绝，standards §1.4 类别 5）**，仅限执行面 9 件：`agent_loop` / `mcp_runtime` / `mcp_tool_face` / `permission_gateway` / `pii_fence` / `hybrid_assembly` / `ref_store` / `tool_router` / `host_tool_invoker`（2026-10-23 按 §1.4 类别 5「先改清单再写 import」增：host 虚拟服务执行端口的 owner 住 coordinator——「谁拥有执行面谁组装」，避免网关逐个直连 `memory_tool_executor` / `local_resource_tool_executor` 两件）。

### 存量超标清单（standards §8.3 · 只减不增）

> 本表只登记超标文件与治理策略，**不登记即时行数**（行数每次提交都在漂移，写进文档必打架）；是否仍超标以当次扫描为准，CI 已覆盖全量 `flutter test`（见 `.github/workflows/ci.yml`）。任一件降到 800 行以下即从本清单移除。

| 文件 | 治理策略 |
|---|---|
| `ui/chat_page.dart` | 窗口层最大件；状态/控制器/组件已拆出，剩余视图骨架逐步收敛至 800 行以下 |
| `ui/components/dual_track_stream.dart` | 卡片渲染集中地；计划按卡片类型（确认卡/排查卡）拆子组件 |
| `ui/gateway_loop_debug_page.dart` | 编排已下沉 orchestrator，剩余为 UI 开关面板；只减不增 |
| `coordinator/mcp_runtime.dart` | 核心装配逻辑保持高内聚；只减不增（保留字断言 / CoW 注入 / 本机工具链已抽独立小件） |

### 契约面漂移登记（standards §8.2 · 机械门禁数据）

| 项 | 落点 | 说明 |
|---|---|---|
| 规则数据（唯一数据源） | `scripts/agent-tools/drift-registry.txt` | 三类登记：`BANNED` 退役词条（token 级）/ `CONST` 单源常量（字面量级）/ `OVERSIZE` 超标登记核对（行数级）；**新规则只加数据行** |
| 引擎（跨项目共用，全局池） | `~/.agents/toolbox/scripts/drift-guard.sh`（`toolbox run drift-guard`） | pre-commit 侧；零项目知识，读各项目 registry |
| CI 镜像（随仓库进 CI） | `test/architecture/drift_rules_test.dart` | flutter test 版，与引擎同读同一 registry；CI 无 toolbox 故走镜像 |
| 首版登记项 | 同 registry | 退役词条 = 旧工具名 `gateway__list_private_servers`（drift:keep：此处是登记说明，非调用契约）+ D1 旧键 `?strategy=`/`scope=`（PC copy 面）；单源常量 = `kMcpProtocolVersion` / `kGatewayDefaultPort`（2026-10-23 评估轮实证的双源）；超标上限 = 800 行对 `index.md` 超标清单 |

## 命令速查

见 `goodhub-workflow` skill（本仓 `.agents/skills/goodhub-workflow/SKILL.md`）。
