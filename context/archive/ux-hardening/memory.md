---
dev-loop: memory
format: v1
epic: ux-hardening
total-merged: 1
last-merge: 2026-10-16
---

# ux-hardening（已收尾归档 2026-10-16）

- [挂载] docs/design/ux-hardening.md

> 普通用户可用性加固：管「出错后的用户之路」与冷启动，不管视觉规范（page-revamp 域，SSOT=ui-design.md）。

## 结论（::done 收尾，devlog 18 条已提炼）

- **域界**：与 page-revamp 不重叠——page-revamp=视觉/信息结构；本 epic=反馈/术语/权重/可见性；重叠面（破坏性确认、信任卡）归本 epic。不做新功能扩张（排队发送等新交互须先拍板）。
- **9 项盘点问题全闭环**：P0×3（冷启动引导卡/错误白话+重试行动卡/辅助面错误隔离与分色）＞ P1×5（运行中出口/会话管理/决策卡白话/术语层/信任权重）＞ P2×1（DEGRADE 用户可见性）；验证基线 705 过（唯一失败=并发窗口未跟踪测试，已移交）。
- **DEGRADE 标记清算**：6 处标记全部转 (风险) 待办（不删标——均为有意降级且已补用户可见/收紧方向，逐条留痕见 misc 台账）；cow_sync:74 / conversation_archive:122 标记注释已刷新至 P2-1 后行为。
- **收尾审计**：本 epic 自身 12 项全 ✓；他 epic 存量债务（HDR/TODOS/MOUNT/MERGE 23 违规 21 告警）与 lessons 待归并 10 条，按多窗口纪律（todo #18）留账随各窗口处理，未代改。

## 断点
- [断点] 已完结（2026-10-16 ::done）：章程 9 项闭环 + 标记转办 + 本目录归档 context/archive/ux-hardening/；恢复流程永不再读本文件。
