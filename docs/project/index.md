---
status: active
updated: 2026-10-17
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
| 任务循环（认领→心跳→回写） | `lib/task/`（TaskLoopService + TaskInference 接口） | 推理期 5s 心跳（契约 §3.3）；apply 产出按 task_action 分叉 summary_md/tags/note |
| L1/L2 权限网关（分类矩阵/确认卡会话豁免/拒绝回填） | `lib/coordinator/permission_gateway.dart` | 装饰 ToolExecutor；拍板 C2/C5/C7 语义 |
| N7 PII 出站围栏内核（正则遮蔽/反向映射/流式还原） | `lib/coordinator/pii_fence.dart` | 拍板 D1-D5；挂点=云引擎装饰器，失败→PiiMaskException 禁静默放行 |
| N7 围栏云引擎装饰器（出站遮蔽/流式还原/拦截分派） | `lib/coordinator/fenced_cloud_engine.dart` + `hybrid_assembly.dart` 接线 | 一次装配=一次 Run 映射会话（调用方按 Run 装配）；PiiFenceDelegate 缺省 null=无人值守 fail-closed，debug 页接 FenceBlockCard 双选项卡 |
| 两步熔断+步数墙排查卡契约 | `lib/coordinator/tool_breaker.dart` + `agent_loop.dart` | BlockDelegate 三操作；拍板 C1/C3 语义 |
| 上下文治理（滑动窗口/工具结果摘要化） | `lib/coordinator/context_governor.dart` + `agent_loop.dart` | 发送边界窗口化（本地历史不裁）+ 回填前端侧摘要化（拍板 E1：摘要化失败保留原文 DEGRADE 留痕）；端侧摘要器 `OnDeviceResultSummarizer` |
| UI 组件（design tokens/药丸/确认卡/排查卡/围栏拦截卡） | `lib/ui/tokens/` + `lib/ui/components/` + `lib/ui/gateway_loop_debug_page.dart` | tokens 唯一出处（goodhub-ui skill），debug 页全链接线（拍板 C4 边界） |
| 网关/熔断联调页（L1/L2 网关 + 熔断排查卡验证 + 故障注入 + 脚本引擎 + 跨源/CoW 调试） | `lib/ui/gateway_loop_debug_page.dart`（窗口层：开关收集 + 四 UI 端口 + 事件流→轨道映射）+ `lib/coordinator/debug_run_orchestrator.dart`（挂载→协商→记忆面→网关→注水→引擎→sampling→故障注入→Skills/CoW→AgentLoop 全编排，纯编排零 UI；`_FaultInjector`/`_ScriptedEngine` 可单测件；clientFactory/目录解析器/五 UI 端口注入位） | **红线**：不并回 `McpRuntime.assemble`——生产多 Server 前缀路由+JIT 发现 vs 联调单 Server 裸名+静态 tools 语义不兼容；单测 `test/coordinator/debug_run_orchestrator_test.dart`（事件流契约/故障注入/释放卫生/异常路径） |
| 应用装配入口（引擎预热/记忆清扫/首页挂载） | `lib/main.dart` | 纯装配；M1 壳迁 `lib/ui/claim_loop_page.dart`（debug 入口） |
| 聊天主页（AgentLoop 正式宿主面） | `lib/ui/chat_page.dart`（视图交互与装配）+ `lib/ui/components/chat_composer.dart`（底部输入集群，传数据+回调零依赖私有态）+ `lib/ui/chat_status_controller.dart`（状态带 pill/运行态/已耗时 + 轨道列表 + 滚动锚定/键盘/会话切换生命周期；status/tracks 双 Listenable）+ `lib/ui/components/dual_track_stream.dart`（`TrackText`/`TrackCall` 自管局部渲染）+ `lib/ui/components/status_strip.dart`/`status_capsule.dart` | 交互 SSOT `docs/product/chat-interaction.md`；运行态·轨道·40ms 流控已下沉 controller/组件；**红线**：离开运行中任务有 `PopScope` 确认拦截（abort 即停 + mounted 内落盘部分进度）；回归 `test/ui/chat_status_controller_test.dart` |
| 双轨消息流组件（TrackEntry/渲染映射） | `lib/ui/components/dual_track_stream.dart` | 卡片复用 M2/M3 组件；阅读轨文本走 StreamingRichText；TrackEntry 编解码在 UI 层（静态） |
| Markdown 子集解析器（跨仓共享包） | 外部包 `/home/zzh/app/rich_text/`（`rich_text.dart` 抽象 + `markdown_subset.dart` 实现） | goodhub 渲染器只依赖抽象（`List<RichBlock>`），parse 移调用点 |
| 阅读轨只读渲染器（console tokens 对齐） | `lib/ui/rich_text_view.dart` | 媒体块降级不吞内容；todo 只读字形；MathBlock/InlineMath 降级等宽呈现 |
| 流式性能优化（P0 流控缓冲 + P1 前缀块缓存） | `lib/ui/components/stream_text_buffer.dart` + `lib/ui/components/streaming_rich_text.dart` | 设计 SSOT `docs/design/stream-perf.md`；Buffer 40ms 节拍 + 流结束强制清空；安全切点增量解析 + RepaintBoundary 隔离；等价性 fuzz 门禁 `test/ui/streaming_rich_text_test.dart` |
| 记忆沙盒（三件套/FC1 锚点/scope 三层作用域/预算视图/审计/轮转） | `lib/sandbox/memory_store.dart` | 拍板 D4~D8 见 docs/design/m4.md §4；`underSupportDir` 生产装配 + 启动清扫挂 main |
| 记忆读写内部工具面（update_memory/query_memory） | `lib/coordinator/memory_tool_executor.dart` | 挂 Gateway 内侧（L2 裁决先于执行）；§5.1 描述引导 + §5.3 快照回显；审计三点合围见 m4.md T2 注记 |
| 会话历史持久化（每会话一 JSON/原子重写） | `lib/sandbox/conversation_store.dart` | CloudChatMessage 编解码在此；恢复降级语义见 m4.md T3b 注记 |
| 串行文件写队列（temp+rename 原子替换） | `lib/core/storage/sequential_file_writer.dart` | coding-standards §3.2 基准件；支持 `settled`/`ioDrained` 确定性握手 |
| 多服务配置面（多端点 JSON + apiKey 安全存储 + 旧键迁移 + enabled 挂载位） | `lib/mcp/server_endpoints.dart`（`ServerEndpointStore`） | 服务全生命周期收敛到设置页 `_nodesPanel`；单测 `test/mcp/server_endpoints_test.dart` |
| 节点探活（握手+工具计数计时 / 401/403 鉴权态与离线区分） | `lib/mcp/server_probe.dart`（`ServerProber`/`NodeProbeResult`） | `McpClientFactory` 注入位；探活一次性建 client 用完即弃；单测 `test/mcp/server_probe_test.dart` |
| Server 节点卡面板（端口/延迟/在线点/工具计数/鉴权态/挂载开关/增删改/默认私有钉选渲染） | `lib/ui/sections/nodes_section.dart`（`NodesSection`） | 增删改同 `mcp_servers.json`；探活按需不自动网络化；注入位 `endpointStoreOverride`/`probeOverride`/`autoProbe`；钉选 owner 在 settings_page（`isDefaultPrivate`/`onPinToggle` 透传）；段 State 混合 `AutomaticKeepAliveClientMixin`（滚动不丢态，闸见 `test/ui/settings_sections_keepalive_test.dart`）；单测 `test/ui/server_nodes_panel_test.dart` |
| 本地插件面板（Binder 发现项渲染/信任态 pill/信任卡片入口；零配置自动挂载，不落用户 JSON） | `lib/ui/sections/local_plugins_section.dart`（`LocalPluginsSection`） | 注入位 `localScanOverride`/`localChangesOverride`；单测 `test/ui/local_plugins_panel_test.dart` |
| 设置页（原服务大厅：Skill 覆写管理/BYOK/跨源授权/PC 远程网关/本地插件撤销信任/关于段） | `lib/ui/settings_page.dart`（页面骨架 + 跨段 owner：ListView 顺序/toast/错误行/默认私有钉选持久读写）+ 七段各自落在 `lib/ui/sections/{byok,nodes,local_plugins,gateway,cow,cross_source,about}_section.dart`（文件头有 scope 边界声明与各段迁移语义） | BYOK 多 profile 增删改 + 置顶切换生效（首位=生效对齐 hybrid_assembly；apiKey 走 SecureKeyValue）；「关于」段 = 版本 + 检查更新常驻 + 长按标题进 debug 联调（kDebugMode）；**红线**：入口只在聊天页侧边栏（AppBar 无设置按钮）；单测 `test/ui/byok_panel_test.dart` + `settings_page_test.dart`（关于面板/长按联调） |
| 记忆看板（三 Tab 查看/编辑/导出/粉碎 + ops.log 人类可读渲染） | `lib/ui/memory_board_page.dart` | store 编辑面 `updateEntry/deleteEntry/purgeUserScope/listOpsLog/exportAll`（memory_store.dart）；ChatPage 侧边栏入口；单测 `test/ui/memory_board_page_test.dart` + `test/sandbox/memory_board_store_test.dart` |
| token 字符级粗估口径 SSOT | `lib/core/tokens.dart` | 自 context_governor 下沉（层级纪律），governor 原位 re-export |
| 应用内自更新（清单模型/下载校验/安装器/更新页） | `lib/update/` + `lib/ui/update_page.dart` | 入口 = chat_page ⚙ 调试菜单「检查更新」；设计 SSOT `docs/design/self-update.md` |
| 聚合网关服务器（Streamable HTTP `/mcp` / 会话 / Bearer / SSE 下行 / 15s 心跳） | `lib/gateway/gateway_server.dart` | thirdconnect §7；协议 2025-06-18；**红线**：SSE 起点必设 `bufferOutput=false`（goodshare 同坑已修 + 逐帧计时回归钉子）；单测 `test/gateway/gateway_server_test.dart` |
| 网关协议处理器（工具聚合 / 前缀分发 / 进度转 SSE / `tools/list_changed`） | `lib/gateway/mcp_gateway_handler.dart` | `GatewayHandler.toolsCall` 剥前缀直达 `face.client`；阻断类结果经 `errorCode` 回协议错误帧 |
| 网关装配与生命周期（双源装配 / 包变更重扫 / 原生前台服务桥 / Wi-Fi IP） | `lib/gateway/gateway_controller.dart` + `gateway_service_channel.dart` + `android/`（`GatewayForegroundService`/`GatewayServiceBridge`） | TC12 FSI 醒目呼叫 = `L2AlertActivity` + `GatewayConsentBridge`；电池优化白名单留真机 |
| 网关入站安全闭环（L1/L2 裁决 / 45s 熔断 / 会话豁免 / PII 出站 fail-closed / 入站审计） | `lib/gateway/gateway_security.dart` | 复用 `permission_gateway.classify` + `DialogGateDelegate`（`appNavigatorKey` 后台弹层）；ops.log 落 `server=gateway`；单测 `test/gateway/gateway_security_test.dart` |
| 网关环路防护（Trace-ID 在途集合引用计数 / `hop_count>0` 闸门 / 上限 2 熔断 / TTL 300s 惰性驱逐） | `lib/gateway/gateway_loop_guard.dart` | 阻断回 JSON-RPC `-32000`；出站 `params._meta` 平级注入 `traceId`+`hopCount+1`；单测 `test/gateway/gateway_loop_guard_test.dart` |
| 网关背压（per-server 并发上限 4 + FIFO 排队） | `lib/gateway/gateway_backpressure.dart` | thirdconnect §9.6；只包真实执行段（L2 确认等待不占槽）；无 429 语义（有界队列 429 已显式关闭，见 architecture 待拍板清单） |
| 本地插件发现（PackageManager 扫描 + 包变更广播 → 运行时自动挂载） | `lib/mcp/local_plugin_discovery.dart` | 产出「系统托管端点」= 装配期运行时 face（不落用户 JSON store，区别于 `server_endpoints.dart`） |
| 同机插件信任（签名 SHA-256 白名单持久化 + 信任卡片 UI） | `lib/mcp/trusted_plugins.dart` + `lib/ui/trust_plugin_dialog.dart` | 同签名零弹窗 + 开发者模式第三方信任卡；gateway headless 跳过；真机自动化 `integration_test/trust_gate_test.dart` |
| Sampling 反向请求（宿主收端 + 反向在途表 + `answerReverse`） | `lib/mcp/sampling.dart` | 宿主推理侧闭环待推理源 |
| 同机 Binder 传输（AIDL 通道 / 状态机 / 挂起队列 / DeathRecipient / 事件回传） | `lib/mcp/transport/`（Dart `BinderTransport`）+ `android/`（AIDL + MethodChannel 桥） | TC9 控制面；插件侧 SDK = `android/plugin-core`；≥128KB 的 `mcp-blob://` 数据面未落地（thirdconnect 待办） |
| 多 Server 路由与 JIT 元工具（前缀隔离 / 激活集 / `get_connected_apps` / `activate_server_tools` / `use_server`） | `lib/coordinator/tool_router.dart` + `lib/coordinator/discovery_executor.dart` | `<server_id>__<tool>`；装配在 `chat_page._send`；**注意** `lib/mcp/tool_router.dart` 为孤立件（仅测试引用，海关过滤在其中，待收编） |
| `$ref` 暂存池（内存/文件双介质 / TTL 30min / Session 即焚 / 启动幂等清池） | `lib/coordinator/ref_store.dart` | architecture §9；启动清池 `sweepStartupOrphans` 挂 `main.dart`；单测 `test/coordinator/ref_store_test.dart` |
| 端侧模型管理链（目录/下载/清单缓存） | `archive/local_model/`（**已归档，非 lib 代码**） | 零接线零测试，端侧推迟拍板未翻转前不复活；复活步骤见该目录 `README.md`；`lib/llm/llm_model.dart` 仍为活代码（被 `llm.dart` 引用） |

