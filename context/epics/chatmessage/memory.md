---
dev-loop: memory
format: v1
epic: chatmessage
total-merged: 2
last-merge: 2026-10-16
---

# chatmessage

- [挂载] docs/design/host-gateway-accessibility-memory.md（2026-10-15 一轮架构推演，含访问性模型 / Host 网关 / 记忆 In-band 捎带提取三段结论）

## 设计 SSOT 速览（TL;DR）

- **§1 访问性 / 隐私分层**：外部 MCP 服务仅 `private` / `public` 两档；`host`（宿主内置能力）**不进 `ServerEndpoint`**，由客户端以 `HostNativeTools` 注入。两维解耦 = Provider（host / external）× Tier（private / public）。
- **§2 Host = 聚合反向代理网关**：goodhub 既是对下子服务的客户端，又是对上的标准 MCP 服务端代理；四项治理（命名空间虚拟化 / 工具面虚拟化 / 调用拦截 / 遥测脱敏）收口在网关层（`GatewayController` + `GatewayHandler` 已是实体）。
- **§3 记忆 = In-band 捎带提取**：模型最终自然语言轮尾部用 `<workspace_update>` 标签捎带提取背景事实，省掉二次模型调用；现有 `MemoryStore` / `context_governor` / `agent_loop` 已覆盖约 80% 基础设施，真实缺口集中在 Demuxer 与会话级 store。

## 关键决策（锁定）

- D-A：外部服务仅 `private`/`public` 两档；`host` 不进 `ServerEndpoint`（Provider×Tier 两维解耦）。
- D-B：goodshare 迁移为普通外部 `ServerEndpoint`，`tier: public`；宿主能力另抽 `HostNativeTools`。
- D-C：私有 + 私有严禁由 `activePrivateServerId` 单一槽位构造保证。
- D-D：Host = 「连接平面全局 / 投影平面按工作区隔离」（`GatewayController.shared` 单例与投影态会话级矛盾待实现）。
- D-E：记忆走 In-band 捎带提取，非异步小模型。
- D-F：会话级事实 store 须新建（G3）——现有 `MemoryStore` 仅 app 全局级，无 per-conversation 层。
- D-G：Prompt Caching 以显式断点 + 工具序确定性为第一杠杆，记忆置尾策略维持。
- D-H：切换私有域做历史投影时绝不物理删除 `tool_call`/`tool_result`，保留 matching `id` 替换为合成占位桩（防 OpenAI/Anthropic 400）。详见 §9.1。
- D-I：超大工具输出在 `_governedContent` 入口前置物理硬截断 `kToolResultHardCap = 2000 tokens (≈8KB)`，Head 50 + Tail 20 折叠。详见 §10.4。
- D-J：单轮多 `tool_calls` 改 `Future.wait` 并发编排；任一失败须包装为合法错误 `ToolResult` 全量回填。详见 §10.2。
- D-K：剪枝与负收益消除——仅留断点 A（砍断点 B 消除 re-cache 惩罚）；砍 `is_locked` 行级锁；Gemini 保持无状态；当前阶段不引入 MCP Resources/Prompts。详见 §7.5 / §9.5 / §9.4 / §10.3。

## 真实缺口（待落地，§3.5）

- **G1** 语义 key 映射：`MemoryStore` 无 keyed upsert/remove，需按 key 查重或新建轻量 KV 子 store。
- **G2** Demuxer / FSM 未写：新建 `WorkspaceStreamFilter`，挂 `agent_loop.dart:265`（分流）+ `calls.isEmpty` 分支（终局剥离）。
- **G3** 会话级（workspace）store 缺失：最大缺口，落点 = 未落地的 `workspace_states` 表。
- **G4** scope 校验 + 「public」映射：扩展 `_scopeRegExp` 含 `session`/`ws:`，JSON 的 `"public"` 映射为「本会话域」。
- **G5** 工具 Schema 键序归一（P0 缓存杀手）：`CloudToolSchema` 缺规范 `toJson` 且 `parametersSchema` 键序不可控，须 Dart 层递归字典序排序。详见 §8.2 改动点 3。
- **G6** FSM 生命周期与取消回滚（P0 数据安全）：用户 Stop / 断网时 `pendingBuffer`/`jsonBuffer` 残留致脏解析，须 `_aborted` 挂 `fsm.discard()`。详见 §9.2。
- **G7** 输入端特异性标签转义（P1 防注入）：用户输入 `<workspace_update` 转义为 `&lt;workspace_update`；输出升级 `<workspace_update_v1>`。详见 §9.3。
- **G8** 移动端前后台生命周期探针（P1 稳定性）：缺 `WidgetsBindingObserver`；`resumed` 须 ping 探针 + 失效静默重连。详见 §10.1。

## 收尾账本 (2026-10-15)

