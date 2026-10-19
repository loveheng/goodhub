---
dev-loop: memory
format: v1
epic: task-consume-loop
total-merged: 0
last-merge: none
---
dev-loop: memory
format: v1
epic: task-consume-loop
total-merged: 0
---

# task-consume-loop · 宿主侧任务消费闭环（M4 第一步）

- [定位] 修复「拉模型缺拉手」根因：goodshare 入队后**不推**（§3.2 拉模型），goodhub 侧 claim 调用链在生产代码零入口（人类入口 ClaimLoopPage 已归档、AI 入口不存在）→ 任务永久滞留 pending、UI spinner 空转。本 epic = 宿主侧消费循环，独立可验收（不依赖跨仓通知）
- [契约] goodshare 仓 `docs/design/ai-app-split.md` §3.12（2026-10-18 新增，本仓只读引用方）：宿主侧消费纪律 8 条（幂等自洽 / 自主时机 / **catch-up 是地基** / 单飞 dirty / 空拉终止 / **毒丸防护** / 生命周期解绑 / 熔断）+ §3.12.3 形态 B（宿主不可达由 goodshare 侧徽标 + 一键唤起，本仓零新增）
- [红线] 不改变 claim/apply 语义（§3.2/§3.4 零变更）；不引入常驻后台轮询（宿主自主原则：挂载/重连时 catch-up，非常驻拉）；通知（goodshare 侧后续叠加）只优化延迟、不承担正确性
- [结论] 核心件已落地（2026-10-18）：`lib/task/task_consume_loop.dart`（单飞 dirty / 达顶继续 / idle 终止 / 熔断 / 通道前置 / 让路 / dispose）+ 毒丸修复（`task_loop_service` 推理失败 apply failed 终态，既有「不 apply」断言已随契约改为须 apply）；analyze 0 + 全量 790 绿
- [结论] M4-2 接线已完成（2026-10-18）：`lib/app/task_consume_bootstrap.dart`（应用级装配件 + 进程级单例）+ `main` 启动触发 catch-up + `chat_page` 2 行注入 `isHostBusy`
- [结论] 对账能力已完成（2026-10-18 用户拍板三项）：`lib/task/task_consume_ledger.dart`（文件持久化账本）+ 设置页「任务对账」段 + 事件扩展（`TaskClaimed.itemId`/`LoopFailed.taskId`）；analyze 0 + 全量 801 绿
## 断点
- [断点] 下一步：待 AI 回填：该 epic 断点由 ctx-fix 结构重建（专项清理），须下一轮读 devlog 尾部补真实下一步
