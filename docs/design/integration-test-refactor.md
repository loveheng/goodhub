---
status: active
updated: 2026-11-09
---

# integration_test 联调层改造（通用接入解耦）

## 1. 背景与问题

goodhub 是通用 AI 宿主（任意 App 经 MCP/SDK 接入），但 `integration_test/` 现有 8 个真机 e2e 中 3 个把对端钉死在 goodshare：

- `goodshare_binder_e2e_test.dart` / `goodshare_toolrouter_e2e_test.dart`：断言主体是 goodhub 自身装配能力（bind 状态机、ToolRouter 隔离、JIT 发现），但前置依赖「goodshare 同 debug keystore 同批安装」；
- `goodshare_wal_e2e_test.dart`：并发压测的是 goodshare.db 写路径，断言主体是对端 App——**归属错位**。

按此模式每接入一个新 App 都要在 goodhub 仓留一份联调测试，不可扩展。

## 2. 判定式（落点裁决）

> 断言 goodhub 内部行为 → goodhub 仓 `test/` / `integration_test/`；
> 断言契约互通 → goodhub-mcp-sdk 仓 conformance 套件；
> 断言对端 App 内部行为 → 对端仓。

## 3. 改造分解

### R1 goodshare_wal_e2e 外迁（goodshare 仓）——✅ 2026-11-09 已落地

已迁移：goodshare 仓 `integration_test/goodshare_wal_e2e_test.dart`（进程内直调 `callTool('add_item')` 压 WAL 写路径，隔离测试库 `goodshare_itest.db`）；goodhub 侧旧文件已删除。

### R2 白盒 e2e 对端换标准参照插件（goodhub 仓）——✅ 2026-11-09 已落地

`goodshare_binder_e2e` → `dummy_binder_e2e_test.dart`、`goodshare_toolrouter_e2e` → `dummy_toolrouter_e2e_test.dart`（对端 = sample-dummy-plugin，serverId=`dummy`，短工具 echo）；ai_complete_e2e callerKey 改中性 `com.example.e2e.caller`（M5 寻址语义不变）。命令清单同步 `goodhub-workflow` skill。

### R3 SDK 仓 conformance 套件（goodhub-mcp-sdk 仓，跨仓）——✅ 2026-11-09 已落地

套件 = SDK 仓 `conformance/`（`run.py` + `configs/{dummy,goodshare}.json` + README），真机实证：dummy 正向 6/6 过、goodshare 负样本 4/4 过。形态：

- **PC 侧 JSON-RPC 驱动**，两级网关就绪模式：`probe`（自动拉起 goodhub 仓 `gateway_external_probe` + adb forward，需 `goodhub_repo` 路径）/ `direct`（外接已起网关 host:port）；
- **断言面四项**：① initialize 握手；② 聚合目录 SHARED 工具可见（default-deny 海关正向）；③ 目录 PRIVATE 工具不可见（default-deny 负向钉）；④ SHARED 工具 tools/call 真调通；
- **薄配置**（每接入方一份 `configs/<app>.json`）：package / server_id / expect_shared_tools / forbid_tools / call_probe（tool + arguments）；`expect_shared_tools: []` + 全 forbid = 旧式全 PRIVATE 插件的负样本形态；
- **blob 分片不进套件**：`mcp-blob://` 契约未落地（ai-app-split §3 二期），留扩展点；
- sampling 反向列入二期断言（依赖宿主 wireSampling 接线，先保四项稳定）。

### R4 观测面固化（goodhub 仓）——已定稿 2026-11-09

观测面三层各自在场，固化 = 登记为**对外联调标准通道 SSOT**，杜绝「来一个接入方就在好仓留一个探针文件」：

| 层 | 载体 | 联调职责 |
| --- | --- | --- |
| 协议断言 | SDK 仓 `conformance/`（R3 产出） | 接入方机械验收唯一出处（A1-A4） |
| 网关通道 | goodhub `integration_test/gateway_external_probe_test.dart` | **非断言探针**（NON-TEST 身份）：装配 faces + 起网关 0.0.0.0:8766 保活 120s，供 PC `adb forward` + conformance probe 模式驱动；禁当回归用例跑 |
| 结构化观测 | `toolbox run debug-bridge`（`/debug/state` 含 onDeviceTasks 锚） | AI 自驱联调观测（状态/日志/UI 树），替代截图猜坐标 |

消费侧指针：接入方联调入口 = SDK 仓 `AI_ONBOARDING.md`（真机验证步骤指向 conformance）；接缝裁决 = goodshare `ai-app-split.md` §10。

## 4. 红线

- R3 涉接缝须同轮修 goodshare 仓 `docs/design/ai-app-split.md`；
- 覆盖 contract 层行为先改 goodhub-mcp-sdk 契约仓 `:contract`；
- 验证分层纪律（coding-standards §8.1）不放松：R2 仍是第②层真机 e2e。

## 5. 验收口径

1. goodhub `integration_test/` 内不再有文件名/前置钉死具体第三方 App 的用例；
2. 新接入方联调 = SDK 仓加一份薄配置 + 装对方 App，零 goodhub 仓测试代码改动；
3. `flutter analyze` 0 issue + 既有测试基线不劣化。

## 决策日志

（空，随施工追加）
