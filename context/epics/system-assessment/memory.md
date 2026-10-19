---
dev-loop: memory
format: v1
epic: system-assessment
total-merged: 0
last-merge: none
---

# system-assessment

- [挂载] 无独立设计稿；对账结论与行动项落 `context/epics/system-assessment/todos.md`（12 条）

## 结论与决策

- [结论] 2026-10-15 全仓「文档面↔代码层」对账轮（用户发起）：范围 = docs/ 19 篇 + `.agents/skills/` 3 份 + `lib/` 88 dart 十域 + `test/` 56 + `integration_test/` 6；产出 A/B/C 三级脱节清单 + 代码层独立问题 + 综合评估。对账方法：文档侧逐篇提取声明状态，代码侧 grep 级取证落点，双向交叉判「文档有代码无 / 代码有文档无 / 状态不符」
- [结论] **最大脱节 = 决策反向（A1）**：网关 Server 角色已在生产 UI 落地（`lib/gateway/` 6 文件 + ChatPage ⚙「PC 远程网关（:8766）」开关与配对 Token，`chat_page.dart:417-456`；TC5~TC8 于 2026-10-12 拍板），但产品层三文档（`architecture.md` / `requirements.md` / `future-considerations.md`，updated 均停在 2026-10-10~11，早于拍板日）仍判「Server 角色暂缓不做 / 实时 RPC 直调链路整体不建」，且全仓 docs 对 gateway 域零正记载
- [结论] **A1 连带效应（A2/A3）**：A2 三项 P0 原语（SessionManager 会话隔离 / Trace-ID+hop_count 环检测 / 有界队列深度 4+429）原「随 Server 角色挂起」成立，现挂起前提已失效而文档未重裁 → 属**实质风险**（:8766 已对外开放而环检测零实现，暴露先于防护），非纯文档措辞问题；A3 M4-T4 连接韧性（`backoff|reconnect` 全仓 0 命中）未落地而 `m4.md` 状态仍 active 无挂起注记
- [结论] 脱节**集中在「产品层文档 + skill 层」，不在「里程碑设计稿」**：`m4.md` / `stream-perf.md` / `self-update.md` / `local-plugin-access-trust.md` / `thirdconnect.md` 与代码落点吻合度高、实现注记回填及时；失准的是 architecture/requirements/future-considerations（陈旧一整个决策周期）、coding-standards（拓扑/命名/门禁四项背离）、goodhub-index（缺 gateway 域 + 两处失效落点）、goodhub-workflow（停在 M1）
- [结论] 代码层独立问题五宗（与文档无关）：① 端侧模型管理链（`llm_model_manager` 24KB + `llm_download_isolate` + `remote_config_store`）零接线零测试 → F2.3/N5 需求悬空；② 双份 ToolRouter（`mcp/` 孤立仅测试引用 vs `coordinator/` 生产，海关过滤逻辑在孤立那份）；③ `core/turn_wall.dart` 仅测试引用；④ RefStore 启动清池 API 与单测在但未挂 `main.dart`（`main.dart:68` 只清 MemoryStore）；⑤ `chat_page.dart`（60KB 装配中枢）零 widget 测试
- [结论] 质量面实测健康且纪律为真执行：analyze 1 存量 info（`gateway_loop_debug_page.dart:670`）、flutter test **446 全绿**；分层纪律（sandbox 不 import ui / tokens 下沉避免逆向依赖 / `underSupportDir` 收 Directory 构造）、DEGRADE 留痕 48 处、0 个 TODO/FIXME、安全件（PII 围栏 / L1L2 网关 / 熔断 / 原子写 / 信任白名单）代码+单测双落点

## B0 拍板（2026-10-15 用户裁决，已销账）

