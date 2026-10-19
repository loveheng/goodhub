---
dev-loop: devlog
format: v1
epic: misc
total-merged: 4
last-merge: 2026-10-19
---

（开发过程日志按行追加：[变更]/[验证]/[note]/[SSOT 修正]；≥5 条自动归并进 memory.md——dev-loop §2）

[变更] 2026-10-19 会话侧边栏全局入口横排化（用户拍板，HCI/美学评估后实施）：`lib/ui/components/conversation_drawer.dart` 底部「设置/资源中心/任务对账/记忆库」四竖排 ListTile（约 260dp）→ 横排工具带 `_DrawerUtilityItem`（约 52dp），省出高度归会话列表——抽屉主任务=会话切换（一级内容），全局入口为二级内容，空间分配向一级倾斜。规格走 ui-design：热区 ≥44dp（§4.4 透明 padding 补足，对冲横排后单项目标面积缩至 1/4 的误触回退）、图标+文字双通道保识别（§6 禁纯图标——「任务对账/记忆库」为领域词汇）、`Fsz.microSm` + `terminalMuted` 灰阶弱化（§4.7 token 化零魔法值）；四项顺序原样保肌肉记忆；导航编排不变（`_openPage` = pop 抽屉 + push 目标页）。
[验证] arch-guard 0 违例 + `flutter analyze` 0 issue + `flutter test --timeout 180s` 全绿 928（DEGRADE 行为纯 Dart 环境预期降级）；新增回归用例「全局入口横排工具带」：四项文字标签齐备、同一横排且顺序原样、ListTile 仅剩会话列表项（竖排已移除）、InkWell 渲染高度 ≥44dp（`test/ui/conversation_drawer_test.dart`）。
[note] 入口描述同轮同步：`resource_center_page.dart` / `settings_page.dart` / `task_ledger_page.dart` 文件头 + `docs/project/index.md` 两处落点表述改「底部横排工具带」口径（task_ledger_page 原「侧边栏顶部」为存量笔误，本轮顺修）；真机视觉验收待用户侧载（无模拟器，workflow §2）。
[变更] 2026-10-19 context 归档迁移（承 268772f 存量债专项收口）：13 个已完结 epic（arch-hardening / init / m2-5-skill-refstore / m3-ui-subs-sampling / m4 / p0-security-correctness / page-revamp / prompt-mgmt / self-update / stream-perf / system-assessment / task-consume-loop / thirdconnect）自 `epics/` 入库 `archive/`，`epics/` 仅留 7 活跃域（ai-app-split / chatmessage / instant-sampling / mcp-orchestration / misc / resource-center / window-slim）；prompt-mgmt memory.md 随迁重写为 17 行「已归档」摘要（32 行原件即删），m2-5 / m3 memory.md 精简移除，7 处 `memory.md.bp.lock` 剔除（锁不随归档）；同轮核对并复原上一轮回退残迹（工作区 archive/ 被清空 + epics/ 未跟踪副本）——副本与归档件逐字节一致（mismatch=0），复原后按暂存区原样落盘。