## 文档落点

| 主题 | 落点 | 状态 |
|---|---|---|
| MCP 接缝契约（SSOT） | goodshare 仓 `docs/design/ai-app-split.md` | active（跨仓只读引用） |
| 宿主自身交互产品设计（聊天/决策卡片/双轨流） | 本仓 `docs/product/chat-interaction.md` | active（交互 SSOT） |
| UI 设计规范（控制台风格 SSOT） | 本仓 `docs/project/ui-design.md`；落点纪律见 `.agents/skills/goodhub-ui/SKILL.md` | active |
| 工程编码基准（规则契约 SSOT，含 MCP 对 AI 接口契约 §5） | 本仓 `docs/project/coding-standards.md`；项目基线数据（内核登记/白名单/超标清单）= 本文件「工程基线数据」 | active |
| 同机互联与网关设计（Binder/UDS/网关/插件 SDK/TC1~TC14） | 本仓 `docs/design/thirdconnect.md` | active |
| 本地插件准入与信任（签名/信任卡片/生态开放度） | 本仓 `docs/design/local-plugin-access-trust.md` | active |
| M4 施工设计（双轨/记忆/多 Server/T4 韧性） | 本仓 `docs/design/m4.md` | active |
| 自更新（整包/清单/串包防御） | 本仓 `docs/design/self-update.md` | active |
| Binder 联调评估与修复请求 | 本仓 `docs/design/goodhub-goodshare-binder-eval.md` + `goodshare-binder-poc-fix-request.md` | active（结果回写投 thirdconnect 域） |
| 端侧 LLM 设计（LiteRT-LM / FoundationModels） | goodshare 仓 `docs/design/on-device-llm.md` | active（跨仓只读） |
| Host 网关架构 · 访问性模型 · 记忆捎带提取（Provider×Tier 解耦 / 聚合反向代理 / In-band `<workspace_update>`） | 本仓 `docs/design/host-gateway-accessibility-memory.md` | active；绑定 epic = `chatmessage`（§3 记忆提取主战场，§1/§2 依赖项） |
| 窗口解耦（内核 + 多投影：ServiceDirectory / McpRuntime / ConversationSession） | 本仓 `docs/design/window-kernel-split.md` | 内容 SSOT（架构裁决十二项 §8.1、路线图 §7.5）；施工已由 arch-hardening 承接 |
| 架构债修复施工稿（内核单入口 + 反向边斩断，步 0→3 勾稽） | 本仓 `docs/design/arch-hardening.md` | active；绑定 epic = `arch-hardening`；步 0→3 已完成，剩余 = 真机冒烟验收 |
| 普通用户可用性加固（冷启动/错误自救/术语白话/危险权重/DEGRADE 可见性） | 本仓 `docs/design/ux-hardening.md` | active；epic `ux-hardening` 已收尾归档 |

