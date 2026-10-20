---
dev-loop: memory
format: v1
epic: window-kernel-split
total-merged: 0
last-merge: none
---

# window-kernel-split

- [挂载] docs/design/window-kernel-split.md
- [实施] context/epics/window-kernel-split/plan.md —— WBS + 门禁 + 回滚点（2026-10-16 立，设计稿 §7.5 的可执行展开；本文件只记状态与指针，不抄任务）
- [域] ai-app-split（从属大域：goodhub / goodshare 拆分后的宿主侧架构；本 epic 是其 **UI / 装配侧**落地。注：epic 名须等于文档 slug，故未直接挂 `ai-app-split`，域归属以本行指针表达）

## 结论（2026-10-16 一轮评估）

- **定性**：ChatPage 兼三角色——① 会话窗口（本职）② 装配中枢（越权，待拆）③ 应用外壳（**已于 2026-10-16 page-revamp 轮解除**：设置弹层与 debug 菜单迁出、AppBar 清空）。**本轮只处理 ②**。
- **内核 11 个**：ServiceDirectory / McpRuntime / EngineSupply / TrustGovernance / ConversationArchive / ConversationSession / Memory / SkillSupply / Gateway / TaskLoop / Updater。本轮**只碰 Directory + McpRuntime + Session**，其余仅登记。
- **命名**：落地 `McpRuntime`（`lib/coordinator/mcp_runtime.dart`），不用 ServiceRuntime——云端引擎侧 Run 级装配已由 `hybrid_assembly.dart` 承载（4 处在跑）。
- **准入**：S2 结构性引入，否决信号 #2 命中且是 **3 处**不是 2 处；命中落点是 **Directory**（三处拼 `mcp_servers.json`，`gateway_controller:148` 漏 prefs 迁移 = 活 bug），故 Directory 排步 0。
- **两条裁决**：① `MemoryStore` 兼审计日志——本轮不动，已落 chatmessage 待办 `(风险)[long]`；② `TaskLoop` 直连 baseUrl——步 2 仅适配 `mountEndpoint(ephemeral)`，**不开** `assemble(baseUrl:)` 重载。
- **端口组 8 个**：`onNote` / `onProgress` / `connectionReport` / `majorJumpDelegate` 需新建；`consent` / `gate` / `fence` / `block` 四个 delegate 已有、零成本。**`onToolCall` 不在内**（执行期事件流，属窗口）。
- **搬迁边界写死**：装配段 = `chat_page._send` **658→970**（末行 `loopBox = loop`），**991 起事件循环不搬**。
- **单测前移到步 0**：断言"装配产物等价性"，不是重测 ToolRouter（后者已被 `discovery_executor_test:177-305` 覆盖）；另补 `_resolveBinding` 回退链纯函数测试。
- **二轮评估（架构形态，2026-10-16）**：定性 = **两层 + 端口**——窗口投影层 单向依赖 内核层；向下传值对象（`SessionContext` + 装配选项），向上传 8 个回调端口（事件/确认，控制反转），横向内核读内核走**具体类型 + 快照**（无接口）。**不是** Clean/Hexagonal 完整形态（无 use case / repository / DTO 层）；该取舍成立（接口爆炸收益低），但须把"长生命周期可被短生命周期依赖、禁止反向"写死为铁律。
- **二轮评估的实证通过项**：三处拼装成立（chat_page:303 / settings_page:268 带 prefs，gateway_controller:148 **无 prefs** = 活 bug）；装配段 658-970 确与 UI 交织（`_add`/`_setPill`/`showTrustCard(context)`）；`GateDelegate`/`BlockDelegate`/`PiiFenceDelegate` 三个接口**无 Flutter 依赖**→ 四个 delegate"零成本原样传"成立；`_GuardedExecutor`(65-80) 是纯 Dart 可搬；`finally`(1089-1108) 混杂三类收尾（视图 / 资源 / 持久）。
- **二轮评估发现的接线缺口（步 0 前须裁决）**：① 991-1076 事件循环留窗口，但内含两处**写内核态**（`_history` transcript 回写 1067、`_activePrivateServerId` 绑定捕获 1079-1085）→ 缺写回通道；② headless 路径缺 delegate 缺省语义（`GateDelegate.confirm` 是 await 用户确认，gateway 无 UI 会挂死）；③ `assemble()` **返回句柄未定义**（窗口要拿 `loop`/`connections`/`router`）；④ `SessionContext` 是入参快照还是活态容器**自相矛盾**（`_samplingQuota` 可变跨 Run）；⑤ §7.2 把"会话快照落盘"误归视图态——它属 Archive 持久态，非视图态（铁律 3 不适用）。

