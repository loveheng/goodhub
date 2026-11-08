---
dev-loop: memory
format: v1
epic: ai-capability-export
total-merged: 0
---

# ai-capability-export（临时 epic）

- [挂载] docs/design/ai-capability-export.md
- [临时] 2026-11-08 用户裁决挂临时域收口设计稿；正式立项时按 D3 更名 / 迁移，记忆随域搬

## 决策（已拍板 2026-11-08）
- D1 路由权：端侧 / 云端由设备主在 goodhub 设置选择，调用方不得强制；`completeSync` 固定默认端侧
- D2 sampling：`sampling/createMessage` 保留兼容，实现收敛为 `ai/complete` 适配壳
- D3 立项：新独立 epic（本域即前身，正式立项时转正）
- 封板节奏：设计稿 status 保持 draft，用户待打磨后另定

## 断点
- [断点] 设计稿十二轮评审收口、决策点清零（§7 留档 D1~D3）；等待用户封板 → M-A 契约立法：契约仓 `:contract` 加 method 常量 + 十二码表 + `_meta.phase` + `retry_after_ms`、版本递增 → goodshare 仓 `ai-app-split.md` / `ai-dev-spec.md` §4 成对修 → `toolbox run check-contract-sync`
