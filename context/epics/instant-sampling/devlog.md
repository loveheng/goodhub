---
dev-loop: devlog
format: v1
epic: instant-sampling
total-merged: 0
last-merge: none
---
dev-loop: devlog
format: v1
epic: instant-sampling
---

# instant-sampling devlog（goodhub 半边）

## 2026-10-17 T3 分池实施（goodshare 任务书驱动）

- 改动 `lib/mcp/sampling.dart`：① `SamplingQuota` 增 `caps` 档位覆盖表（默认 `{'instant': 60}`，默认池 maxPerWindow=20 不变）；② `tryConsume(serverKey, now, {String? pool})`——pool 白名单判定单点内移（`caps.containsKey`），未登记/空 pool 归默认池，配额 key 派生 `serverKey` / `serverKey:pool`；③ `samplingRequestHandler` 读 params 平级 `pool`（非 String 归默认池）透传；④ -32000 错误消息去掉具体次数（分池超限时默认池数字误导）
- 安全硬化（施工发现）：pool 是 server 不可信输入，直接进 key = 伪造池名每名一池绕过限额 → caps 白名单是唯一分池入口
- snapshotHits/restoreHits 未改（key 为字符串，pool key 自动兼容；conversation_archive 落盘恢复路径无感）
- 挂载点零改动：五处 `SamplingQuota()` 全默认构造（mcp_runtime:551 / gateway_controller:275 / debug_run_orchestrator:299 / conversation_archive:128 / debug_page:120），caps 默认值自动继承
- 测试 `test/mcp/sampling_test.dart` +5 例：默认 caps 口径 / instant 独立计数与互不挤占 / 白名单防伪造 / 分池 per-server 隔离 / snapshot-restore 跨 pool key；handler +2 例：pool 透传分池 / 非 String+未登记归默认池
- 验证：flutter analyze（2 文件）0 issue；sampling_test 14/14 绿；全量 773 绿
- 文档：index.md sampling 行补 pool 分池全口径；本 epic 建立 + CURRENT 绑定
