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

## 断点
- [断点] CoW 撞名 ✓（2026-10-14，仅 goodshare）：goodshare 双 serverId（goodshare + goodshare-lan）自撞名坐证——Tier1 prompts [item_digest/weekly_review/suggest_tags]，server1 注册 3 cow/，server2 同名 3 跳过。发现撞名静默跳过无用户面通告（设计含「通告」）→ **通告侧已于 2026-10-14 补上**（chat_page 撞名发 TrackNote「已采用 <serverId> 版本，跳过 <serverId>」，danger:false）。**联调第三批 P1~P3 全部验证通过**，仅剩 reverseDemo（暂缓）+ 三处设备端 UI 冒烟（交用户）