- [裁决] **SA-Q1 = b**：A2 只做 Trace-ID + hop_count 环检测（止血红线）；SessionManager 会话隔离与有界队列 4/429 判为早产不做——**必须在 B2 显式关闭并写触发条件**（多会话并发 / 网关对外正式分发），否则下次对账会以「脱节」形态复现
- [裁决] **SA-Q2 = 文档规范收口优先**：B1 + B2 + B3 低风险快赢（RefStore 清池闭环）先行，M4-T4 连接韧性暂缓至收口完成；理由 = 先让 SSOT 与代码 1:1 镜像，避免 T4 在旧单向 Client 认知下二次返工
- [裁决] **SA-Q3 = 归档**：端侧模型管理链移出 `lib/`，现阶段不补接线；落点 `archive/local_model/`（仓库内目录 + analysis exclude，非分支）
- [结论] 归档粒度取证修正：`lib/llm/llm_model.dart` 被生产 `lib/llm/llm.dart:5` 引用（`llmModelVisibleOnDevice`），**不在死代码范围**；真正孤岛 = `llm_model_manager.dart` + `llm_download_isolate.dart` + `remote_config_store.dart` 三件互引、零外部引用
- [结论] 环路防护取证（`mcp_gateway_handler.dart:70-131`）：转发经 `face.client.callWithProgress`，`_meta` 不会自动透传下游 → **单靠 hop_count 有失效面**（下游非 goodhub 时回环请求 hop_count 缺省 0）；已提 SA-Q5 建议升级为「入站 Trace-ID 在途集合去重（主防线，纯本地闭环）+ hop_count 递增上限 2（跨网关深度兜底）」双保险

## B1 实施（2026-10-15，止血 + 文档回填 + 归档）

- [结论] **环防护判据定稿（对 SA-Q5 的落地修正）**：主防线 key **不用 `traceId+reqId`**——回环请求由下游重新发起、JSON-RPC id 多为新值，拿 reqId 参与 key 会漏判。改用 **「traceId 在途集合（引用计数）+ `hop_count>0` 闸门」**：平级并发（PC 一轮多 call 复用同一 Trace-ID）入站 hop 缺省 0 → 永不误杀；嵌套回环（hop≥1 且同 traceId 在途）→ 拦截。不依赖下游透传任何字段
- [结论] **TTL 取 300s 且走惰性驱逐（无 Timer）**：覆盖 TC12 的 45s 确认窗 + 长任务；到期只失去保护（漏判）不会误杀，故取宽不取紧；惰性 sweep 挂在 `acquire`/`checkInbound`，测试零 pending timer
- [变更] 落点：新增 `lib/gateway/gateway_loop_guard.dart`（在途集合引用计数 / hop 上限 2 / TTL 300s / traceId 自派）；`mcp_gateway_handler.dart` 入站判定 + `try/finally` 必释 + 出站 `params._meta`（与 name/arguments 平级）注入 `traceId`+`hopCount+1`；`gateway_server.dart` 读 `X-Mcp-Trace-Id`（Header 优先于 `params._meta`），阻断回 JSON-RPC **-32000**（SSE 模式亦以标准 error 帧收尾）
- [变更] 文档回填（决策反向收口）：`architecture.md`（定位节改 2026-10-12 解冻口径 + 配套状态四条 / 分期表 M1.5 改已落地 / §11 双进程未落地注记 / §15 SessionManager 显式关闭含触发条件 / 待拍板清单补 5 条）；`requirements.md`（节首注记重标 + F1.5·1.6·1.8·1.10·1.11·1.12·1.16·1.17 按实现状态重标 + P0 集合销账）；`future-considerations.md` FC6 改「已触发，落地为实时聚合网关（原待完成队列形态未采用）」；三份 updated 升 2026-10-15
- [变更] SA-Q3 归档：`git mv` 端侧模型管理链三件 → `archive/local_model/`（`README.md` 写归档原因 + 复活条件 + 5 步复活步骤），`analysis_options.yaml` 增 `- archive/**`；`lib/llm/llm_model.dart` 因被 `llm.dart:5` 引用**保留在 lib**
- [待办] 候选补强（未做，待排）：**自环端点防呆**——远端 server URL 的 host 属本机且 port == 网关端口时拒绝挂载/调用，比 trace 判定更直接（零依赖、5 行级）；是否做随 B2 一并定

## 近期验证状态

