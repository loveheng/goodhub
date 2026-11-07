---
dev-loop: memory
format: v1
epic: on-device-residency
total-merged: 1
last-merge: 2026-11-07
---

# on-device-residency

- [挂载] docs/design/on-device-residency.md

## 正文

- 立项（2026-11-07）：底子文档 = docs/design/on-device-residency.md（评估 SSOT，R1–R8/L0–L4/P0–P3/W6 全量在内，拍板已完成——Prio 确认 + 契机 B ADR 已立）。
- P0 施工稿已定稿（文档第八节）：S-R0-a TTL 参数化（AIDL Bundle 缝，缺省零行为变化）/ S-R0-b Piggyback 观测面（驱逐四类+cold-reload+process-death 六分类，JSONL 账本 + logcat 镜像）/ S-R0-c 电池白名单独立入口。验证：docs-lint 通过；证据链 = initEngine Bundle 缝 / EngineLifecycle ttlMs 构造参数 / 驱逐原因四类规范串 / onEngineEvicted 汇入点三处（devlog 2026-11-07 归并）。

## 断点
- [断点] 下一步：采样会话收束（10+ 完整周期 + 1 条 R4 级劣化数据点）；下一步 = ①重启设备复测装载（碎片化对照）②P0 数据继续自然积累 ③P1 策略 owner 待数据
