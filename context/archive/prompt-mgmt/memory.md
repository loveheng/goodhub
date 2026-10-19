---
dev-loop: memory
format: v1
epic: prompt-mgmt
total-merged: 1
last-merge: 2026-10-19
---

# prompt-mgmt（已归档 2026-10-19）

- 准入：S1 局部能力补全，不引入新容器；六否决信号全不命中。
- 方案三件事：① appScoped 按激活私有槽位过滤（保前缀缓存）；② 切域同拍原子变更；③ user 来源全局 prompt 的 UI 管理/持久化（受 300 Token 注册闸）。
- 落地：ToolRouter Run 边界快照隔离 + pending 切域事务提交点（onRoundCommitted→commitPendingSlot）+ 断连 pending 降级收敛；UserGlobalPromptsStore + UserPromptsSection + buildBaseSkillRegistry 装配管道；SkillRegistry.appScoped()/knownNames() 只读投影。
- 透明面：记忆看板第 4 Tab「提示词」只读总览（全局读 UserGlobalPromptsStore 落盘面 + 服务读活态 appScoped()，回落 CowOverridesStore 基线并明示差异）。
- 双根因修复：A) CoW keptLocal 覆写正文进注册表（cow_sync 两分支携 override 生效内容，content==null 过滤不再丢弃）；B) 看板提示词段由 ListView 改 SingleChildScrollView+Column（eager build），离线态/覆写正文恒可见。
- 防御：DEGRADE 标记均引设计文档（§8.2.3 / P2-1）fail-closed，ADR 支撑未逾期；水位计 core/tokens.dart estimateTokens 超 300 禁保存；注册闸 fail-fast 跳过项经 skipped 通告。
- 收尾：全量 903 绿；Telemetry 真机观测 + user 全局 Prompt 设置段真机侧载验证已完成（用户确认）。