- flutter analyze 0 新增（存量 1 info，行号 :670 —— `context/todos.md` 记 :635 已漂移）；flutter test --timeout 120s **446 例全绿**（stream-perf memory 记 442，self-update memory 记 446，一致）
- 对账证据可复查：A1 见 `chat_page.dart:417-456` 与 `docs/product/architecture.md:17`；A2 见 lib/ 与 android/ 对 `SessionManager|traceId|hopCount` 零命中（仅 `mcp_client.dart:62` 注释）；A3 见 lib/ 对 `backoff|reconnect` 零命中；B2 见 `lib/ui/` 三处 `dart:io` 违规
- 未验证假设：A2 三项是否随网关解冻**需用户拍板**（本次只取证未裁决）；thirdconnect 未落地条款（`mcp-blob://` / stdio / 200ms 节流 / 双进程）是否为有意裁剪待确认

## B2 实施（2026-10-15，规范/索引/文档小项收口）

- [结论] **四项背离已修**（`coding-standards.md`）：① §1 补「目标拓扑 vs 现状扁平域目录」对照与 M4-D4 收敛纪律（新增文件沿用现状，禁双拓扑）；② §3 取消通知名 `$/cancelRequest` → 规范名 `notifications/cancelled`（两处）；③ 规则 1「ui/ 禁 dart:io」三处违规（`chat_page.dart:12` / `services_hall_page.dart:19` / `update_page.dart:1`）给**临时豁免 + 整改触发条件**（`lib/platform/` 抽象层建立时改注入，此前禁新增第四处）；④ §6.2 四项集成门禁逐条标落地状态（环检测已落 / Abort 顺序缺断言 / 重连不重放随 T4 暂缓 / `$ref` 清理已闭环）；**附带修正 §7 前提**——Server 角色已解冻，本节全面生效（约束网关可达工具面）
- [结论] **索引层已补**（`goodhub-index`）：新增 `lib/gateway/` 整域 7 行（server/handler/controller/security/loop_guard/backpressure + 原生件）、`lib/mcp/` 第三波 4 行（local_plugin_discovery / trusted_plugins+信任卡片 / sampling / transport+Binder）、ToolRouter·JIT、RefStore、归档件（注明 `archive/local_model/` 非 lib 代码）；修正两处失效落点（`lib/doc/rich_text.dart` → 外部共享包 `/home/zzh/app/rich_text/`；`on-device-llm.md` 本仓不存在 → goodshare 仓）；文档落点表补 5 行
- [结论] **workflow 事实源已更新**：技术栈由「M1 最小壳」改 **M4+ 双角色**（Client 多 Server + Gateway :8766 均已落地）；模块结构由三目录改**十域扁平目录**（含 `lib/gateway/`、`archive/`）；命令实测状态更新（455 全绿 / 1 存量 info / release 出包已实测 / 无模拟器）
- [结论] **m4.md T4 状态注记**：T4 整体未落地（`backoff|reconnect` 零命中、`server_probe` 只是按需探活、订阅消费无实现），暂缓理由 = SA-Q2；**§5「韧性单测」口径保留不删**（禁以删需求销账），并确立 M4 收官边界——转 active(收官) 时须显式列出 T4 未交付
- [结论] **文档小项五则已清**：m3 frontmatter draft→active；binder-eval / poc-fix-request 的 `context/epics/goodhub-local-plugin/`（不存在）改投 `context/epics/thirdconnect/`；m4.md 的 `lib/doc/rich_text.dart` 改共享包表述；architecture 待拍板项「1200T 超限精简模式」由 `[x]` 改**未实现**（现靠 `use_server` 聚焦人工规避）；`context/todos.md` 存量 info 行号 :635→:670

## B3 实施（2026-10-15，代码层收尾）

