---
description: goodhub（AI 宿主 App）的「功能 → 代码落点 + 文档落点」归属索引。改 MCP 客户端、LLM 引擎、任务认领/回写、UI 前先查本表定位，避免全仓扫描。
---

# goodhub · 功能落点索引

> 机制规范见全局 project-index skill；本文件只登记项目数据。项目初建，表随实现增量登记——禁止一次性铺满。

## 代码落点

| 功能 | 落点 | 备注 |
|---|---|---|
| MCP 客户端（连接/claim/touch/apply） | `lib/mcp/` | JSON-RPC over Streamable HTTP；契约 = goodshare 仓 `docs/design/ai-app-split.md` §3；tools/call 结果按 MCP content 信封解包（T7 修复） |
| LLM 引擎（端侧 LiteRT-LM / 云端） | `lib/llm/` + `android/`（LlmBridge.kt） | M2 自 goodshare 随迁；proguard keep 教训见 workflow skill |
| 云端 BYOK 引擎（双协议/SSE 流式/BYOK 配置） | `lib/llm/cloud/` | M2-T1；密钥走 `core/security/` SecureKeyValue；装配入口 `engineFor` |
| 混合编排 Coordinator（降级状态机/云↔端路由/Agent Loop/MCP 工具面） | `lib/coordinator/` | M2-T2；`HybridCloudEngine` 路由 + `AgentLoop` 工具环（maxTurns=10）+ `McpToolFace`；默认装配 `assembleDefaultHybridEngine` |
| 任务循环（认领→心跳→回写） | `lib/task/`（TaskLoopService + TaskInference 接口） | M1 建；M2-T2 换真实推理内核 + 推理期 5s 心跳（契约 §3.3）；apply 产出按 task_action 分叉 summary_md/tags/note（T7 修复） |
| L1/L2 权限网关（分类矩阵/确认卡会话豁免/拒绝回填） | `lib/coordinator/permission_gateway.dart` | M2-T4a；装饰 ToolExecutor，拍板 C2/C5/C7 语义 |
| N7 PII 出站围栏内核（正则遮蔽/反向映射/流式还原） | `lib/coordinator/pii_fence.dart` | M2-T5a；拍板 D1-D5；挂点=云引擎装饰器（T5b 接线），失败→PiiMaskException 禁静默放行 |
| N7 围栏云引擎装饰器（出站遮蔽/流式还原/拦截分派） | `lib/coordinator/fenced_cloud_engine.dart` + `hybrid_assembly.dart` 接线 | M2-T5b/c；一次装配=一次 Run 映射会话（调用方按 Run 装配）；PiiFenceDelegate 缺省 null=无人值守 fail-closed，debug 页接 FenceBlockCard 双选项卡 |
| 两步熔断+步数墙排查卡契约 | `lib/coordinator/tool_breaker.dart` + `agent_loop.dart` | M2-T4b；BlockDelegate 三操作，拍板 C1/C3 语义 |
| 上下文治理（滑动窗口/工具结果摘要化） | `lib/coordinator/context_governor.dart` + `agent_loop.dart` | M2-T6；发送边界窗口化（本地历史不裁）+ 回填前端侧摘要化，拍板 E1（摘要化失败保留原文 DEGRADE 留痕）；端侧摘要器 `OnDeviceResultSummarizer` |
| UI 组件（design tokens/药丸/确认卡/排查卡/围栏拦截卡） | `lib/ui/tokens/` + `lib/ui/components/` + `lib/ui/gateway_loop_debug_page.dart` | M2-T4c/T5c；tokens 唯一出处（goodhub-ui skill），debug 页全链接线（拍板 C4 边界） |
| 网关/熔断联调页（L1/L2 网关 + 熔断排查卡验证 + 故障注入 + 脚本引擎 + 跨源/CoW 调试） | `lib/ui/gateway_loop_debug_page.dart`（**窗口层**：开关收集 + 四 UI 端口 + 事件流→轨道映射；852 行）+ `lib/coordinator/debug_run_orchestrator.dart`（2026-10-17 window-slim P1-B 下沉：挂载→协商→记忆面→网关→注水→引擎→sampling→故障注入→Skills/CoW→AgentLoop 全编排，纯编排零 UI；`_FaultInjector`/`_ScriptedEngine` 随迁成可单测件；clientFactory/目录解析器/五 UI 端口全注入位；**不并回 McpRuntime.assemble**——生产多 Server 前缀路由+JIT 发现 vs 联调单 Server 裸名+静态 tools 语义不兼容） | M2-T4c/T5c；单测 `test/coordinator/debug_run_orchestrator_test.dart`（事件流契约/故障注入/释放卫生/异常路径 4 例，纯 Dart 假传输） |
| 应用装配入口（引擎预热/记忆清扫/首页挂载） | `lib/main.dart` | M4-T3/D9 收敛纯装配；M1 壳迁 `lib/ui/claim_loop_page.dart`（debug 入口） |
| 聊天主页（AgentLoop 正式宿主面） | `lib/ui/chat_page.dart` | M4-T3/D9 首页接管；交互 SSOT `docs/product/chat-interaction.md`；连接配置 SharedPreferences 过渡态 |
| 双轨消息流组件（TrackEntry/渲染映射） | `lib/ui/components/dual_track_stream.dart` | M4-T3；卡片全量复用 M2/M3；T3b 恢复装配复用；阅读轨文本走 StreamingRichText（stream-perf P1） |
| Markdown 子集解析器（**已抽为跨仓共享包**） | 外部包 `/home/zzh/app/rich_text/`（`rich_text.dart` 抽象 + `markdown_subset.dart` 实现） | M4-T3/D12 随迁后按 DIP 拆分（2026-10-14）；goodhub 渲染器只依赖抽象（`List<RichBlock>`），parse 移调用点；**本仓 `lib/doc/` 已不存在**，勿再按旧路径引用 |
| 阅读轨只读渲染器（console tokens 对齐） | `lib/ui/rich_text_view.dart` | M4-T3/D12；媒体块降级不吞内容；todo 只读字形；MathBlock/InlineMath 降级等宽呈现（2026-10-14 adopt 共享包演进） |
| 流式性能优化（P0 流控缓冲 + P1 前缀块缓存） | `lib/ui/components/stream_text_buffer.dart` + `lib/ui/components/streaming_rich_text.dart` | stream-perf（设计 SSOT `docs/design/stream-perf.md`）；Buffer 40ms 节拍 + 流结束强制清空；安全切点增量解析 + RepaintBoundary 隔离；等价性 fuzz 门禁在 `test/ui/streaming_rich_text_test.dart` |
| 记忆沙盒（三件套/FC1 锚点/scope 三层作用域/预算视图/审计/轮转） | `lib/sandbox/memory_store.dart` | M4-T1/T2；拍板 D4~D8 见 docs/design/m4.md §4；`underSupportDir` 生产装配 + 启动清扫挂 main |
| 记忆读写内部工具面（update_memory/query_memory） | `lib/coordinator/memory_tool_executor.dart` | M4-T2；挂 Gateway 内侧（L2 裁决先于执行）；§7.1 描述引导 + §7.3 快照回显；审计三点合围见 m4.md T2 注记 |
| 会话历史持久化（每会话一 JSON/原子重写） | `lib/sandbox/conversation_store.dart` | M4-T3b；CloudChatMessage 编解码在此，TrackEntry 编解码在 UI 层（dual_track_stream 静态）；恢复降级语义见 m4.md T3b 注记 |
| 串行文件写队列（temp+rename 原子替换） | `lib/core/storage/sequential_file_writer.dart` | M4-T1；coding-standards §5.1 基准件（续链与透传分离修正） |
| 多服务配置面（多端点 JSON + apiKey 安全存储 + 旧键迁移 + enabled 挂载位） | `lib/mcp/server_endpoints.dart`（`ServerEndpointStore`） | M4-T6-1；M4-T5 增 `enabled`（节点卡卸载开关，_send 装配过滤）；服务全生命周期已收敛到设置页 `_nodesPanel`（2026-10-16：ChatPage ⚙ 弹层并入并删除 `_openSettings`）；单测 `test/mcp/server_endpoints_test.dart` |
| 节点探活（握手+工具计数计时 / 401/403 鉴权态与离线区分） | `lib/mcp/server_probe.dart`（`ServerProber`/`NodeProbeResult`） | M4-T5；`McpClientFactory` 注入位；探活一次性建 client 用完即弃；单测 `test/mcp/server_probe_test.dart` |
| Server 节点卡面板（端口/延迟/在线点/工具计数/鉴权态/挂载开关/增删改/默认私有钉选渲染） | `lib/ui/sections/nodes_section.dart`（`NodesSection`，2026-10-17 window-slim P1-A 自 settings_page 迁出） | M4-T5；增删改原 ChatPage ⚙（同 `mcp_servers.json`）；探活按需不自动网络化；注入位 `endpointStoreOverride`/`probeOverride`/`autoProbe`；钉选 owner 仍在页面（`isDefaultPrivate`/`onPinToggle` 透传）；段 State 混合 `AutomaticKeepAliveClientMixin`（滚动不丢态，闸见 `test/ui/settings_sections_keepalive_test.dart`）；单测 `test/ui/server_nodes_panel_test.dart` |
| 本地插件面板（Binder 发现项渲染 / 信任态 pill / 信任卡片入口；零配置自动挂载，不落用户 JSON） | `lib/ui/sections/local_plugins_section.dart`（`LocalPluginsSection`，2026-10-17 迁出） | 2026-10-15 新增（补齐真缺口）；注入位 `localScanOverride`/`localChangesOverride`；单测 `test/ui/local_plugins_panel_test.dart` |
| 设置页（原服务大厅：Skill 覆写管理 / BYOK / 跨源授权 / 2026-10-16 并入 PC 远程网关 + 本地插件撤销信任 + 关于段） | `lib/ui/settings_page.dart`（**页面骨架** + 跨段 owner：ListView 顺序/toast/错误行/**默认私有钉选持久读写**）+ 七段各自落在 `lib/ui/sections/{byok,nodes,local_plugins,gateway,cow,cross_source,about}_section.dart`（2026-10-17 window-slim P1-A 全量拆出；文件头有 scope 边界声明与各段迁移语义） | M3-T4 建 + M4-T5 增 BYOK 面板（多 profile 增删改 + 置顶切换生效，首位=生效对齐 hybrid_assembly；apiKey 走 SecureKeyValue）；2026-10-16 增「关于」段（版本 + **检查更新**常驻 + **长按标题**进 debug 联调，kDebugMode）；**入口只在聊天页侧边栏**（AppBar 无设置按钮）；单测 `test/ui/byok_panel_test.dart` + `settings_page_test.dart`（关于面板/长按联调） |
| 记忆看板（三 Tab 查看/编辑/导出/粉碎 + ops.log 人类可读渲染） | `lib/ui/memory_board_page.dart` | M4-T5；store 编辑面 `updateEntry/deleteEntry/purgeUserScope/listOpsLog/exportAll`（memory_store.dart）；ChatPage 侧边栏入口；单测 `test/ui/memory_board_page_test.dart` + `test/sandbox/memory_board_store_test.dart` |
| token 字符级粗估口径 SSOT | `lib/core/tokens.dart` | M4-T1 自 context_governor 下沉（层级纪律），governor 原位 re-export |
| 应用内自更新（清单模型/下载校验/安装器/更新页） | `lib/update/` + `lib/ui/update_page.dart`（入口=chat_page ⚙ 调试菜单「检查更新」） | self-update epic（goodshare 同款移植）；发布侧 `scripts/release-r2.sh` + `upload-r2.mjs`；设计 SSOT `docs/design/self-update.md` |
| 聚合网关服务器（Streamable HTTP `/mcp` / 会话 / Bearer / SSE 下行 / 15s 心跳） | `lib/gateway/gateway_server.dart` | G1/G2/G5（thirdconnect §7）；协议 2025-06-18；SSE 起点必设 `bufferOutput=false`（goodshare 同坑已修 + 逐帧计时回归钉子）；单测 `test/gateway/gateway_server_test.dart` |
| 网关协议处理器（工具聚合 / 前缀分发 / 进度转 SSE / `tools/list_changed`） | `lib/gateway/mcp_gateway_handler.dart` | G2；`GatewayHandler.toolsCall` 剥前缀直达 `face.client`；阻断类结果经 `errorCode` 回协议错误帧 |
| 网关装配与生命周期（双源装配 / 包变更重扫 / 原生前台服务桥 / Wi-Fi IP） | `lib/gateway/gateway_controller.dart` + `gateway_service_channel.dart` + `android/`（`GatewayForegroundService`/`GatewayServiceBridge`） | G4/G5；TC12 FSI 醒目呼叫 = `L2AlertActivity` + `GatewayConsentBridge`；电池优化白名单留真机 |
| 网关入站安全闭环（L1/L2 裁决 / 45s 熔断 / 会话豁免 / PII 出站 fail-closed / 入站审计） | `lib/gateway/gateway_security.dart` | G3；复用 `permission_gateway.classify` + `DialogGateDelegate`（`appNavigatorKey` 后台弹层）；ops.log 落 `server=gateway`；单测 `test/gateway/gateway_security_test.dart` |
| **网关环路防护**（Trace-ID 在途集合引用计数 / `hop_count>0` 闸门 / 上限 2 熔断 / TTL 300s 惰性驱逐） | `lib/gateway/gateway_loop_guard.dart` | 2026-10-15 SA-Q5（A2 止血，F1.10）；阻断回 JSON-RPC `-32000`；出站 `params._meta` 平级注入 `traceId`+`hopCount+1`；单测 `test/gateway/gateway_loop_guard_test.dart` 9 例 |
| 网关背压（per-server 并发上限 4 + FIFO 排队） | `lib/gateway/gateway_backpressure.dart` | G5 / thirdconnect §9.6；只包真实执行段（L2 确认等待不占槽）；无 429 语义（有界队列 429 已显式关闭，见 architecture 待拍板清单） |
| 本地插件发现（PackageManager 扫描 + 包变更广播 → 运行时自动挂载） | `lib/mcp/local_plugin_discovery.dart` | T-trans-4；产出「系统托管端点」= 装配期运行时 face（**不落用户 JSON store**，区别于 `server_endpoints.dart`） |
| 同机插件信任（签名 SHA-256 白名单持久化 + 信任卡片 UI） | `lib/mcp/trusted_plugins.dart` + `lib/ui/trust_plugin_dialog.dart` | §1.2.6；同签名零弹窗 + 开发者模式第三方信任卡；gateway headless 跳过；真机自动化 `integration_test/trust_gate_test.dart` |
| Sampling 反向请求（宿主收端 + 反向在途表 + `answerReverse`） | `lib/mcp/sampling.dart` | M3-T1 建 / T-trans-3 接线；宿主推理侧闭环待推理源（reverseDemo 未达 PC 属环境未就绪） |
| 同机 Binder 传输（AIDL 通道 / 状态机 / 挂起队列 / DeathRecipient / 事件回传） | `lib/mcp/transport/`（Dart `BinderTransport`）+ `android/`（AIDL + MethodChannel 桥） | T-trans-2/3（TC9 控制面）；插件侧 SDK = `android/plugin-core`；≥128KB 的 `mcp-blob://` 数据面**未落地**（thirdconnect 待办） |
| 多 Server 路由与 JIT 元工具（前缀隔离 / 激活集 / `get_connected_apps` / `activate_server_tools` / `use_server`） | `lib/coordinator/tool_router.dart` + `lib/coordinator/discovery_executor.dart` | M4-T6；`<server_id>__<tool>`；装配在 `chat_page._send`；**注意** `lib/mcp/tool_router.dart` 为孤立件（仅测试引用，海关过滤在其中，待收编） |
| `$ref` 暂存池（内存/文件双介质 / TTL 30min / Session 即焚 / 启动幂等清池） | `lib/coordinator/ref_store.dart` | M2.5-T3（architecture §9）；启动清池 `sweepStartupOrphans` 已挂 `main.dart`（2026-10-15 闭环）；单测 `test/coordinator/ref_store_test.dart` 11 例 |
| 端侧模型管理链（目录/下载/清单缓存） | `archive/local_model/`（**已归档，非 lib 代码**） | 2026-10-15 SA-Q3 归档；零接线零测试，端侧推迟拍板未翻转前不复活；复活步骤见该目录 `README.md`；`lib/llm/llm_model.dart` 仍为活代码（被 `llm.dart` 引用） |

## 文档落点

| 主题 | 落点 | 状态 |
|---|---|---|
| MCP 接缝契约（SSOT） | goodshare 仓 `docs/design/ai-app-split.md` | active（跨仓只读引用） |
| 宿主自身交互产品设计（聊天/决策卡片/双轨流） | 本仓 `docs/product/chat-interaction.md` | active（M4-T3 立稿，交互 SSOT） |
| UI 设计规范（控制台风格 SSOT） | 本仓 `docs/product/ui-design.md`；落点纪律见 `.agents/skills/goodhub-ui/SKILL.md` | active |
| 工程编码基准（编码规范 SSOT，含 MCP 对 AI 接口契约 §7） | 本仓 `docs/project/coding-standards.md` | active（§7 已随网关解冻生效） |
| 同机互联与网关设计（Binder/UDS/网关/插件 SDK/TC1~TC14） | 本仓 `docs/design/thirdconnect.md` | active |
| 本地插件准入与信任（签名/信任卡片/生态开放度） | 本仓 `docs/design/local-plugin-access-trust.md` | active |
| M4 施工设计（双轨/记忆/多 Server/T4 韧性） | 本仓 `docs/design/m4.md` | active |
| 自更新（整包/清单/串包防御） | 本仓 `docs/design/self-update.md` | active |
| Binder 联调评估与修复请求 | 本仓 `docs/design/goodhub-goodshare-binder-eval.md` + `goodshare-binder-poc-fix-request.md` | active（注意：文中引用的 `context/epics/goodhub-local-plugin/` **不存在**，结果回写改投 thirdconnect 域） |
| 端侧 LLM 设计（LiteRT-LM / FoundationModels） | **本仓不存在**——goodshare 仓 `docs/design/on-device-llm.md`（跨仓只读） | 勿在本仓按此路径引用 |
| Host 网关架构 · 访问性模型 · 记忆捎带提取（Provider×Tier 解耦 / 聚合反向代理 / In-band `<workspace_update>`） | 本仓 `docs/design/host-gateway-accessibility-memory.md` | active；绑定 epic = `chatmessage`（§3 记忆提取主战场，§1/§2 依赖项） |
| 窗口解耦（内核 + 多投影：ServiceDirectory / McpRuntime / ConversationSession） | 本仓 `docs/design/window-kernel-split.md` | 内容 SSOT（架构裁决十二项 §8.1、路线图 §7.5）；施工已由 arch-hardening 承接 |
| 架构债修复施工稿（内核单入口 + 反向边斩断，步 0→3 勾稽） | 本仓 `docs/design/arch-hardening.md` | active；绑定 epic = `arch-hardening`；步 0→3 已完成（2026-10-16），剩余 = 真机冒烟验收 + #7 共享态债 |
| 普通用户可用性加固（冷启动/错误自救/术语白话/危险权重/DEGRADE 可见性） | 本仓 `docs/design/ux-hardening.md` | active；epic `ux-hardening` 已收尾归档（2026-10-16 ::done，9 项全闭环；page-revamp 清零后的第二批） |

## 架构债与依赖违例登记（2026-10-16 架构盘点立 · 改相关代码前必读）

> 违例黑名单、依赖方向红灯与施工纪律全量在 `goodhub-workflow` skill「架构依赖纪律与修复施工规范」节（规则 SSOT 链：`window-kernel-split.md` §5 → `coding-standards.md` §1.1）。本表只作**改前定位速查**；每清零一项，同步更新：① 本表状态列 ② workflow 红灯清单 ③ 设计稿/ epic todos。不在本表之外的散修须先在此登记再动手。

| # | 债 | 落点 | 状态 |
|---|---|---|---|
| 1 | **服务目录三拼且不一致**（gateway 处漏 prefs 迁移 = 活 bug，正确性缺陷） | `lib/app/service_directory.dart`（唯一 owner） | ✅ 已清零（步 0 三拼收敛 + 活 bug 修复，2026-10-16） |
| 2 | chat_page 装配越权（`_send` 内联 client/face/router/装饰器链） | `lib/coordinator/mcp_runtime.dart` | ✅ 已清零（步 1 搬迁 + 步 3 接线，2026-10-16） |
| 3 | 装配第二/第三副本（无装饰器链版 / 联调简化版） | `McpRuntime.mount/mountEndpoint` 挂载原语 | ✅ 已清零（步 2 三调用点收敛，2026-10-16） |
| 4 | `mcp → coordinator/sandbox` 反向依赖 | `mcp/connection_face.dart`（face 注入）+ `core/tool_result.dart` + `core/audit_sink.dart` | ✅ 已清零（arch-hardening ②，2026-10-16） |
| 5 | `mcp/sandbox → llm` 反向依赖 | `mcp/sampling.dart`（`SamplingEngine` 端口）/ `core/chat_message_data.dart` + `llm/cloud/chat_message_codec.dart` | ✅ 已清零（arch-hardening ③/④，2026-10-16） |
| 6 | `ui ↔ gateway` 跨域环 | 弹层迁 `ui/gateway_consent_dialog.dart` | ✅ 已清零（arch-hardening ①，2026-10-16；gateway→ui 断环，ui→gateway 属窗口→窗口允许方向） |
| 7 | ~~`GatewayController.shared` 全局单例持会话态~~（阶段二 D-D 已落地） | `gateway/gateway_controller.dart` / `gateway/gateway_server.dart` | ✅ 已收口（2026-10-16 #7 接手）：① 阶段二 per-connection 投影隔离（`_handlers[sessionId]` + `forSession()` + `gateway__select_private` + 防火墙）已测（`gateway_per_session_projection_test.dart`）；② shared 单例 `_activePrivateServerId` 澄清为 **host-level 默认投影源**（重命名 `_hostDefaultPrivateServerId` + 注释，per-session 态已隔离在 server 层）；③ POST-only 连接投影上下文泄漏修复（`idleTimeout` + `_gcIdle` + `_lastActivity`）；`workspaceId` 接线见 #11 |
| 8 | 会话态手工枚举（新增字段要改声明/reset/落盘 3 处，漏改即静默 bug） | `coordinator/mcp_runtime.dart`（ConversationSession） | ✅ 已清零（步 0/3，2026-10-16） |
| 9 | 装配级 / chat_page 级测试基线缺失 | `test/coordinator/mcp_runtime_test.dart` 等 | ✅ 已清零（步 0/1 契约与装配测试，2026-10-16） |
| 10 | ~~`memory_kernel_test` 2 例全仓并发失败（单跑 5/5、coordinator 目录 286 并发均过；全仓 706 并发时 wsStates 混入他测试键值 `dark`/`ui.lang`）~~ | ~~`test/coordinator/memory_kernel_test.dart`~~ | ✅ 已清零（2026-10-16 arch-hardening 断点移交项）：根因 = 固定 100ms 猜等写链排空，全量并发 CPU 饱和即 flaky；修法 = `SequentialFileWriter.settled` + `MemoryStore/WorkspaceStateStore.ioDrained` 确定性握手（`memory_governor_test` 同族一并修），706/706 全绿 |
| 11 | 投影平面 `workspaceId` 接线（D-D 投影平面三元 `{activePrivateServerId, publicServerIds, workspaceId}` 缺 `workspaceId`） | `gateway/*`（ProjectionContext） | 待接：PC 连接不携带 workspaceId，记忆分区归属 chatmessage 域 per-conversation（`workspace_states`）；网关侧接线待 chatmessage 记忆分区工作，#7 本轮不接 |
| 12 | **UI 侧 `dart:io` 存量违规清零**（`update_page.dart` 持 `File? _apk` / `error_copy.dart` 为识别 SocketException·HttpException 而 import dart:io） | `lib/ui/update_page.dart`（改持路径 `String`）+ `lib/ui/error_copy.dart`（判定下沉 `core/errors/transport_error_kind.dart`，UI 只消费 `TransportErrorKind` 枚举） | ✅ 已清零（2026-10-17 P0-C）：新依赖护栏立起后 arch-guard R1 实测命中 2 处，不清零会挡住所有提交；**处置=修而非加白名单**（白名单纪律只减不增）。R1 白名单仍为原 3 项（`services_hall_page`/`chat_page`/`memory_board_page`） |
| 14 | **GatewayController 无装配注入位**（`localPluginDiscovery` / `serverEndpointStore` 为顶层全局直接引用）→ 重扫释放与起服失败回滚两条路径**无单测覆盖**，只能真机验收 | `lib/gateway/gateway_controller.dart` | 待接（2026-10-17 P0-B 登记）：释放接线已落地（`_mounted` 句柄表 + `_unmountAll` + 重扫/停服/起服失败三路回滚，`McpMount.close` 为唯一释放通道），但断言只到挂载原语层（见 `test/gateway/gateway_session_isolation_test.dart` 用例 5~7）。收敛条件=给 controller 加 `localPluginDiscovery` / `serverEndpointStore` 注入位后补网关级重扫与回滚断言；真机冒烟=插件安装触发重扫、停服后无残留连接 |
| 13 | **CI 缺口**：无 `.github/` 无 `.gitlab-ci.yml`，`flutter test` 从无自动化触发入口 | 仓库根（待建 workflow）；现状兜底 = `scripts/agent-tools/pre-commit-gate.sh` | 待接（2026-10-17 P0-C 登记）：现状=pre-commit 默认跑秒级 `arch-guard`（R1~R8，含依赖方向 6 条中的域级 5 条 + URI 级 1 条），`flutter test` 版经 `ARCH_GATE_FULL=1` 显式开关跑 `arch-deps.sh`（单次 ~12s 超钩子 10s 预算故不进默认路径）。**收敛条件**：建 CI workflow 固定跑 `flutter analyze` + `flutter test --timeout 180s` + `arch-guard.sh --json`；存量教训=conversation_drawer_test 隔夜腐化（fixture 写死绝对日期）长期未暴露，根因正是从不跑测试 |

## 命令速查

见 `goodhub-workflow` skill（本仓 `.agents/skills/goodhub-workflow/SKILL.md`）。
