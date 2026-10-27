---
dev-loop: memory
format: v1
epic: task-orchestration
total-merged: 1
last-merge: 2026-10-28
---

# task-orchestration

- [挂载] docs/design/task-orchestration.md

## 结论
- B1 代码面全量落地并发版：v1.2.0（build 2015）已推送 main、发布 R2 更新源；链路 = propose_task_plan → PlanGuard → Gateway（PlanGrantSource），会话级 PlanRunState 由 ChatRunOrchestrator 持有、McpAssembly.close 为 Run 收口唯一咽喉
- 落点：lib/coordinator/{task_plan,plan_guard,plan_proposal_tool}.dart + lib/ui/{task_plan_card,task_result_card}.dart；代码落点表见 docs/project/index.md，内核 12 号 PlanOrchestration 见 docs/design/window-kernel-split.md §3.1
- 围栏口径：step-id 无条件剥离归属（缺失走启发式 inferred）、每对配额跨续跑累计、毁坏步（D1）不入批量授权；R6 二次校验防 TOCTOU——确认手势那一刻重查 availabilityIssue，掉线步置 failed（与 skipped 分立，经 ToolResult 回填）
- 门禁基线：arch-guard + drift-guard --root . + analyze 0 issue + test 1259 全绿（[DEGRADE] MissingPluginException 为纯 Dart 环境预期降级）
- 发布口径：清单 versionCode = pub 号 + 2000（aapt2 校验）；.env 的 CHANGELOG 已置空走脚本默认（自动取最近 commit），防硬编码说明错发

## 断点
- [断点] 下一步：#11 真机 e2e 云南四插件场景+毒丸 A~F（需真机侧载；代码面 B1 已全量落地、全门禁绿、v1.2.0 已发布 R2，等设备接入后跑 workflow §2 装机验证）
