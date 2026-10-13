---
dev-loop: memory
format: v1
epic: m4
total-merged: 1
last-merge: 2026-10-11
---

# m4

- [挂载] docs/design/m4.md（内容 SSOT：范围 / T1~T5+T3b 分解 / D1~D12 拍板 / 各任务实现注记）；交互 SSOT = docs/product/chat-interaction.md（T3 立）
- [立项] 2026-10-11 自 M3 收官移交，范围提炼自同日全仓文档↔实现对账。拍板：D1 五项全做 / D2 记忆沙盒先行 / D3 §16 门槛维持推迟；D4~D7 记忆层方案（lib/sandbox/、lessons 同 FC1 锚点、截断保底留最新、ops.log JSONL）；D8 记忆三层作用域（user 全局 / srv 绑定卸载即清 / 数据快照不进记忆走 Resource+订阅）；D9~D11（聊天页接管首页 / 历史落盘可恢复→拆 T3b / 同页多轮上下文共享）；D12 Markdown = goodshare 自写 parser 随迁 + 宿主渲染器（弃三方包）——详见挂载文档 §4
- [结论] **T1 ✓ 记忆沙盒内核**：MemoryStore 三件套（FC1 锚点+scope / 预算截断丢最旧+保底留最新 / ops.log JSONL 10MB 单代轮转 / 启动清扫）+ SequentialFileWriter（coding-standards §5.1 基准件，续链与错误透传分离修正草案队列死锁缺陷）+ estimateTokens 下沉 core/tokens（governor 原位 re-export 零破坏）
- [结论] **T2 ✓ 记忆接入运行时**：MemoryToolExecutor（update_memory/query_memory——Gateway 内侧 L2 裁决先于执行、§7.1 描述引导禁记快照、§7.3 快照回显）+ 审计三点合围（McpToolFace remote / 记忆·技能工具 local，isError 截 200，DEGRADE 不阻断）+ memoryPromptSection 注入（D8 作用域 + 超限 query_memory 注记）+ main 启动清扫
- [结论] **T3 ✓ 双轨消息流正式 UI**：ChatPage 首页接管（连接配置 SharedPreferences 过渡态）+ DualTrackStream 公共组件（TrackEntry 七类 sealed，卡片全量复用 M2/M3）+ RichTextView（D12 随迁 parser + 宿主只读渲染器，媒体块降级不吞内容）+ AgentLoop D11 多轮上下文（history 入参 / transcript 回传 / _sessionTranscript 未配对尾巴协议安全截断）；ClaimLoopPage/GrammarSpikePage 拆独立文件，main 收敛纯装配；tokens 补 codeBg/dataRef
- [验证基线] flutter analyze 0 issue / 317 测试全绿（2026-10-11 T3 收官）；真机链路（记忆注入→L2 卡→ops.log、聊天页全链、Abort 半程明示）随 T5 真机联调第三批
- [待办指针] T3b（D10 拆分）→ T4 连接韧性+订阅消费（并行线）→ T5 大厅余项+收官；全局遗留见 context/todos.md（§16 门槛三案、拦截卡三态真机验证等）
- [结论] **T6 核心接线（JIT+装配）✓ 2026-10-12**：DiscoveryExecutor（get_connected_apps/activate_server_tools，执行链最外层 L1）+ AgentLoop.toolsProvider（每轮重算 tools）+ ChatPage._send 多连接池（ServerEndpointStore.load 多端点→多 McpClient+McpToolFace→ToolRouter，默认激活全部，resolver 接 router.serverFor，静态摘要「## 已挂载服务」节）+ 配置读写切 ServerEndpointStore（迁移旧 chat.mcp.*）；analyze 0 issue / discovery_executor_test 14 例全绿。T6 剩余：服务管理 UI（增删改列表）/ CoW 多 server 真机 / T6-4 真机联调（goodshare 经 ToolRouter 不回归 + 第二真实服务随用户接入）/ 已激活 Schema 1200T 精简模式（待拍板）

## 断点
- [断点] T5-BYOK 面板已落（2026-10-13）：服务大厅面板二「BYOK 云端引擎」多 profile 增删改 + 置顶切换生效（首位=生效，装配线零改动对齐 hybrid_assembly）+ apiKey 走 SecureKeyValue（编辑留空保持已存）；byok_panel_test 5 例全绿 / 370 全绿 / analyze 无新增。**下一步**：记忆看板（MemoryStore/ops.log 数据源就绪）→ Server 节点卡 → T5 收官（双仓全量验证 + 真机联调第三批：BYOK 面板真机配置→云端链路全通，兼收 thirdconnect reverseDemo 挂起）；T6 剩余 ②③④（CoW 多 server 真机 / T6-4 真机联调 / 1200T 精简模式待拍板）攒真机批或穿插
