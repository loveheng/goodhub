dev-loop: devlog
format: v1
epic: task-consume-loop
---

# task-consume-loop devlog（M4 第一步：宿主侧消费循环核心件）

## 2026-10-18 核心件 + 毒丸修复（接线待 M4-2）

- 根因复盘：goodshare 任务永久滞留 pending 的根因 = **拉模型缺拉手**——goodhub 生产代码零 `claim_ai_task` 调用点（人类入口 ClaimLoopPage 随 `532eb52` 归档摘除，「AI 入口」并不存在）。非签名/权限问题（Manifest `<uses-permission com.zzh.goodhub.permission.MCP_SERVER>` 与 `<queries>` 均已声明）
- 新增 `lib/task/task_consume_loop.dart`：单飞 dirty（运行期间 trigger 只置标记不并发 claim）/ 达顶继续（单轮跑满 ≠ 队列空，须续跑——补形态评审时漏掉的漏洞）/ idle 终止（空拉不轮询）/ 连续失败熔断 / 通道存活前置（注入端口，防向已断 Binder 发 IPC）/ 算力让路（注入 `isHostBusy`，前台对话时暂缓重试）/ `dispose` 生命周期解绑（清 timer + 复位）。依赖倒置：不 import ui/gateway，端口全注入
- 毒丸修复 `lib/task/task_loop_service.dart`：新增 `_inferGuarded` + `_closeTask`——推理失败**主动** apply(note) 回写 failed 终态（原实现留 processing，30s 被 `reclaimStaleTasks` 重置 pending 反复认领 = 无限重试烧额度）。**既有测试「推理失败 → 不 apply」断言同步改为须 apply**（契约 §3.12.2-6 行为变更）
- 测试 `test/task/task_consume_loop_test.dart` +9 例全绿：空拉终止 / 批量消化 / 达顶继续 / 单飞 dirty 补跑 / 熔断 / 毒丸 failed 收尾 / 通道离线跳过 / 让路重试 / dispose 解绑
- 验证：flutter analyze 全仓 0 issue；全量测试 790 绿
- 文档：index.md 登记消费循环落点 + §3.12 契约指针 + 毒丸防护备注

## 2026-10-18 M4-2 接线（应用级装配件）

- 新增 `lib/app/task_consume_bootstrap.dart`：插件识别（`kGoodsharePackage` 包名常量，跨仓同族）→ `createClient` → `GoodshareTaskApi` + `HybridTaskInference(assembleDefaultHybridEngine())` + `TaskConsumeLoop` → `trigger()` catch-up。进程级单例 `taskConsumeBootstrap`（仿 `localPluginDiscovery` 范式）
- 依赖倒置：`LocalPluginSource` 接口注入（该接口本就为可注入而引入，P0-B）；`isHostBusy` / `isChannelAlive` 为可变字段，经闭包读最新值 → 窗口层后置注入对已建循环生效
- 接线点：`main.dart` `_startTaskConsume()`（与 `_warmEngine`/`_sweepMemoryStartup`/`_sweepRefStoreStartup` 并列，unawaited + DEGRADE 留痕）；`dispose` 调 `taskConsumeBootstrap.dispose()`（清 timer + close client）
- 窗口层仅 2 行：`chat_page.initState` 注入 `isHostBusy = () => _status.running`（算力让路）、`dispose` 置 null 解绑。装配逻辑全在 app 层，未加重 chat_page 超标债
- 测试 `test/app/task_consume_bootstrap_test.dart` +5 例：发现即装配 / 未发现跳过 / 扫描失败 DEGRADE / start 幂等 / 让路端口后置注入生效
- 验证：analyze 0；全量 **795 绿**

## 2026-10-18 对账能力（执行侧透明，用户拍板三项）

- 拍板：展示 = 设置页「任务对账」分区；粒度 = 计数 + 最近 20 条明细（时间/动作/条目 id/结果）；持久化 = **文件**（跨会话保留）
- 新增 `lib/task/task_consume_ledger.dart`：今日计数（跨日自动归零）+ 最近 N 条明细；`underSupportDir` + `SequentialFileWriter` 原子重写（P0-A 后互斥粒度 = 文件路径，跨实例安全）；损坏文件返空账 + DEGRADE（宁空勿炸，同 WorkspaceStateStore 口径）
- 事件扩展（对账锚点）：`TaskClaimed` 加 `itemId`、`LoopFailed` 加 `taskId/itemId`（TaskLoopService 持 `_current` 供失败事件回填）——emit 点各一处，无其他消费方受影响
- 接线：`TaskConsumeBootstrap` 给 service 挂 `onEvent` → 账本记账（Applied=成功 / LoopFailed、NotFoundClosed=失败带原因）
- UI `lib/ui/sections/task_ledger_section.dart`：设置页新增段（ConsoleTokens 零魔法值 + KeepAlive 混入）；账本经注入位传入
- 对账入口位置三轮定档（2026-10-18 用户）：设置页顶部 → 侧边栏顶部 → **侧边栏「设置」下**（最终）。实现：`TaskLedgerSection` 内容 widget 保留（注入位复用），新独立页 `lib/ui/task_ledger_page.dart`，侧边栏入口区「设置」之后加 ListTile；设置页段与 import 移除（迁移非复制，防双处漂移）
- 对账 UI 形态重塑（2026-10-18 用户）：列表为主、聚合降级为组头元信息、按 MCP 服务领域（serverId）分组、自然日过滤。改动 = `TaskLedgerEntry` 加 `serverId` 字段（`_record` 从 `start()` 取 goodshare 包名注入；`serverName` 可选）+ `recentEntries`/`groupedByServer` getters（原 `todayDone/todayFailed` 改为基于 `recentEntries`）+ `task_ledger_section.dart` 重构为分组列表（组头域名+组今日计数小字，聚合不再抢眼）；美学/HCI 依据 = 对账是逐条确认心智（列表直接）、聚合只作健康概览（降级组头）、分组匹配"哪来源"心智且为未来多 server 预留。验证 = analyze 0 + 全量 807 绿
- **测试捕获生产缺陷**：持久目录不存在时首次写入 `PathNotFoundException`（真机首启同发）→ `_flush` 前补 `dir.create(recursive: true)`
- 测试 `test/task/task_consume_ledger_test.dart` +6 例：记账/裁剪/持久化恢复/跨日归零/损坏兜底/清空
- 验证：analyze 0；全量 **801 绿**

## 待办（真机验收）

- 打开 goodhub → goodshare 积压任务被消化（不依赖跨仓通知即可验证 catch-up 地基）
- 签名一致性（goodshare release 走 debug keystore，两包须同签才能 bind `signature` 权限）——若 logcat 见 SecurityException 则先配 keystore