- [结论] **双份 ToolRouter 性质不同，处置必须分开**：`lib/mcp/tool_router.dart` 是 **F1.9（P0）海关过滤的唯一实现**，未接线是**有意裁剪**（现网服务端普遍不下发 annotations，启用即全量过滤、生产功能归零）→ **保留 + 文件头标注**（未接线原因 + 三项启用前置条件 + 接线点两处），提 SA-Q6 拍板；`lib/core/turn_wall.dart` 是**被 `tool_breaker.StepWallReport` 取代的真死代码** → 连其单测一并归档至 `archive/turn_wall/`（`lib/` 对 `TurnWall` 零引用）
- [结论] **补测立刻咬出两个真实缺陷（补测价值实证）**：① 环判定原在 `face` 查找之后 → hop 超深的请求被「服务未挂载」掩盖，拿不到 -32000；已**前置到路由之前**（协议级错误优先于业务路由，且阻断路径不查注册表）。② 出站 `_meta` 注入条件用入参 `traceId` 而非自派后的 `trace` → **入站无 Trace-ID 时第一跳就丢深度信息，兜底线形同虚设**；已改恒注入
- [变更] 新增单测 19 例：`test/update/update_service_test.dart` 13 例（更新源解析与回退 / 非法 URL / 清单 URI 归一 / 未配置源拒更 / 清单拉取与非 200 / 本地回环下载 sha256 一致与篡改拒绝 + 半成品清理 + 进度终帧）；`test/gateway/mcp_gateway_handler_test.dart` 6 例（入站校验 / 同 traceId 在途阻断且**未转发** / hop 超限阻断 / 剥前缀转发 + `_meta` 平级注入与递增 / 自派 traceId / 下游异常仍释放在途记录），均用假传输实现（`McpTransport`）不触网
- [结论] **补测尾巴已完成（B3 收官）**：端侧引擎链 `test/llm/llm_engine_test.dart` 30 例（桥协议映射 / 空产出与桥缺失一律降级 null / 约束解码参数映射 / 生命周期透传 / 探针 null / SoC 可见性）；`test/gateway/gateway_controller_test.dart` 3 例（初始态 / stop 幂等 / LAN 地址 DEGRADE 口径）；`test/ui/chat_page_smoke_test.dart` 2 例（首屏装配 + 输入区可写，用 path_provider 通道 mock + SharedPreferences 官方 mock）
- [结论] **第三处缺陷（补测咬出）**：`GatewayServiceChannel._invoke` 只捕 `MissingPluginException` / `PlatformException`，而「binding 未初始化」抛的不是这两类 → 异常穿透到 `GatewayController.stop()`，与文件注释「绝不阻断网关起停」不符；已补 `on Object` 兜底分支（2026-10-15）
- [结论] **可测性注记**：`ChatPage` 构造无参、无 store/engine 注入位，依赖面只能走平台 mock → 现阶段只做冒烟（钉住「首屏装配不崩」）。若要升级为发送链路交互测试，须先为其加注入位（与 `services_hall_page` 的 `byokStoreOverride`/`endpointStoreOverride` 同款写法）
- [待办] 无（B3 收官）。剩余全局项：SA-Q6 拍板 / #11 thirdconnect 条款标注 / M4-T4 连接韧性

## 归并补充（2026-10-19 · 自 devlog 20 条提炼，memory 此前缺失项）