## 架构债与依赖违例登记（2026-10-16 架构盘点立 · 改相关代码前必读）

> 违例黑名单、依赖方向红灯与施工纪律的**规则 SSOT** = `docs/project/coding-standards.md` §1.0 护栏表 / §1.1（规则链：`window-kernel-split.md` §5 → coding-standards）。本表只作**改前定位速查**；每清零一项，同步更新：① 本表结项归档 ② coding-standards §1.0（如涉新增/清零红灯规则） ③ 设计稿/ epic todos。不在本表之外的散修须先在此登记再动手。**活跃表只留未结项**，已清零项移入下方归档区。

### 活跃债（未结项 · 第一屏只放风险点）

| # | 未结架构债与风险点 | 落点 | 现状与收敛条件 |
|---|---|---|---|
| 11 | 投影平面 `workspaceId` 接线（D-D 投影平面三元 `{activePrivateServerId, publicServerIds, workspaceId}` 缺 `workspaceId`） | `gateway/*`（ProjectionContext） | 待接：PC 连接不携带 workspaceId，记忆分区归属 chatmessage 域 per-conversation（`workspace_states`）；网关侧接线待 chatmessage 记忆分区工作 |
| 13 | **CI 缺口**：无 `.github/` 无 `.gitlab-ci.yml`，`flutter test` 从无自动化触发入口 | 仓库根（待建 workflow）；现状兜底 = `scripts/agent-tools/pre-commit-gate.sh` | 现状 = pre-commit 默认跑秒级 `arch-guard`（R1~R8），`flutter test` 版（arch-deps，~12s 超钩子 10s 预算）经 `ARCH_GATE_FULL=1` 显式开关跑。**收敛条件**：建 CI workflow 固定跑 `flutter analyze` + `flutter test --timeout 180s` + `arch-guard.sh --json`；存量教训 = conversation_drawer_test 隔夜腐化（fixture 写死绝对日期）长期未暴露，根因正是从不跑测试 |
| 14 | **GatewayController 无装配注入位**（`localPluginDiscovery` / `serverEndpointStore` 为顶层全局直接引用）→ 重扫释放与起服失败回滚两条路径缺网关级单测，只能真机验收 | `lib/gateway/gateway_controller.dart` | 释放接线已落地（`_mounted` 句柄表 + `_unmountAll` + 重扫/停服/起服失败三路回滚，`McpMount.close` 为唯一释放通道），但断言只到挂载原语层（`test/gateway/gateway_session_isolation_test.dart` 用例 5~7）。**收敛条件** = 加 `localPluginDiscovery` / `serverEndpointStore` 注入位后补网关级重扫与回滚断言；真机冒烟 = 插件安装触发重扫、停服后无残留连接 |

