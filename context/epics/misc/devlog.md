---
dev-loop: devlog
format: v1
epic: misc
total-merged: 5
last-merge: 2026-10-22
---

（开发过程日志按行追加：[变更]/[验证]/[note]/[SSOT 修正]；≥5 条自动归并进 memory.md——dev-loop §2）

[变更] 2026-10-19 会话侧边栏全局入口横排化（用户拍板，HCI/美学评估后实施）：`lib/ui/components/conversation_drawer.dart` 底部「设置/资源中心/任务对账/记忆库」四竖排 ListTile（约 260dp）→ 横排工具带 `_DrawerUtilityItem`（约 52dp），省出高度归会话列表——抽屉主任务=会话切换（一级内容），全局入口为二级内容，空间分配向一级倾斜。规格走 ui-design：热区 ≥44dp（§4.4 透明 padding 补足，对冲横排后单项目标面积缩至 1/4 的误触回退）、图标+文字双通道保识别（§6 禁纯图标——「任务对账/记忆库」为领域词汇）、`Fsz.microSm` + `terminalMuted` 灰阶弱化（§4.7 token 化零魔法值）；四项顺序原样保肌肉记忆；导航编排不变（`_openPage` = pop 抽屉 + push 目标页）。
[验证] arch-guard 0 违例 + `flutter analyze` 0 issue + `flutter test --timeout 180s` 全绿 928（DEGRADE 行为纯 Dart 环境预期降级）；新增回归用例「全局入口横排工具带」：四项文字标签齐备、同一横排且顺序原样、ListTile 仅剩会话列表项（竖排已移除）、InkWell 渲染高度 ≥44dp（`test/ui/conversation_drawer_test.dart`）。
[note] 入口描述同轮同步：`resource_center_page.dart` / `settings_page.dart` / `task_ledger_page.dart` 文件头 + `docs/project/index.md` 两处落点表述改「底部横排工具带」口径（task_ledger_page 原「侧边栏顶部」为存量笔误，本轮顺修）；真机视觉验收待用户侧载（无模拟器，workflow §2）。
[变更] 2026-10-19 context 归档迁移（承 268772f 存量债专项收口）：13 个已完结 epic（arch-hardening / init / m2-5-skill-refstore / m3-ui-subs-sampling / m4 / p0-security-correctness / page-revamp / prompt-mgmt / self-update / stream-perf / system-assessment / task-consume-loop / thirdconnect）自 `epics/` 入库 `archive/`，`epics/` 仅留 7 活跃域（ai-app-split / chatmessage / instant-sampling / mcp-orchestration / misc / resource-center / window-slim）；prompt-mgmt memory.md 随迁重写为 17 行「已归档」摘要（32 行原件即删），m2-5 / m3 memory.md 精简移除，7 处 `memory.md.bp.lock` 剔除（锁不随归档）；同轮核对并复原上一轮回退残迹（工作区 archive/ 被清空 + epics/ 未跟踪副本）——副本与归档件逐字节一致（mismatch=0），复原后按暂存区原样落盘。
- [2026-10-22] [变更]: 聊天页 P2 打磨（用户拍板）：① P2-11 本轮记忆入口常驻化且恒可点——原「首颗胶囊入轨才出现」导致 AppBar 布局跳变；按 SSOT §1「禁止静默禁用」不给置灰方案，改为图标色 + tooltip 双通道分档（有记忆 l1Ok / 无记忆 terminalMuted），无记忆时点开同一汇总列表，其空态回答「模型从对话里认出稳定事实时会写入这里，入轨的每条都可在流内逐条撤销」。② P2-12 思考轨表头补自述 kThinkingHint「模型内部推理 · 不进对话历史，不影响结果」——默认收起只露「思考过程 ▸」时用户得自己猜「要不要看/看了算不算数」，自述与 CloudThinkingDelta 展示 only 四不契约同口径。③ SSOT 回填 chat-interaction.md（记忆入口常驻口径 + LoopThinkingDelta 行加自述要求）
- [2026-10-22] [验证]: flutter analyze 全仓 → No issues found；flutter test --timeout 180s 全量 986 绿（985 + 本轮新增 1 例：无记忆时记忆入口可点且空态有解释；思考表头自述断言并入既有 TrackThinking 用例）；toolbox run arch-guard → OK；toolbox run docs-lint → OK；未执行: 真机走查（常驻 Bolt 在窄屏 AppBar 与标题的挤压、表头自述行在 360dp 宽下的截断）
