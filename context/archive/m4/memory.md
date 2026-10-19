---
dev-loop: memory
format: v1
epic: m4
total-merged: 2
last-merge: 2026-10-14
---

# m4

- [挂载] docs/design/m4.md（内容 SSOT：范围 / T1~T5+T3b 分解 / D1~D12 拍板 / 各任务实现注记）；交互 SSOT = docs/product/chat-interaction.md（T3 立）
- [立项] 2026-10-11 自 M3 收官移交，范围提炼自同日全仓文档↔实现对账。拍板：D1 五项全做 / D2 记忆沙盒先行 / D3 §16 门槛维持推迟；D4~D7 记忆层方案（lib/sandbox/、lessons 同 FC1 锚点、截断保底留最新、ops.log JSONL）；D8 记忆三层作用域（user 全局 / srv 绑定卸载即清 / 数据快照不进记忆走 Resource+订阅）；D9~D11（聊天页接管首页 / 历史落盘可恢复→拆 T3b / 同页多轮上下文共享）；D12 Markdown = goodshare 自写 parser 随迁 + 宿主渲染器（弃三方包）——详见挂载文档 §4
- [结论] **T1 ✓ 记忆沙盒内核**：MemoryStore 三件套（FC1 锚点+scope / 预算截断丢最旧+保底留最新 / ops.log JSONL 10MB 单代轮转 / 启动清扫）+ SequentialFileWriter（coding-standards §5.1 基准件，续链与错误透传分离修正草案队列死锁缺陷）+ estimateTokens 下沉 core/tokens（governor 原位 re-export 零破坏）
- [结论] **T2 ✓ 记忆接入运行时**：MemoryToolExecutor（update_memory/query_memory——Gateway 内侧 L2 裁决先于执行、§7.1 描述引导禁记快照、§7.3 快照回显）+ 审计三点合围（McpToolFace remote / 记忆·技能工具 local，isError 截 200，DEGRADE 不阻断）+ memoryPromptSection 注入（D8 作用域 + 超限 query_memory 注记）+ main 启动清扫
- [结论] **T3 ✓ 双轨消息流正式 UI**：ChatPage 首页接管（连接配置 SharedPreferences 过渡态）+ DualTrackStream 公共组件（TrackEntry 七类 sealed，卡片全量复用 M2/M3）+ RichTextView（D12 随迁 parser + 宿主只读渲染器，媒体块降级不吞内容）+ AgentLoop D11 多轮上下文（history 入参 / transcript 回传 / _sessionTranscript 未配对尾巴协议安全截断）；ClaimLoopPage/GrammarSpikePage 拆独立文件，main 收敛纯装配；tokens 补 codeBg/dataRef
- [验证基线] flutter analyze 0 issue / 317 测试全绿（2026-10-11 T3 收官）；真机链路（记忆注入→L2 卡→ops.log、聊天页全链、Abort 半程明示）随 T5 真机联调第三批
- [待办指针] T3b（D10 拆分）→ T4 连接韧性+订阅消费（并行线）→ T5 大厅余项+收官；全局遗留见 context/todos.md（§16 门槛三案、拦截卡三态真机验证等）
- [结论] **T6 核心接线（JIT+装配）✓ 2026-10-12**：DiscoveryExecutor（get_connected_apps/activate_server_tools，执行链最外层 L1）+ AgentLoop.toolsProvider（每轮重算 tools）+ ChatPage._send 多连接池（ServerEndpointStore.load 多端点→多 McpClient+McpToolFace→ToolRouter，默认激活全部，resolver 接 router.serverFor，静态摘要「## 已挂载服务」节）+ 配置读写切 ServerEndpointStore（迁移旧 chat.mcp.*）；analyze 0 issue / discovery_executor_test 14 例全绿
- [结论] **T5 节点卡 + 同签名信任链 ✓（2026-10-13~14 归并）**：`ServerEndpoint.enabled` 挂载位 + `lib/mcp/server_probe.dart`（401/403→待授权 Rose 与离线区分）+ services_hall 节点卡面板替换占位 + ChatPage._send 过滤卸载节点；AndroidManifest 增 `MCP_SERVER` 权限请求（B2）；#9 签名对齐达成协议（双方 release 均复用 debug signing，对称无错配；正式 release 共享证书=出包前置不阻塞）；§5 门禁落机械测试（manifest gate 3 例 + signature 解析 4 例）+ `check-same-signature.sh`（keytool→apksigner 修正，入池 alias sig-check），真机 D.1/D.2 通过 → **#9 可关，#10 解锁**
- [结论] **T6-3 扩展 + 真机第三批 ✓（2026-10-14 归并）**：JIT 聚焦元工具 `use_server(server_id)`（独占单服务 + 聚焦幂等 + all 恢复 + 独占守卫，测试 +8 → 全量 413 绿）；T6-4 e2e integration test 6 断言全绿（前缀路由/JIT 元工具/未激活幻觉防线）；BYOK 云端全通（StepFun step-3.7-flash，chat+tool_calls 双探针）；节点卡探活数据面双态过（带 key 38 工具 / 无 key 401）；CoW 多 server 撞名跳过坐证（**发现：撞名静默跳过无用户面通告，与 m4.md「通告」有差，待拍板**）。文档：新增 `docs/design/local-plugin-access-trust.md`（§1~§9 完整）+ thirdconnect §1.2.6 反向指针 + m4.md T5/T6 回填
- [待办指针] T6 剩余：服务管理 UI（增删改列表）/ loadCatalog 聚焦切换刷新面 / 已激活 Schema 精简模式（待拍板）；真机批剩 reverseDemo（暂缓）+ 三处设备端 UI 冒烟（交用户）；Markdown parser 已抽同级共享包 `/home/zzh/app/rich_text/` 并 DIP 拆两 library（`rich_text.dart` 抽象：AST+RichTextParser+纯运算；`markdown_subset.dart` 实现：parser+helper，export 抽象）；goodhub 渲染器改吃 `List<RichBlock>`、parse 移调用点 → 只依赖抽象（全量 409 绿）。goodshare adopt（同拆 + 渲染器吃 AST + parse 移调用点）+ 上 git 宿主待协同

