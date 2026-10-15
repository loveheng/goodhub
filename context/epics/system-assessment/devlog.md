---
dev-loop: devlog
format: v1
epic: system-assessment
total-merged: 0
last-merge: none
---

（开发过程日志按行追加：`- [YYYY-MM-DD] [变更|验证|note|SSOT 修正]: <一句话>`；[变更] 与 [验证] 成对，≥5 条自动归并进 memory.md——dev-loop §2）
- [2026-10-15] [note]: 规划轮——12 条待办定序为 B0 拍板 / B1 决策反向收口 / B2 规范索引 / B3 代码层收尾 / B4 跨 epic 并行，定序注记回填本域 todos.md；待拍板 SA-Q1~Q4 入 `context/pending-confirm.md` (src: agent)
- [2026-10-15] [note]: 事实发现——TC13 双进程未落地（`AndroidManifest.xml:56` `.GatewayForegroundService` 无 `android:process`，与 architecture §11 单进程硬约束同向），thirdconnect.md 该条款属「文档领先代码」而非冲突 (src: agent, manifest 取证)
- [2026-10-15] [note]: B0 拍板销账——Q1=b（只做 Trace-ID/hop_count，余两项 B2 显式关闭）/ Q2=文档规范收口优先、T4 暂缓 / Q3=归档到 `archive/local_model/`（非分支）；归档粒度修正：`llm_model.dart` 被 `llm.dart:5` 引用须保留；新增 SA-Q5（环防护双保险）待确认 (src: 用户, 裁决)
- [2026-10-15] [变更]: B1 止血——新增 `lib/gateway/gateway_loop_guard.dart`（入站 traceId 在途集合引用计数 + `hop_count>0` 闸门 + 上限 2 熔断 + TTL 300s 惰性驱逐 + traceId 自派），接线 `mcp_gateway_handler.dart`（入站判定 / try-finally 必释 / 出站 `params._meta` 平级注入 `traceId`+`hopCount+1`）与 `gateway_server.dart`（读 `X-Mcp-Trace-Id` 优先于 `params._meta`，阻断回 -32000）；新增 `test/gateway/gateway_loop_guard_test.dart` 9 例 (src: agent, SA-Q5)
- [2026-10-15] [验证]: 网关域 23 例全过 / 全量 455 全绿 / `flutter analyze` 仅存量 1 info —— 环防护改动零回归 (src: agent)
- [2026-10-15] [变更]: B1 文档回填——`architecture.md`（定位节 2026-10-12 解冻口径 + 配套四条 / 分期表 M1.5 改已落地 / §11 双进程未落地 / §15 SessionManager 显式关闭含触发条件 / 待拍板清单 +5 条）、`requirements.md`（节首注记重标 + F1.5·1.6·1.8·1.10·1.11·1.12·1.16·1.17 按实现状态重标 + P0 集合销账）、`future-considerations.md` FC6（改「已触发，落地为实时聚合网关」，原待完成队列形态未采用）；三份 updated → 2026-10-15 (src: agent)
- [2026-10-15] [变更]: SA-Q3 归档——`git mv` 端侧模型管理链三件至 `archive/local_model/`（附 README：归档原因 + 复活条件 + 5 步复活步骤），`analysis_options.yaml` 增 `- archive/**`；`lib/llm/llm_model.dart` 被 `llm.dart:5` 引用故保留 (src: agent, 用户裁决)
- [2026-10-15] [验证]: 归档后 `flutter analyze` 1 存量 info 不变、`flutter test --timeout 120s` 455 全绿；archive 已排除分析范围，无编译回归 (src: agent)
- [2026-10-15] [变更]: B2 规范——`coding-standards.md` 四项背离修正（§1 现状扁平域对照 + M4-D4 收敛纪律 / §3 取消通知名改 `notifications/cancelled` 两处 / 规则 1 三处 dart:io 违规临时豁免含整改触发条件 / §6.2 四项门禁落地状态逐条标注），并附修 §7 前提（Server 角色已解冻，本节生效）；updated→2026-10-15 (src: agent)
- [2026-10-15] [变更]: B2 索引——`goodhub-index` 补 `lib/gateway/` 整域 7 行 + `lib/mcp/` 第三波 4 行 + ToolRouter/JIT/RefStore/归档件；修两处失效落点（`lib/doc/rich_text.dart`→外部共享包、`on-device-llm.md` 本仓不存在）；文档落点表补 5 行 (src: agent)
- [2026-10-15] [变更]: B2 事实源——`goodhub-workflow` 技术栈改 M4+ 双角色、模块结构改十域扁平目录（含 gateway/archive）、命令实测状态刷新（455 全绿 / 1 存量 info / release 出包已实测）(src: agent)
- [2026-10-15] [变更]: 文档小项五则——m3 frontmatter draft→active；binder-eval/poc-fix-request 的 `context/epics/goodhub-local-plugin/`（不存在）改投 `context/epics/thirdconnect/`；m4.md rich_text 改共享包表述；architecture「1200T 超限精简模式」由 [x] 改未实现；`context/todos.md` info 行号 :635→:670 (src: agent)
- [2026-10-15] [变更]: m4.md T4 状态注记——整体未落地（backoff/reconnect/订阅零命中）+ 暂缓理由（SA-Q2）+ §5 韧性单测口径保留不删 + M4 收官边界须显式列出 T4 未交付 (src: agent)
- [2026-10-15] [变更]: B3 收编——`lib/mcp/tool_router.dart`（F1.9 海关过滤唯一实现）保留并加文件头未接线注记（原因 + 三项启用前置条件 + 两处接线点），提 SA-Q6；`lib/core/turn_wall.dart` + `test/turn_wall_test.dart` 归档至 `archive/turn_wall/`（被 tool_breaker 取代，lib 零引用）+ README；requirements F1.9 标注「口径已定、实现未接线」 (src: agent)
- [2026-10-15] [变更]: B3 补测 19 例——新增 `test/update/update_service_test.dart` 13 例 + `test/gateway/mcp_gateway_handler_test.dart` 6 例（假传输 `McpTransport` 实现，不触网） (src: agent)
- [2026-10-15] [验证]: 补测咬出两处真实缺陷并修复——① 环判定由 face 查找之后**前置到路由之前**（hop 超深原被「未挂载」掩盖，拿不到 -32000）；② 出站 `_meta` 注入条件由入参 `traceId` 改自派后的 `trace` 并恒注入（入站无 Trace-ID 时兜底线原在第一跳即失效）。修后 `flutter analyze` 1 存量 info、`flutter test --timeout 120s` **471 全绿** (src: agent)
- [2026-10-15] [变更]: B3 补测尾巴——新增 `test/llm/llm_engine_test.dart` 30 例（端侧引擎链：桥协议/降级/约束解码参数/生命周期/探针/SoC）+ `test/gateway/gateway_controller_test.dart` 3 例 + `test/ui/chat_page_smoke_test.dart` 2 例（path_provider 通道 mock + SharedPreferences 官方 mock） (src: agent)
- [2026-10-15] [变更]: B3 第三处缺陷修复——`GatewayServiceChannel._invoke` 补 `on Object` 兜底分支（原只捕 MissingPlugin/PlatformException，「binding 未初始化」类异常会穿透到 `controller.stop()`，与注释「绝不阻断网关起停」不符） (src: agent, 测试咬出)
- [2026-10-15] [验证]: B3 收官——`flutter analyze` 仅存量 1 info（`gateway_loop_debug_page.dart:670`）；`flutter test --timeout 120s` **491 全绿**（补测三轮合计 +36 例：update 13 / handler 6 / llm 30 / controller 3 / chat_page 2，减 turn_wall 归档 3） (src: agent)
- [2026-10-15] [note]: 取证——`RefStore.sweepStartupOrphans` 为实例方法（`lib/coordinator/ref_store.dart:191`），需 cacheDir=getTemporaryDirectory + `gcInterval:null`（不起周期 GC），对账轮 #10 闭环点即 `main.dart` initState (src: agent)
- [2026-10-15] [变更]: 文档同步收口（用户指出「代码已做文档没追上」三类，system-assessment 外溢）——① `m4.md` 删过期待做段（T6-3 元工具/T6-2 装配接线/服务管理 UI/CoW 同步/T6-4 单测已于 2026-10-12 核心接线轮落地，旧「待做」段未随进度删除致与「T6 核心接线进度」段自相矛盾）；② `page-revamp.md` 决策表补 8 项「✓ 已完成」状态列 + 实施状态小结（九轮全清零）；③ `thirdconnect.md` 给 TC9~TC13 + §9.3 加「状态（2026-10-15 对账）」实现标注（TC12 已实现、TC9 部分实现、TC10/TC11/TC13/§9.3 未落地）；updated 同步 2026-10-15；勾掉 system-assessment #11 前半、拆分出「本地插件节点卡 UI 真实缺口」留待排期 (src: agent)
- [2026-10-15] [变更]: M4-T4 复核——用户「同意启动 M4-T4」时核代码发现 **T4-1~T4-5 早已全量落地**（代码+接线+测试 529 绿），此前 system-assessment 断点③ 列「启动 M4-T4」为误判（根因 = 断点滞后于 `m4.md` §5 收官完成注记）。已：SA-Q6 拍板选 a（保留待接线）；`m4.md` 施工分解表 T4 状态改「✓ 已落地」+ 缺口取证/状态注记/收官边界/重启注记四处旧段标注过期；`pending-confirm.md` M4-T4 状态行改「全量落地」；system-assessment 断点③ 改「已完成」、测试数 491→529、列复核后真实遗留。注：本地 `flutter` 不在 PATH，未实跑测试，靠代码审查 + devlog 记录确认 (src: agent)
- [2026-10-15] [变更]: 本地插件节点卡 UI 补齐（thirdconnect 域**真实功能缺口**，非文档滞后）——`services_hall_page` 新增 `_localPluginsPanel` 本地插件面板：渲染 Binder 发现的 `LocalPluginInfo`（标题/serverId、包名、transportId、绿点=已发现）、信任态 pill（同签名私有生态自动信任 / 白名单已信任 / 否则待信任+「信任」按钮触发 `showTrustCard` 信任卡片）、订阅 `localPluginDiscovery.changes` 包变更热刷新；注入位 `localScanOverride`/`localChangesOverride` 保持可测。单测 `test/ui/local_plugins_panel_test.dart` 4 例全绿；`server_nodes_panel_test` 11 项回归无碍；改动文件 `flutter analyze` 0 issue。注意：本地插件按设计「发现即挂、自动挂载」，本次**未加 per-plugin 卸载开关**（仍为独立缺口）。勾掉 system-assessment #11 后半、从断点真实遗留移除该项 (src: agent)
