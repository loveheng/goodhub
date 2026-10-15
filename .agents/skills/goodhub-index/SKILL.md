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
| 多服务配置面（多端点 JSON + apiKey 安全存储 + 旧键迁移 + enabled 挂载位） | `lib/mcp/server_endpoints.dart`（`ServerEndpointStore`） | M4-T6-1；M4-T5 增 `enabled`（节点卡卸载开关，_send 装配过滤）；ChatPage ⚙ 设置面板（`_openSettings` 服务列表增删改）为其薄壳；单测 `test/mcp/server_endpoints_test.dart` |
| 节点探活（握手+工具计数计时 / 401/403 鉴权态与离线区分） | `lib/mcp/server_probe.dart`（`ServerProber`/`NodeProbeResult`） | M4-T5；`McpClientFactory` 注入位；探活一次性建 client 用完即弃；单测 `test/mcp/server_probe_test.dart` |
| Server 节点卡面板（端口/延迟/在线点/工具计数/鉴权态/挂载开关） | `lib/ui/services_hall_page.dart`（`_nodesPanel` 段） | M4-T5；增删改编辑面归 ChatPage ⚙（同 `mcp_servers.json`）；探活按需不自动网络化；注入位 `endpointStoreOverride`/`probeOverride`；单测 `test/ui/server_nodes_panel_test.dart` |
| 本地插件面板（Binder 发现项渲染 / 信任态 pill / 信任卡片入口；零配置自动挂载，不落用户 JSON） | `lib/ui/services_hall_page.dart`（`_localPluginsPanel` 段） | 2026-10-15 新增（补齐真缺口）；注入位 `localScanOverride`/`localChangesOverride`；单测 `test/ui/local_plugins_panel_test.dart` |
| 服务大厅（Skill 覆写管理 / BYOK 云端引擎面板 / 跨源授权口径） | `lib/ui/services_hall_page.dart` | M3-T4 建 + M4-T5 增 BYOK 面板（多 profile 增删改 + 置顶切换生效，首位=生效对齐 hybrid_assembly；apiKey 走 SecureKeyValue）；单测 `test/ui/byok_panel_test.dart` |
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

## 命令速查

见 `goodhub-workflow` skill（本仓 `.agents/skills/goodhub-workflow/SKILL.md`）。