- **B1 止血落地**：`lib/gateway/gateway_loop_guard.dart`（入站 traceId 在途集合引用计数 + `hop_count>0` 闸门 + 上限 2 熔断 + TTL 300s 惰性驱逐 + traceId 自派），接线 `mcp_gateway_handler.dart`（入站判定 / try-finally 必释 / 出站 `params._meta` 平级注入 traceId+hopCount+1）与 `gateway_server.dart`（读 `X-Mcp-Trace-Id` 优先于 `params._meta`，阻断回 -32000）；`test/gateway/gateway_loop_guard_test.dart` 9 例。
- **B2 三项**：`coding-standards.md` 四项背离修正（§1 现状扁平域对照 + M4-D4 收敛纪律 / §3 取消通知名 `notifications/cancelled` / 规则 1 三处 dart:io 临时豁免含整改触发条件 / §6.2 四项门禁落地状态）+ 修 §7 前提（Server 角色已解冻）；`goodhub-index` 补 gateway 整域 7 行 + mcp 第三波 4 行 + 修两处失效落点（`lib/doc/rich_text.dart`→外部共享包、`on-device-llm.md` 本仓不存在）+ 文档落点表 5 行；`goodhub-workflow` 技术栈改 M4+ 双角色、模块结构改十域扁平目录、命令实测状态刷新。
- **文档同步收口（用户指出「代码已做文档没追上」三类）**：`m4.md` 删过期待做段（与「T6 核心接线进度」自相矛盾）；`page-revamp.md` 决策表补 8 项「✓ 已完成」状态列 + 实施状态小结；`thirdconnect.md` 给 TC9~TC13 + §9.3 加「状态（2026-10-15 对账）」标注（TC12 已实现、TC9 部分、TC10/TC11/TC13/§9.3 未落地）。
- **本地插件节点卡 UI 补齐（thirdconnect 域真实功能缺口，2026-10-15）**：`services_hall_page` 新增 `_localPluginsPanel`——渲染 Binder 发现的 LocalPluginInfo（标题/serverId/包名/transportId/绿点）、信任态 pill（同签名自动信任 / 白名单已信任 / 待信任+按钮触发 showTrustCard）、订阅 `localPluginDiscovery.changes` 热刷新；注入位 `localScanOverride`/`localChangesOverride` 保持可测；单测 4 例全绿 + server_nodes_panel 11 项回归无碍。**未加 per-plugin 卸载开关**（仍为独立缺口）。
- **取证两则**：① `RefStore.sweepStartupOrphans` 为实例方法（`lib/coordinator/ref_store.dart:191`），需 cacheDir=getTemporaryDirectory + `gcInterval:null`（不起周期 GC），对账 #10 闭环点 = `main.dart` initState；② TC13 双进程未落地（`AndroidManifest.xml:56` `.GatewayForegroundService` 无 `android:process`，与 architecture §11 单进程硬约束同向），thirdconnect.md 该条款属「文档领先代码」而非冲突。

## 近期验证状态（B1 后）

- `flutter analyze` 全仓仅存量 1 info（`gateway_loop_debug_page.dart:670` deprecated_member_use，pre-existing；archive 已排除不新增）；`flutter test --timeout 120s` **455 全绿**（446 + 环防护新增 9；网关域 23 例）
- 归档无回归：`git mv` 三件后 analyze/测试计数不变，验证「零外部引用」取证成立

## 断点
- [断点] ~~B0/B1/B2/B3~~ → **B3 已完成（2026-10-15）**，测试 **529 全绿**（含 M4-T4 新增 +38，见 m4.md §5）。**① ~~SA-Q6 拍板~~**（**已拍板 2026-10-15，选 a 保留待接线**：`lib/mcp/tool_router.dart` 待 SDK 发 annotations 后按文件头条件接线、合并入 `coordinator/tool_router.dart` 记为 #9 补强）· **② ~~#11 thirdconnect 条款标注~~**（**已完成 2026-10-15**，§9.3/§10.1~§10.5 状态块）· **③ ~~启动 M4-T4~~**（**M4-T4（T4-1~T4-5）已于 2026-10-15 收官完成**——代码+接线+测试 529 绿，见 m4.md §5，仅剩真机验收 + D20 goodshare 契约回写）。**当前真实遗留（2026-10-15 复核，剔除已误列项）**：T6 已激活 Schema 1200T 精简模式（未实现）/ 本地插件 **per-plugin 卸载开关**（未实现；节点卡 UI 面板已于 2026-10-15 补齐——渲染/信任态/订阅热刷新，见「归并补充」节）/ reverseDemo 推理闭环（环境未就绪）/ thirdconnect `readOnlyHint` 注解（未实现）/ self-update 真机验证 / 各 epic 设备端 UI 冒烟 / §16 门槛校准拍板 / 自环端点防呆（候选）。**候选补强**：① #9 孤立实现收编（`lib/mcp/tool_router.dart` 保留待接线，merge 入 `coordinator/tool_router.dart` 待 SDK annotations 就绪）；② #7 零测试面补测——`chat_page` widget / `gateway_controller`·`mcp_gateway_handler` / `update_service`·`installer` / 端侧引擎链。**候选补强（待定）**：自环端点防呆（远端 server URL 指向本机 :8766 时拒挂载/调用）。