- 全量测试 **583/583 全绿**（含此前编译失败的 `hybrid_cloud_engine_test` 21 例已修复入网）；`flutter analyze` 基线 = 1 条已知存量 info（`gateway_loop_debug_page.dart:670 value deprecated`，`release-r2.sh` 已降为告警不阻断）。
- 阻断修复（devlog → 此处收口）：
  - `lib/coordinator/hybrid_cloud_engine.dart`：`_cloudSend` 内 `fireTimeout` 闭包在 `late final srcSub` 声明前引用 → 编译回归（连带 `debug_hall_test`/`gateway_controller_test`/`hybrid_cloud_engine_test` 编译失败）；`srcSub` 声明前置解决。
  - `lib/mcp/connection_manager.dart`：`_resyncSubscriptions` 重连重放原走 `listResources()` 重列，server 重启后缺 `resources` 数组抛错且清单未必含手动订阅 uri → 重放中断（`subscription_test` 实际 1/期望 2）；改为先按本地 `client.subscribedUris` 重报（force）+ best-effort 重列补新增。
  - `lib/coordinator/hybrid_cloud_engine.dart`：`_cloudSend` gapTimer 三元 `isFirst ? firstTokenTimeout : interEventGapTimeout` 首事件后误重装首 token 预算（interEventGapTimeout 判据永不触发）；改为事件到达后一律按 `interEventGapTimeout` 重装并删废变量 `isFirst`；`hybrid_cloud_engine_test` `CloudDone` 缺必填 `finishReason` 编译失败补 `CloudFinishReason.stop`。

## 归并 (2026-10-16 · 会话绑定 UI 与流控判据)

- **会话绑定 UI 定稿**：状态带上下文胶囊改**常驻可点**（已绑定→`[服务名]`；有端点→`[公共]`；本地插件→`本地×N`），输入框「+」**固定常显不隐藏**（移除 `_composerVisible` 及输入监听）——解决"输入一半想切服务"的痛点，输入内容不丢。
- **本地插件语义（易错点）**：Binder 自动发现项**不进 `mcp_servers.json`**，经 `localPluginDiscovery.scan()` 填 `_localPlugins`；**按私有呈现**（锁形 + `l1Info` 色，非公有灰），**始终挂载**、无需绑定选择——绑定语义仅适用于手填 HTTP 端点。
- **`_endpoints` 缓存过时缺陷**：`ChatPage` 原只在 `initState` 读一次目录，"先开聊天→设置加服务→返回"后菜单恒空。修法 = `_openComposerMenu` 开菜单前先 `await _loadEndpoints()` 重读；且加载后即完成"新会话默认锁定"（`isDefault` → 首个 private）。
- **流控判据放宽（D-K 连带）**：`DegradationController` 移除 `maxThinkingGap` 上限——长思考/慢推理不掐断，交由人类按状态带新增的 `mm:ss` 运行计时自行决定中止；活体连接（含 SSE 心跳字节）永不误杀，仅持续无字节的真死连接被 `interEventGapTimeout`=120s 下限兜底。
- **验证基线**：`flutter analyze` No issues；全量 564/0（该轮排除 hybrid_cloud_engine_test），后随编译修复入网升至 583/583（见上节收尾账本）。

## 断点

- [断点] 下一步：2026-10-19 归并批（归因条/胶囊禁令修复/悬浮入口/默会提取协议/阶梯截断/记忆 journal 与 governor）已落地且 706 全绿；等待新子任务或 ::done；真机端到端（多轮胶囊/覆写同 key/undo 识别）待用户
- [note] 2026-10-16：本 epic 的 UI/装配层解耦已**分拆**至新 epic `window-kernel-split`（挂 `docs/design/window-kernel-split.md`），本 epic 仅保留 §3 记忆 In-band 提取战场；两边连线 = 依赖跟踪 §2.4 投影平面隔离

## 归并（2026-10-19 · 记忆提取与上下文治理一批，自 devlog 18 条提炼）

