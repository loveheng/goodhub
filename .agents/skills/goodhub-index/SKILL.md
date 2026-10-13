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
| 双轨消息流组件（TrackEntry/渲染映射） | `lib/ui/components/dual_track_stream.dart` | M4-T3；卡片全量复用 M2/M3；T3b 恢复装配复用 |
| Markdown 子集解析器（goodshare 随迁） | `lib/doc/rich_text.dart` | M4-T3/D12 随迁（零依赖原样，随迁注记见文件头；双仓分叉风险已记） |
| 阅读轨只读渲染器（console tokens 对齐） | `lib/ui/rich_text_view.dart` | M4-T3/D12；媒体块降级不吞内容；todo 只读字形 |
| 记忆沙盒（三件套/FC1 锚点/scope 三层作用域/预算视图/审计/轮转） | `lib/sandbox/memory_store.dart` | M4-T1/T2；拍板 D4~D8 见 docs/design/m4.md §4；`underSupportDir` 生产装配 + 启动清扫挂 main |
| 记忆读写内部工具面（update_memory/query_memory） | `lib/coordinator/memory_tool_executor.dart` | M4-T2；挂 Gateway 内侧（L2 裁决先于执行）；§7.1 描述引导 + §7.3 快照回显；审计三点合围见 m4.md T2 注记 |
| 会话历史持久化（每会话一 JSON/原子重写） | `lib/sandbox/conversation_store.dart` | M4-T3b；CloudChatMessage 编解码在此，TrackEntry 编解码在 UI 层（dual_track_stream 静态）；恢复降级语义见 m4.md T3b 注记 |
| 串行文件写队列（temp+rename 原子替换） | `lib/core/storage/sequential_file_writer.dart` | M4-T1；coding-standards §5.1 基准件（续链与透传分离修正） |
| 多服务配置面（多端点 JSON + apiKey 安全存储 + 旧键迁移 + enabled 挂载位） | `lib/mcp/server_endpoints.dart`（`ServerEndpointStore`） | M4-T6-1；M4-T5 增 `enabled`（节点卡卸载开关，_send 装配过滤）；ChatPage ⚙ 设置面板（`_openSettings` 服务列表增删改）为其薄壳；单测 `test/mcp/server_endpoints_test.dart` |
| 节点探活（握手+工具计数计时 / 401/403 鉴权态与离线区分） | `lib/mcp/server_probe.dart`（`ServerProber`/`NodeProbeResult`） | M4-T5；`McpClientFactory` 注入位；探活一次性建 client 用完即弃；单测 `test/mcp/server_probe_test.dart` |
| Server 节点卡面板（端口/延迟/在线点/工具计数/鉴权态/挂载开关） | `lib/ui/services_hall_page.dart`（`_nodesPanel` 段） | M4-T5；增删改编辑面归 ChatPage ⚙（同 `mcp_servers.json`）；探活按需不自动网络化；注入位 `endpointStoreOverride`/`probeOverride`；单测 `test/ui/server_nodes_panel_test.dart` |
| 服务大厅（Skill 覆写管理 / BYOK 云端引擎面板 / 跨源授权口径） | `lib/ui/services_hall_page.dart` | M3-T4 建 + M4-T5 增 BYOK 面板（多 profile 增删改 + 置顶切换生效，首位=生效对齐 hybrid_assembly；apiKey 走 SecureKeyValue）；单测 `test/ui/byok_panel_test.dart` |
| 记忆看板（三 Tab 查看/编辑/导出/粉碎 + ops.log 人类可读渲染） | `lib/ui/memory_board_page.dart` | M4-T5；store 编辑面 `updateEntry/deleteEntry/purgeUserScope/listOpsLog/exportAll`（memory_store.dart）；ChatPage 侧边栏入口；单测 `test/ui/memory_board_page_test.dart` + `test/sandbox/memory_board_store_test.dart` |
| token 字符级粗估口径 SSOT | `lib/core/tokens.dart` | M4-T1 自 context_governor 下沉（层级纪律），governor 原位 re-export |

## 文档落点

| 主题 | 落点 | 状态 |
|---|---|---|
| MCP 接缝契约（SSOT） | goodshare 仓 `docs/design/ai-app-split.md` | active（跨仓只读引用） |
| 宿主自身产品设计（聊天/决策卡片/共享区） | 本仓 docs/（M3+ 时建） | 未建 |
| UI 设计规范（控制台风格 SSOT） | 本仓 `docs/product/ui-design.md`；落点纪律见 `.agents/skills/goodhub-ui/SKILL.md` | active |
| 工程编码基准（编码规范 SSOT，含 MCP 对 AI 接口契约 §7） | 本仓 `docs/project/coding-standards.md` | active |
| 端侧 LLM 设计（LiteRT-LM / FoundationModels） | 本仓 `docs/design/on-device-llm.md` | active（M2 已随迁） |

## 命令速查

见 `goodhub-workflow` skill（本仓 `.agents/skills/goodhub-workflow/SKILL.md`）。
