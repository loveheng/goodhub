---
dev-loop: memory
format: v1
epic: on-device-residency
total-merged: 0
last-merge: none
---

# on-device-residency

- [挂载] docs/design/on-device-residency.md

## 正文

- 立项（2026-11-07）：底子文档 = docs/design/on-device-residency.md（评估 SSOT，R1–R8/L0–L4/P0–P3/W6 全量在内，拍板已完成——Prio 确认 + 契机 B ADR 已立）。
- P0 施工稿已定稿（文档第八节）：S-R0-a TTL 参数化（AIDL Bundle 缝，缺省零行为变化）/ S-R0-b Piggyback 观测面（驱逐四类+cold-reload+process-death 六分类，JSONL 账本 + logcat 镜像）/ S-R0-c 电池白名单独立入口。

## 断点
- [断点] 下一步：P0 施工稿定稿（文档第八节）；下一步 = 施工 S-R0-a/b/c 三批（建议顺序 a→b→c，各批独立真机冒烟）
