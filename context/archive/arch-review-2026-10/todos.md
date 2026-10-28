---
memo: todos
format: v3
epic: arch-review-2026-10
---

# arch-review-2026-10 · 域内待办

## C 类（纯文档）—— 本轮已结

- [x] [2026-10-28] (架构) (重:低) #27 孤立件裁决：选 B（钉为规则独立镜像 + 文件头声明），决策已落 coding-standards §1.1 规则 7 / §5.6；不并回 coordinator（SA-Q6 保留待接线，待 SDK annotations 后按 #9 收编）；「同轮回写规约」已完成 → 结案 (src: ai)

## A 类 —— 按施工稿 `docs/design/arch-consolidation.md` 推进

- [x] [2026-10-28] (架构) (重:高) S2 装配 Profile 化：`RunProfile`（chat / gateway / headless）同一 `assemble` 出参，网关与 task 自拼逻辑退役，「不并回 assemble」红线改 profile 变体（✅ 已交付，标记滞后补全） (src: ai)
- [x] [2026-10-28] (架构) (重:低) S3 尾项：`_resetSessionState` 换 `CancellationToken` + `dual_track_stream` 按卡片类型拆子组件（独立小步） (src: ai) — 注：`_resetSessionState` 纯会话切换复位，与取消解耦；取消统一入口经 `useCase.cancel()`（`ChatSendUseCase` 自 `assembleRun` 起持锚点），未新增 `CancellationToken` 空壳件；`dual_track_stream` 拆 15 子组件，行为等价
- [x] [2026-10-28] (架构) (重:中) S4 写通道收口：`SequentialFileWriter` 增静态原子写入口，五处手写 `tmp → rename` 替换 + arch-guard 禁裸 `.tmp` 规则（✅ 已交付，标记滞后补全） (src: ai)
- [x] [2026-10-28] (架构) (重:中) S6 主体一级抽象：`Actor` 在鉴权层推导 + 工具声明 `allowedActors`，新增对外工具未声明即装不上（补单测矩阵完备性断言）（✅ 已交付，标记滞后补全） (src: ai)