## T4 连接韧性（2026-10-15 重启，SA-Q2 文档收口后）

- [结论] 施工分解：**T4-1 退避底座（✓ 已落）** → T4-2 心跳探活 → T4-3 指数退避重连 → T4-4 积压丢弃回告 → T4-5 `resources/subscribe` 全链与失效感知。切分依据：T4-2~4 是纯客户端能力（不依赖 goodshare 新能力），T4-5 依赖对方真发 `notifications/resources/updated`（未核实前先做易成空中楼阁）
- [结论] T4-1 落点与纪律：`lib/core/network/backoff.dart` 只放**纯算法**（指数退避 + jitter + 重试额度 + 最坏累计），按 coding-standards §1.2 边界纪律——「什么时候重连、重连后怎么重建」的总线策略必须住 `lib/mcp/`（T4-2/3），不得下沉 core
- [结论] 现状取证（2026-10-15）：`mcp_client` 已有 `listResources`/`readResource`（只读数据面），但**无 `resources/subscribe` 方法、无 `notifications/resources/updated` 收侧**；`server_capabilities.hasSubscriptions` 仅 gate；`server_probe` 是用户触发的一次性探活，非周期心跳
- [待办] D15~D20 拍板（见 `context/pending-confirm.md`）：顺序切分 / 心跳参数（推荐 15s-5s-2 次）/ 重连后保留激活集 / 断连终态 `Cancelled` 且 TrackNote 回告 / 失效感知不自动重读 / goodshare 契约回写归跨仓由用户执行

## 断点
- [断点] 下一步：T4 连接韧性全链（T4-1~T4-5 + 收官接线）已落地、全量 529 全绿，待真机验收；D20 goodshare 契约回写归用户跨仓执行；剩余 = reverseDemo（暂缓）+ 三处设备端 UI 冒烟（交用户）

## 归并（2026-10-19 · T4 连接韧性全链，自 devlog 11 条提炼）

