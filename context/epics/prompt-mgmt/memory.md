---
dev-loop: memory
format: v1
epic: prompt-mgmt
total-merged: 1
last-merge: 2026-10-19
---

# prompt-mgmt

- [挂载] docs/design/prompt-mgmt.md

## 决策

- 准入判定（2026-10-19）：S1 局部能力补全——SkillRegistry 三层 + CoW 管道已承接结构，不引入新容器；六条否决信号全不命中。
- 方案三件事：① appScoped 注入按激活私有槽位过滤（与 focusedSchemas 三段式同口径，保前缀缓存）；② 切域同拍原子变更（tools 尾块与 skill 尾块单次重前缀）；③ 补 user 来源全局 prompt 的 UI 管理/持久化入口（受 300 Token 注册闸）。
- 非目标：不做 server 版本覆盖管理、不动 tools/resources 注入语义、不引入新持久层。
- Tool-Search 元工具代理模式否决留档（design §4：问题不存在/汇率不划算/参数幻觉/门禁稀释/历史垃圾/双路分支；收敛条件 = 单服务工具量级几十个且检索意图明确时在 activate_server_tools 加 query 过滤）。
- 防御性扫描裁决（design §8）：采纳 5（槽位联动断连/切域提交点/fail-closed/水位计/边界清洗）+ 收窄 2（user/ 前缀规约/分层哈希 debug）+ 否决 1（bypass flag）。
- Phase 1 已落地（composeSystemPrompt 投影三元 + 段内 `serverId:name` 字典序 null 归一化 + 空槽位严格空串）；Phase 2 已落地（ToolRouter Run 边界快照 + pending 切域事务提交点 + 断连 pending 降级收敛；UserGlobalPromptsStore + UserPromptsSection + buildBaseSkillRegistry 装配管道）。

## 落地事实（2026-10-19 归并）

- Run 边界快照隔离：`ToolRouter.effectiveSlot`（Run 内 = beginRun 捕获快照），`beginRun/endRun` 由 ChatRunOrchestrator.plan/writebackSlot 承守；pending 切域事务提交点 = agent_loop `onRoundCommitted`（ToolResultMessage 全量落历史后）→ `router.commitPendingSlot`。
- 断连联动：`markPrivateServerOffline` 只写 pending 标记；连接建于 router 之前，改由 mcp_runtime 在 router 就绪后包一层 onDisconnectReport（保留原 connectionReport 广播）；降级通告经 `ChatRunPlan.slotNotice` 回窗口 TrackNote。
- user 全局 prompt：存储 `user_global_prompts.json`（应用文档目录，原子写 + 损坏隔离备份 + `corruptBackupPath` 面板警示）；注册名 `user/<name>`（SkillSource.user × SkillScope.global）；边界清洗 `sanitizeUserPromptContent` 全角转义（XML 危险标记/行首 markdown 分区头/`[System Notice:`）+ 计数回传 toast；名称规约 `validateUserPromptName`（禁 `/ : 空白 # [`）；水位计 UI 单源 `core/tokens.dart` estimateTokens，超 300 禁用保存不清空；注册闸 fail-fast 跳过项经 buildBaseSkillRegistry.skipped 通告。
- 遗留待办：端到端 Telemetry（真实模型 cached_tokens：同域连续接近全量命中 / 切域当轮重前缀流血值 / 切后第 2 轮恢复）+ 真机侧载验证设置段。
- 透明面（2026-10-19）：记忆看板第 4 Tab「提示词」只读总览（`sections/prompts_overview_section.dart`）——全局 Prompt 读 `UserGlobalPromptsStore`（落盘即注册面）恒随 App 启动可见、与会话无关；MCP 服务 Prompt 读连接态 `SkillRegistry.appScoped()`（抽屉/窗口注入 `skillsProvider: () => session.skills`，其 globals()/appScoped() 反映当前已连接服务与静态预置、与具体会话内容无关），注册表不可用（看板先于连接打开）回落 `CowOverridesStore.knownNames()` 落盘基线（正文不落盘故不展示，明示差异）；零写面，编辑归设置页两段防双入口；底层新增 `appScoped()` / `knownNames()` 两个只读投影。
- 透明面补强（同日「索引的prompt都是空」复盘）：① 根因 A=既有功能缺口——CoW keptLocal（本地覆写）模板正文从不进注册表（`content==null` 过滤把覆写模板丢弃，「本地覆写最高优先级」落空）；修 `cow_sync.sync` keptLocal 两分支携 override 正文（生效内容）下发，调用方注册过滤不再丢弃；② 根因 B=看板提示词段原 `ListView`（SliverChildListDelegate 惰性渲染）离屏 server 卡片不 build→find 抓不到显「空」；改 `SingleChildScrollView+Column`（eager build），离线态补 builtin globals/appScoped 恒可见 + 覆写正文直接展示、未覆写模板正文不落盘走占位说明；cow_sync_test 2 例断言 keptLocal 携 override 正文。

## 断点
- [断点] 下一步：端到端 Telemetry 真机观测（cached_tokens 基线/切域流血/恢复）+ user 全局 Prompt 设置段真机侧载验证
