---
dev-loop: memory
format: v1
epic: m2-5-skill-refstore
total-merged: 2
last-merge: 2026-10-11
---

# m2-5-skill-refstore（已完结 2026-10-11 ::done）

- [挂载] docs/design/m2-5-skill-refstore.md（内容 SSOT：范围 / T1~T7 分解 / 各任务实现注记 / C-1~C-4 工程补齐）
- 结论：M2.5 七任务（T1~T7）全完成并真机联调通过——契约 ai-app-split.md §3.6~§3.9（Tier 分类 / prompts CoW / resources 只读面 / progress SSE opt-in）+ goodshare prompts·resources·SSE 真实现；goodhub 协商垫片 / RefStore / 注水拦截 / 三级 Skill / CoW 继承 / callWithProgress 流式收侧
- 关键拍板（ADR-006/007 随迁本目录 decisions.md）：D1 = goodshare 同程实现；D2 = Progress 走 POST 响应 SSE 帧流（opt-in）；C-2 查无 $ref 立即 isError 回填（AI 代决可推翻）
- 联调修正：goodshare min_hub_version 1.0.0 → 0.1.0（占位错位致 CoW 全跳——单测只断言非不断言值的盲区，真机抓出）
- 验证基线：goodhub 全量 240 绿 / goodshare 全量 792 绿 / 双仓 analyze 0 / 真机 CPH2767 行为断言全过（协商 Tier 1 / 资源面 4 条 / CoW imported×3 / list_items 真卡 / 两轮工具环 done）
- M3 归位清单：跨源授权卡 UI、LoopToolProgress 事件流 + 卡状态机全量、Skill 覆写编辑 UI（服务大厅）、sampling/subscriptions、$ref put 端（Skill 编排）

## 断点

- [断点] 已完结（2026-10-11 ::done）——归档于 context/archive/m2-5-skill-refstore/，恢复流程不再读取；后继工作归 M3（UI 全量 + Subscriptions + Sampling）