- **T4-1 退避底座**：`lib/core/network/backoff.dart`（指数退避 + 抖动 + 重试额度 + 最坏累计等待，纯函数可注入随机源）+ `test/core/network/backoff_test.dart` 8 例。纪律：core 只放纯算法，「何时重连 / 重连后怎么重建」的总线策略必须住 `lib/mcp/`（coding-standards §1.2 边界）。
- **T4-2 心跳探活 + 状态机**：`lib/mcp/connection_health.dart`（ConnectionHealth + ConnectionState{unknown,online,degraded,offline}；**D16 门控** `pollable()` = `transport is HttpTransport`——Binder 连接 `start()` no-op 不建定时器，避免唤醒休眠子进程成电量刺客）；`McpClient.ping()`（MCP 2025-06-18 标准 ping）。单测 6 例（FakeAsync 驱动定时器/超时/幂等/作用域隔离）。
- **T4-3 退避重连**：`lib/mcp/connection_manager.dart`（McpConnection 组合 T4-1 退避 + T4-2 心跳 + McpToolFace；offline→online 自动 reconnect = 重 negotiate + 重 listTools + **D17 差分清洗**（新 listTools 与原 JIT 激活集交集，下线工具剔除并 DEGRADE 留痕 + onActivationChanged）；转 offline 触发 **D18** 断连处置：`face.cancelActiveRequest()` + `onDisconnectReport(在途 N 个已取消)`）；`McpClient.resetNegotiation()`（重连强制重握手）；`McpToolFace.inFlightCount` + cancelActiveRequest 支持多并发在途取消。**作用域隔离（D16）**：仅 HTTP 自动重连，Binder 由 DeathRecipient 显式 handleHealthState。单测 8 例。
- **T4-4 积压丢弃回告**（同文件，与 T4-3 同体）：architecture §1「网络切换积压队列整体丢弃并回告、不重放（写操作重放有副作用风险）」模型落地——McpConnection 增**离线窗口门** `guardExecute(run)`（离线=整体丢弃 + 计 droppedBacklog + 返回 canonical isError `backlogDroppedMessage`；在线=透传）；恢复成功（offline→online 且 reconnect success）经 `onBacklogReport(BacklogReport(droppedCount))` 回告积压总数并清零；重连失败不回告、积压跨断连窗口累计保留。BacklogReport 与 DisconnectReport 并列（两类独立回告：在途=已发被取消 / 积压=未发直接丢弃）。**边界纪律**：guardExecute 签名刻意不引入 `AssembledToolCall`（定义在 `lib/llm/cloud/cloud_llm.dart` 重型 LLM 层），免 mcp 层反向依赖 LLM 层；`ToolExecutionResult` 经 `agent_loop.dart` 取（与 McpToolFace 同源）。单测 5 例（文件共 13 例）。
- **T4-5 订阅消费（客户端侧）**：`lib/mcp/mcp_client.dart` 增 subscribeResource/unsubscribeResource（capabilities gate `ServerCapabilities.hasSubscriptions` 抛协议违规 / 幂等去重 / `force:true` 重放）+ `_subscribedUris` 跟踪 + `subscribedUris` 只读视图 + `onResourceUpdated` 回调 + 统一 `handleServerNotification(method,params)` 分发器（当前仅消费 `notifications/resources/updated`，其余忽略），并接入 `callWithProgress` 的 POST-SSE 流解析（其余 server 主动通知帧原静默忽略 → 现经分发器路由，GET 长连接监听将复用同一分发器）；connection_manager 构造期转发 onResourceUpdated（D19）+ subscribe/unsubscribe 委托 + 重连 `_resyncSubscriptions()`（server 重启清空订阅后按本地集合 force 重发，失败仅 DEGRADE 留痕）+ `resourceStaleMessage` canonical D19 文案「⚠ 数据已变更，如需最新请重新读取（不自动重读）」。**边界纪律**：订阅请求/分发住 `lib/mcp/`（协议层），未碰 `core/network` 纯算法。单测 8 例。
- **T4 收官（应用接线 + GET 监听全链）**：transport 抽象增 `getStream()`（GET /mcp SSE 长连接）；HttpTransport.getStream() 实现（Accept: text/event-stream，非 2xx 抛 McpNetworkException），原有 POST 路径经统一 `_sendRaw`；BinderTransport.getStream() 抛 UnsupportedError（本地通知走 EventChannel，退化不监听）。McpClient 增 GET SSE 订阅监听循环 startNotificationListener/stopNotificationListener（断流/崩溃指数退避重连不惊群，仅 hasSubscriptions 有效，UnsupportedError 静默退出）；readResource 读后 best-effort 自动订阅该 uri 并启动监听（D8/D19：实时读+失效感知闭环，失败静默）。McpConnection：subscribe 后 unawaited(startNotificationListener)；断连 _onDisconnected 停监听；重连 _resyncSubscriptions 重放订阅后起重监听。chat_page 收官接线：每 server 建 McpConnection 并 start()（心跳/重连接管）；onDisconnectReport/onBacklogReport/onResourceUpdated → 操作轨 TrackNote（D18/D19 canonical 文案，资源变更含 uri，D19 不自动重读）；新增 `_GuardedExecutor` 将 server 工具调用按 server 路由到 guardExecute（离线窗口整体丢弃、不重放），JIT/本地工具透传；finally 停连接无泄漏。单测扩至 11 例（含 GET SSE 监听分发+可停 / readResource 读后订阅+监听+推送帧分发 / HttpTransport.getStream SSE 流），另为 5 个测试假传输补 getStream 桩。
- **验证基线**：全量 **529 全绿**、analyze 0 新增（T4 各阶段 513→518→526→529）。**D20 goodshare 契约回写为跨仓动作**（goodshare 仓 `docs/design/ai-app-split.md` §3.10 回写 goodhub 已消费 GET SSE 订阅通道），由用户在 goodshare 仓执行。**T4 全量完成，待真机验收。**