### 已结项归档（只减不增 · 过程细节归 Git log / epic devlog）

- #1 服务目录三拼收敛（含 gateway 处漏 prefs 迁移活 bug 修复）：`lib/app/service_directory.dart` 唯一 owner（2026-10-16 结项）
- #2/#3 chat_page 装配越权 + 装配第二/第三副本收敛：统一至 `McpRuntime.mount/mountEndpoint` 挂载原语（2026-10-16 结项）
- #4/#5 `mcp→coordinator/sandbox`、`mcp/sandbox→llm` 反向依赖斩断：face 注入 + 端口下沉 core（2026-10-16 结项）
- #6 `ui↔gateway` 跨域环解环：弹层迁 `lib/ui/gateway_consent_dialog.dart`（2026-10-16 结项）
- #7 会话态隔离：per-connection 投影（`forSession()` + 防火墙，`gateway_per_session_projection_test.dart`）+ host-level 默认投影源澄清（2026-10-16 结项；`workspaceId` 接线见活跃债 #11）
- #8 会话态手工枚举消除：收敛至 `ConversationSession`（2026-10-16 结项）
- #9 装配级 / chat_page 级测试基线补齐：`test/coordinator/mcp_runtime_test.dart` 等（2026-10-16 结项）
- #10 全仓并发 flaky 修复：`SequentialFileWriter.settled` + `MemoryStore/WorkspaceStateStore.ioDrained` 确定性握手，706/706 全绿（2026-10-16 结项）
- #12 UI 侧 `dart:io` 存量清零：`update_page.dart` 改持路径 `String`、`error_copy.dart` 判定下沉 `core/errors/transport_error_kind.dart`；R1 白名单维持原 3 项只减不增（2026-10-17 结项）

