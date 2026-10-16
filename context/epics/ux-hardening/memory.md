---
dev-loop: memory
format: v1
epic: ux-hardening
total-merged: 0
last-merge: none
---

# ux-hardening

- [挂载] docs/design/ux-hardening.md

> 普通用户可用性加固：管「出错后的用户之路」与冷启动，不管视觉规范（page-revamp 域已清零，SSOT=ui-design.md）。
> 来源：2026-10-16 普通用户视角全库体验盘点（9 条发现，全部经 file:line 核对；清单与优先级见挂载文档 §2）。

## 决策

- **优先级拍板（2026-10-16 立项，用户「立项吧」确认）**：P0 冷启动与错误自救 ＞ P1 运行中出口 ＞ P1 术语与安全卡 ＞ P2 DEGRADE 跟进。
- **域界**：与 page-revamp 不重叠——page-revamp = 视觉/信息结构（已清零）；本 epic = 反馈/术语/权重/可见性。两页重叠面（破坏性确认、信任卡）归本 epic。
- **不做新功能扩张**：排队发送等新交互形态须先拍板再进范围（当前只修「无出口」的反馈缺失）。

## 断点
- [断点] 下一步：章程项全部完成（P0×3 + P1×5 + P2×1 共 9 条盘点问题闭环）——下一步待用户触发 ::done 收尾：审计前置 + 4 处 DEGRADE 标记逐条三选一处置（建议：均为有意降级且已补用户可见/收紧方向 → 转 (风险) 待办或 ADR 记档，不删标）；遗留项：并发窗口的 memory_governor_test 失败已报告待其窗口处理
