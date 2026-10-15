---
memo: todos
format: v3
epic: system-assessment
---

# system-assessment · 域内待办

> 2026-10-15 全仓「文档面↔代码层」对账产出（结论与证据见 `memory.md`）。
>
> **批次定序（2026-10-15 规划轮）**：`B0` 拍板（SA-Q1~Q3，见 `context/pending-confirm.md`，阻塞 B1）→ `B1` 决策反向收口（#1~#3，P0 止血）→ `B2` 规范/索引/文档小项（#4~#6 + #11 + #12，P1）→ `B3` 代码层收尾（#7~#10，P2，按风险升序：#10 清池闭环 → #9 孤立收编 → #8 端侧链（待 Q3）→ #7 补测）→ `B4` 跨 epic 并行主线（self-update 真机 / thirdconnect 遗留 / M4 T4·T6 余项），不占同一条开发节奏。

- [x] [2026-10-15] (文档) (重:中) 回填产品层三文档的网关裁决：`architecture.md`（定位节 / §1 / §11 / §13 / 分期表 M1.5 行）、`requirements.md`（F1.5/F1.6/F1.8/F1.11/F1.12/F1.16/F1.17 由「挂起」改解冻或重标状态）、`future-considerations.md` FC6（改「已触发并按 TC5~TC8 落地」）——依据 `context/pending-confirm.md` TC5~TC8（2026-10-12），当前三份 updated 停在拍板日之前 (src: agent, 对账轮 A1)
- [x] [2026-10-15] (风险) [long] (重:中) 网关 `:8766` 已生产对外开放（ChatPage ⚙ 开关 + Token）而 Trace-ID / hop_count 环路防护在 lib/ 与 android/ 零实现（仅 `mcp_client.dart:62` 注释引用）→ 二选一：落入站链路，或在文档写明「网关不开放级联调用」的风险注记；当前属暴露先于防护 (src: agent, 对账轮 A2)
- [x] [2026-10-15] (风险) [long] (重:中) 重裁 A2 余两项 P0 原语的挂起前提：SessionManager 会话隔离（无具名类，态散在 `chat_page`/`gateway_server`/`skill_registry`）与有界队列深度 4 + 429 仲裁（无；现只有 `gateway_backpressure` 并发信号量，语义不同）——原「随 Server 角色挂起」因网关落地已失效，需拍板解冻还是显式关闭 (src: agent, 对账轮 A2)
- [x] [2026-10-15] (文档) (重:轻) M4-T4「连接韧性」未落地且 `m4.md` 无状态注记：lib/ 对 `backoff|reconnect` 零命中（现有 `server_probe` 仅按需探活）→ 回填「未落地 + 理由」并标注 M4 收官边界，含 §5 验收口径「韧性单测」的去留 (src: agent, 对账轮 A3)
- [x] [2026-10-15] (文档) (重:中) `coding-standards.md` 四项背离修正：§1 目标拓扑（`lib/app|core|features|platform`）补「现状扁平域目录 vs 目标拓扑」对照（m4-D4 已拍板后续收敛）；§3 `$/cancelRequest` 改 `notifications/cancelled`（代码已改、`agent_loop.dart:191` 注释残留旧名）；规则 1「ui/ 禁 dart:io」违规清单给豁免或整改（`chat_page.dart:12` / `services_hall_page.dart:19` / `update_page.dart:1`）；§6.2/6.3 四项集成门禁缺位标注 (src: agent, 对账轮 B2)
- [x] [2026-10-15] (文档) (重:中) skill 层陈旧两处：`goodhub-index` 补 `lib/gateway/` 整域与 `lib/mcp/` 第三波（`local_plugin_discovery` / `trusted_plugins` / `sampling` / binder transport），并修正两处失效落点（`lib/doc/rich_text.dart` 已改外部 path 包 `../rich_text`、`docs/design/on-device-llm.md` 本仓不存在）；`goodhub-workflow` 由「M1 最小壳 / mcp+llm+ui+android」更新到 M4+ 十域 88 dart (src: agent, 对账轮 B1/B3)
- [x] [2026-10-15] (测试) (重:重) 零测试面补测 **剩余**：`chat_page.dart`（60KB 装配中枢）零 widget 测试、`gateway_controller` 零单测、端侧引擎链（`llm.dart` ChannelLlmEngine）零测试——**已完成（2026-10-15）**：`update_service` 13 例（`test/update/update_service_test.dart`：源解析/清单拉取/流式下载 sha256 校验成功与篡改/进度/半成品清理）+ `mcp_gateway_handler` 6 例（`test/gateway/mcp_gateway_handler_test.dart`：入站校验/环阻断/`_meta` 注入/失败路径释放）；`installer` 依赖 open_filex 平台通道，单测收益低，留真机验证 (src: agent, B3)
- [x] [2026-10-15] (优化) (重:中) 端侧模型管理链死代码处置：`llm/llm_model_manager.dart`（24KB）+ `llm_download_isolate.dart` + `remote_config_store.dart` 零接线零测试，使 F2.3/N5「端侧模型按需下载」实为未交付 → 要么接线（补下载 UI + 单测）要么移出 lib 归档，不留半截 (src: agent, 对账轮)
- [x] [2026-10-15] (优化) (重:轻) 孤立实现收编：双份 ToolRouter（`mcp/tool_router.dart` 仅测试引用，海关过滤 `x-mcp-export-to-shared` 在其中）并入生产的 `coordinator/tool_router.dart`；`core/turn_wall.dart` 仅测试引用（步数墙实际走 `tool_breaker.StepWallReport`）一并处置 (src: agent, 对账轮)
- [x] [2026-10-15] (修复) (重:轻) RefStore 启动清池未闭环：`sweepStartupOrphans` API 与单测在，但 `main.dart:68` 只清 MemoryStore → 挂启动流程，对上 §9「启动幂等清池」与 `test/coordinator/ref_store_test.dart:125` (src: agent, 对账轮)
- [x] [2026-10-15] (文档) (重:轻) `thirdconnect.md` 未落地条款补状态标注（与代码逐条对账）：TC9 `$ref` 部分实现/`mcp-blob://` 数据面未落地、TC10 Dual-Stack stdio 未落地、TC11 200ms 节流未落地、TC12 已实现、TC13 双进程未落地、§9.3 冲突后缀降级未落地 —— 已在 §9.3 / §10.1~§10.5 加「状态（2026-10-15 对账）」块 (src: agent, 对账轮 #11 前半)
- [x] [2026-10-15] (风险) (重:轻) 本地插件节点卡 UI 未落地：`services_hall_page._nodesPanel` 只列远端 HTTP 端点，不列 Binder 发现的本地插件（与 binder-eval §5 缺口一致）——属 thirdconnect 域**真实功能缺口**（非文档滞后），待排期 (src: agent, 对账轮 #11 后半) → **已落地（2026-10-15）**：`services_hall_page` 新增 `_localPluginsPanel` 本地插件面板（Binder 发现项渲染 + 信任态 pill + 信任卡片入口），单测 `test/ui/local_plugins_panel_test.dart` 4 例全绿；**per-plugin 卸载开关仍为独立缺口**（见下方）
- [x] [2026-10-15] (文档) (重:轻) 文档小项清理五则：`m3-ui-subs-sampling.md` frontmatter 仍 draft（T5 已收官，`m4.md:31` 自己点名过）；binder-eval / poc-fix-request 引用不存在的 `context/epics/goodhub-local-plugin/`；`m4.md:52` 仍写 `lib/doc/rich_text.dart`；`architecture.md` 待拍板项标 `[x]` 的「已激活 Schema 预算 1200T 超限精简模式」代码未实现（`m4.md` §T6 剩余自注）；`context/todos.md:10` 记的 deprecated info 行号 :635 已漂移至 `gateway_loop_debug_page.dart:670` (src: agent, 对账轮)