## 工程基线数据（coding-standards 配套 · 数据 SSOT）

> 本节是 `docs/project/coding-standards.md` 各契约条款引用的**项目基线数据**；规则正文在 standards，本节只放数据。变更时同轮更新对应条款指针。

### 内核登记表（standards §2.1）

| 内核 | 生命周期层级 | 落点 |
|---|---|---|
| `ServiceDirectory`（服务目录单入口） | 应用级 | `lib/app/service_directory.dart` |
| `McpRuntime`（MCP 侧 Run 级装配唯一入口，含 `ConversationSession`） | 装配 = 应用级 / Run 句柄 = Run 级 | `lib/coordinator/mcp_runtime.dart` |
| `ChatSessionService`（会话内核，transcript 过边界走中立数据） | 会话级 | `lib/coordinator/chat_session_service.dart` |
| `MemoryKernel`（记忆内核，含 `onWriteFailure` 可观测端口） | 会话级 | `lib/coordinator/memory_kernel.dart` |

### 直连白名单基线（standards §1.4 · 只减不增）

- **配置类窗口现状边**：`byok_section→llm/cloud`、`nodes_section→mcp`、`local_plugins_section→mcp`、`trust_plugin_dialog→mcp`、`memory_board_page→sandbox`、`gateway_consent_dialog→gateway`。配置类窗口清单：`settings_page` + `ui/sections/*`、`memory_board_page`、`update_page`、`trust_plugin_dialog`、`components/server_endpoint_forms`、`gateway_consent_dialog`。
- **聊天窗口存量直连（遗留债，12 边）**：