## 裁决（2026-10-16 二轮拍板，六项 · 已回写正文）

指针：**`docs/design/window-kernel-split.md` §8.1 台账**（本表不抄正文内容）。

1. **写回**——窗口（Session owner）显式调 `replaceTranscript`（**全量替换**，非 append）/ `bindPrivateServer`（**三态**）/ `unbindToPublic`；不新增端口。
2. **headless**——`gateDelegate` **可空、传 `null`**，复用 `PermissionGateway` 既有 fail-closed；**不建 HeadlessGate**，**禁止**在 delegate 内做只读自动放行。
3. **出参**——`Future<McpAssembly>`（`loop` / `router` 仅 close 前有效 / `abort()` / `close()`），`connections`+`refStore` 封死；装配须受 `clientFactory` 注入以供步 1 断言。
4. **配额**——`SessionContext` 纯不可变**不含配额**；`SamplingQuota` **实例独立入参**（非 token、非 bool）；归 Session 后**切会话即重置** = 行为变更，入步 3 验收。
5. **归档**——落盘属 `ConversationArchive`（持久态）勘误成立，**本轮不迁**（Deferred），暂留窗口。
6. **规则**——补**铁律 4 生命周期单向依赖**（应用级 ← 会话级 ← Run 级；变更经**快照 + 端口**，不写"事件通知"）；其余 8 内核 **Deferred / Catalog Only**；「未认领」≠「不接触」。
7. **`close()` 语义**——**幂等** + **两段**（`abort()` 仅中断不释放 / `close()` 释放且幂等）；关到哪一层写死 = `stop()` **+ `client.close()`**（现状只 stop，底层未释放 = 既有债，随搬迁修）。**并发踩踏无路径**（单飞守卫 + 池 per-Run 独立 + §9 不做全局池）→ **不做 RunContextId**。
8. **端口异步与取消**——挂起 `Future<T>`（gate/fence/block/consent/majorJump，三个 delegate **已是 Future**）vs 广播 `void`（onNote/onProgress/connectionReport）；**Abort 兜底**：以 `approved:false, reason:'aborted'` 完成所有 pending 卡，防 `TrackConfirm.completer` 永挂。
9. **ephemeral 凭证隔离**——不进 Directory 列表、不参与 `save()`（全量覆写会落盘）；记忆/日志 scope 强制任务上下文，禁写 user/srv 全局域。落步 2 第 3 项。
10. **铁律 2 降级**——**接受**：路由维持 `Navigator.push`，**不引 App Shell Router**（纯形式主义）；「不跨窗口共享可变引用」已达解耦实质。
11. **联调页 fake 注入位**——**保留挂载原语、拒绝特权分支**：不开 `isFakeDebug` 装配参数，fake 传输经 `clientFactory` 注入，与生产同路径。
12. **`lib/mcp/tool_router.dart` 不删**——它是 F1.9（P0）海关过滤唯一实现 + SA-Q6 已拍板「保留待接线」+ 有测试引用；§7.4 原「死件」表述**已勘误**，装配仍不得引它。

**不入本轮（已记 `todos.md`，非遗忘）**：`SamplingQuota` 落盘（`风险[long]`）、Directory 通知通道（`风险`，场景不成立：`chat_page:490` 菜单每次重读）、`client.close()` 未调（`清理[short]`，随步 1 修）。**不成立项**：切会话写冲突（`_guardRunning` + `_persistIfAny` 已挡）。

## 待确认（0 项 · 冻结解除 2026-10-16 四轮）

- 铁律 2 降级 → 已拍板接受（§8.1-10）；联调页 fake 注入位 → 已拍板走 `clientFactory`、拒绝特权分支（§8.1-11）。
- 后续新增议题进 §8.1 台账或 §8.3（不入本轮），本表不再累积。

## 断点
- [断点] 下一步：三项行为变更验收全部代码级闭环（①配额重置单测 ②headless 已覆盖 ③transcript 单测）；下一步：真机端到端常规冒烟（正常聊天/私有绑定/abort-close）→ ::done 收尾（UNCERTAIN/DEGRADE 清零结算）