- **上下文归因展示条（展示 only）**：新增 `TrackContextAttribution`（lib/ui/components/dual_track_stream.dart）——收起态等宽遥测 pill（数据指针色 dataRef + hairline 边框），点击 BottomSheet 详情（记忆按 scope 标签 + 已挂载服务快照 + 超预算丢弃注记）；`onItemExclude` 为预留钩子（null 不渲染排除位，当前不接线）；codec 增 'context' 类型往返（恢复态 onItemExclude=null 锁定，同 TrackMemoryCapsule 口径）；chat_page._send 装配点原「✓ 已载入宿主记忆 N 条」TrackNote 替换为归因条。
- **修复「工具轮后记忆胶囊不出现」**：`WorkspaceStreamFilter.cancelCommit` 置位的提交禁令在多轮 Run 中永不解除（仅 abort 的 discard 复位），首个 tool-call 轮之后所有自然结算轮的合法 `<workspace_update_v1>` 段被 `_tryCommit` 静默丢弃（胶囊不渲染、记忆不落盘）。修法 = feed 中新段（startTag 完全匹配）开启即解除禁令——禁令只压结算时已清空的本段残留，不株连后续轮次新段；新增 filter 回归测试。
- **悬浮记忆入口（≡ FAB）**：与「回到最新」同款 small FAB（Stack 右下 bottom:8，返回键共存时回底钮上移 72）；仅当轨道存在 TrackMemoryCapsule 时显示；点击弹 BottomSheet 汇总列表（l1Ok 状态点 + 等宽 key=value，已撤销条目灰阶删除线终态锁定），纯展示不做修改入口（undo 仍走内联胶囊通道）。
- **空提交可观测**：`_tryCommit` 尾部 kDebugMode debugPrint '[workspace-filter] commit facts=N'（release 静默），区分「纯闲聊空 {} 提交（0 条，无胶囊属预期）」与「模型未输出标签/禁令丢弃」，供真机排障。
- **默会提取协议（promptInstructions，静态区不变护前缀缓存）**：从「仅硬性约束/关键决策/业务实体」扩为对话要点默会提取——①用户目标 ②陈述事实与关键细节 ③选择/决定 ④决定理由；scope 默认一律 session（本会话域落 wsStates），仅用户明确跨会话意图才升 user/srv；新增铁律④「默默提取、不在正文提及协议」。四域白名单 = task.goal / env·fact / decision(结论+原因原子单 key) / constraint.avoid_*；抑制清单（过程细节/假想推演/寒暄）；同 Key 覆盖禁 v1/v2 副本。
- **四域协议定稿四细节（评审修正）**：①占位符 `<n>`→`<主题>`（防端侧小模型误解为数字编号致同 Key 覆盖失效）②action=remove 显式触发规则（用户明确推翻/撤销才设 remove，废案解禁通路）③空态改「严禁输出本标签」（省 token 防闲聊污染，FSM 对无标签正文天然放行；解析器保留 {} 容错）④协议文本压缩 ~250 token（端侧遵循度）。示例修正为 facts 包裹 schema（评审草案原为裸数组会被 `_tryCommit` 静默丢弃）。
- **上下文阶梯截断 + 归档摘要**（设计稿 `docs/design/context-stepped-pruning.md`，status: draft）：`context_governor` 新增 `steppedWindow` 纯函数（高低水位 6~12 双缓冲，纯追加吃满前缀缓存，触线一次剪 6 轮；裁剪点 Assistant 边界 + 回退越过紧贴 UserMessage 防保留轮失提问）；`agent_loop` 接线——summarizer!=null 时阶梯替代朴素滑动，Run 级 archivedSummary 滚动（旧摘要+新裁轮次重摘），摘要块 UserMessage 插装前导之后/保留区之前；降级：summarizer=null 走朴素滑动契约不变，摘要失败 E1 弃归档 DEGRADE 留痕。行为变更①窗口 6→6~12②发送区含归档块，均登记设计稿 §3。
- **记忆冷热分层与增量压实（CQRS 两视图分离，设计稿 §6）**：新建 `lib/coordinator/memory_journal.dart`（frozenBase 字节冻结 + pendingDeltas Append-Only；squash last-wins 首现序折叠、非 DEL 终态归并 SET；compact=Tick 压实）；`MemoryKernel.onCapsule` 扩为 `(key,value,action,scope,undo)`（action/scope 供 delta 判 SET/OVERRIDE/DEL，undo 走 DEL——撤销也 append-only）；chat_page._send Tick 同频判定（滑窗高水位 12 / TTL≥5min 机会主义 / transcript 体量 >8k 突发兜底）+ systemTail=frozenBase；`agent_loop.run` 新增 `contextFooter` 参数（Delta 后置沉底：插 history 后、提问前，escapeUserTag 消毒——防增量区推移其后窗口原文的前缀缓存粉碎）；单向栅栏：_send 组装读快照、Run 内 onCapsule 只写 pending 池；session 域不注入 prompt（现状缺口已记设计稿 §6.1，journal 覆盖 user/srv 域）；切会话 compact('') 重置。
- **记忆治理模块分离（window-kernel-split 落点纪律）**：新建 `lib/coordinator/memory_governor.dart`（MemoryGovernor：journal/TTL 时间戳/Tick 判定/水位常量全部收编，纯 Dart 零 Flutter，clock 可注入）；chat_page 残留策略清零（_memJournal/_lastRunEndedAt/_kTick* 四字段 → 单一 _memGovernor，窗口只测 transcript 轮数/体量并投影 systemTail+footer）；实现期修 `_anchored` 锚点 bug——空 store 合法渲染空串快照后 frozenBase.isEmpty 恒真，会把「未建锚」与「锚为空」混同导致每 Run 重压实，加显式锚定标志（reset 归零）。
- **验证基线**：全量 **706/706 全绿**（journal 语义 5 + kernel delta 通道 1 + contextFooter 沉底/消毒 2 + governor Tick 矩阵/单向栅栏/reset 3 + promptInstructions 四域/schema 文本锚点 2 + steppedWindow 水位边界 5 + agent_loop 归档行为 4）；实现期修 squash 首现序 bug（reversed 收集误得末现序，改 Map 插入序实现）；`flutter analyze` 0 issue。真机端到端多轮未执行（待用户）。
- **G1~G8 缺口清单对账留待**：本批落地了 journal/压实/阶梯截断/归因条，但「真实缺口」节的逐项勾稽留待该 epic 活跃窗口专门做，避免归并轮误判状态。