| 源文件 | 目标 |
|---|---|
| `chat_page.dart` | `llm/cloud/cloud_llm`（1）、`mcp/{connection_manager, default_private_server, local_plugin_discovery, server_endpoints, trusted_plugins}`（5）、`sandbox/{conversation_store, memory_store, workspace_state_store}`（3） |
| `components/conversation_drawer.dart` | `sandbox/conversation_store`（1） |
| `components/session_context_sheet.dart` | `mcp/{local_plugin_discovery, server_endpoints}`（2） |

  **新增任何第 13 边即违例**（standards §1.4 类别 4）。收敛方向 = 经 coordinator 门面（`ChatSessionService` / `McpRuntime` / `ChatRunOrchestrator`）+ 端口回传；每清一边同轮更新本表。

- **gateway → coordinator 执行面白名单（默认拒绝，standards §1.4 类别 5）**，仅限执行面 8 件：`agent_loop` / `mcp_runtime` / `mcp_tool_face` / `permission_gateway` / `pii_fence` / `hybrid_assembly` / `ref_store` / `tool_router`。

### 存量超标清单（standards §8.3 · 只减不增）

> 本表只登记超标文件与治理策略，**不登记即时行数**（行数每次提交都在漂移，写进文档必打架）；是否仍超标以当次扫描为准，CI 自动化缺口见架构债 #13。任一件降到 800 行以下即从本清单移除。

| 文件 | 治理策略 |
|---|---|
| `ui/chat_page.dart` | 窗口层最大件；状态/控制器/组件已拆出，剩余视图骨架逐步收敛至 800 行以下 |
| `ui/components/dual_track_stream.dart` | 卡片渲染集中地；计划按卡片类型（确认卡/排查卡）拆子组件 |
| `ui/gateway_loop_debug_page.dart` | 编排已下沉 orchestrator，剩余为 UI 开关面板；只减不增 |
| `coordinator/mcp_runtime.dart` | 核心装配逻辑保持高内聚；只减不增 |

## 命令速查

见 `goodhub-workflow` skill（本仓 `.agents/skills/goodhub-workflow/SKILL.md`）。
