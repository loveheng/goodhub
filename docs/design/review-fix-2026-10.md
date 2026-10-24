---
status: active
updated: 2026-10-24
---

# 全项目审查修复（2026-10-24 轮）

> 2026-10-24 全项目审查轮（6 域深审 + 安全专项 + 设计账实评审）产出的修复施工稿。
> 范围 = 审查发现的 P0/P1 代码缺陷 + 安全落盘卫生 + 门禁矩阵账实修正；P2 择要挂尾。
> 完成态判定 = 本表各项「验收」列全过 + `flutter analyze` 0 issue + 全量 `flutter test` 全绿。
>
> **状态（2026-10-24）**：F1-F18 + P2 评估 A 批 13 项（含 F19）+ B 批 2 项全部落地（实施明细见 epic devlog）。F9 验收降级为「镜像 _heartbeatPing 已测形态」（死连接同步抛不可用真实 socket 确定性复现，无自动钉子）；F3 含语义变更（见 epic memory SSOT 条）；拍板①②见 epic memory 显式决策。遗留：B 档剩余 6 项按触发条件择机、C 档 3 项观察。

## P0（用户数据保护实际失效）

| # | 缺陷 | 落点 | 修法 | 验收 |
|---|---|---|---|---|
| F1 | PopScope 拦截失灵：`canPop: !_status.running` 只在页面级 build 求值，运行态翻转只通知 body 内 ListenableBuilder → 首 Run 期间 canPop 恒 true，确认弹窗常见路径不出现 | `lib/ui/chat_page.dart`（PopScope 处） | 把运行态 ListenableBuilder 上提到 PopScope 消费层（canPop 随 status 重建） | widget 测试：Run 进行中触发返回手势 → 出确认弹窗（不直接 pop） |

## P1 · 资源收尾（关闭链不彻底）

| # | 缺陷 | 落点 | 修法 | 验收 |
|---|---|---|---|---|
| F2 | `close()` 不停 GET SSE 监听循环 → 关闭后对死 transport 无限退避重连，每次断连泄一个 McpClient | `lib/mcp/mcp_client.dart` | `close()` 内补 `stopNotificationListener()`；close 幂等语义不变 | 单测：close 后监听循环退出（无残留 timer/轮询） |
| F3 | 装配失败路径 client 泄漏：`negotiate()`/`face.listTools()` 抛错时 client 既不在 partialClients 也不 close | `lib/coordinator/mcp_runtime.dart`（端点循环 + 本地插件循环） | 循环内 try/catch：失败即 `client.close()` 再通告/continue；对齐 `mountEndpoint` 既有正确形态 | 单测：坏插件/negotiate 抛错时 client.close 被调（注入 fake 计数） |
| F4 | 联调 Run 泄 client：`mount` 未传 `release` | `lib/coordinator/debug_run_orchestrator.dart` | mount 时传 release 闭包（close 交还装配器统一释放） | 现有 debug orchestrator 单测补释放断言 |

## P1 · 事务与竞态

| # | 缺陷 | 落点 | 修法 | 验收 |
|---|---|---|---|---|
| F5 | `activate_server_tools` 直写 `router.activePrivateServerId`，旁路 requestSlot 提交点事务，与 `use_server` 语义分裂 | `lib/coordinator/discovery_executor.dart` | 改走与 `use_server` 相同的 pending slot + commit 通道 | 单测：提交前 abort 槽位不变（对齐 use_server 既有用例） |
| F6 | `_send` 双发竞态：判 running 后经两个 await 才 beginRun，双击 = 两个并发 Run | `lib/ui/chat_page.dart` | 发送闩（`_sending` 置位提前到 await 之前，finally 复位） | widget 测试：连击发送仅产生一个 Run |
| F7 | 信任白名单读改写无互斥 + 单例 `??=` 跨 await 非原子：撤销信任可被并发写复活 | `lib/mcp/trusted_plugins.dart` | 写路径串行化（队列/互斥 future 链）+ 单例构造原子化（同步 cache） | 单测：并发 add/remove 交错后最终态正确（remove 不被旧快照覆盖） |
| F8 | 任务消费循环 dispose 不中断在途轮次，对已断通道继续 claim/apply | `lib/task/task_consume_loop.dart` | do/while 每步检查 `_disposed`；`isChannelAlive` 单步间复查 | 单测：dispose 后不再发起 claim（fake 计数） |

## P1 · 网关

| # | 缺陷 | 落点 | 修法 | 验收 |
|---|---|---|---|---|
| F9 | `_broadcastListChanged` 遍历 `_sseSubs` 未拷贝且无包裹：死连接同步抛 StateError 中断整轮，后续订阅者丢 `tools/list_changed` | `lib/gateway/gateway_server.dart` | 与 stop()/heartbeat 同形态：遍历副本 + 单订阅者 try/catch | 单测：一个死订阅者不阻断其余订阅者收到广播 |
| F10 | idle GC 重建 handler 静默回退连接投影（`gateway__select_private` 只改 handler 实例，会话快照 final） | `lib/gateway/gateway_server.dart` + `mcp_gateway_handler.dart` | 投影策略变更写回会话条目（非 final 化 / 重建时透传），重建后策略保持 | 单测：select_private → idle GC 逐出 → 再请求，投影仍为所选项 |

## P1 · 安全落盘卫生

| # | 缺陷 | 落点 | 修法 | 验收 |
|---|---|---|---|---|
| F11 | 网关 Token 明文落 SharedPreferences（`gateway.token`） | `lib/ui/sections/gateway_section.dart` | 迁 SecureKeyValue（`gateway.token` 迁移读旧删旧） | 单测：token 不再写 prefs；旧值迁移后清除 |
| F12 | 旧 MCP apiKey 迁移后永久滞留明文 prefs（`chat.mcp.apiKey`） | `lib/mcp/server_endpoints.dart` | 迁移成功后删除旧键（失败保留待下次重试） | 单测：迁移后旧键不存在 |
| F13 | 信任白名单只查包名，不复核签名指纹（记录的 sha256 无消费点）→ 同包名不同签名免信任卡挂载 | `lib/mcp/trusted_plugins.dart` + 挂载判定处 | `isTrusted` 入参加签名指纹，比对记录值；不匹配 = 不信任 | 单测：同包名异签名 → 不信任 |
| F14 | 自更新：sha256 可空、http 源放行、apkUrl 未限 https | `lib/update/update_manifest.dart` + `update_service.dart` | 清单校验强制 https + sha256 必填（缺失即拒） | 单测：http 源/缺 sha256 拒绝 |

## 设计与门禁（账实修正）

| # | 事项 | 落点 | 说明 |
|---|---|---|---|
| F15 | §1.0 分层矩阵 `app/`/`gateway_api/` 行失真修正 | `docs/project/coding-standards.md` | app 行补 task/coordinator 出向；gateway_api 行补 mcp（gateway_control 现状）——先账实对齐 |
| F16 | 正向依赖白名单机械化：dependency_rules_test 补「域 → 允许出向」正向枚举 | `test/architecture/dependency_rules_test.dart` | 现规则表是坏边黑名单，新文件落错域不报警；正向枚举落地后 §1.0「持续守护」承诺才成立 |
| F17 | host-tools-gateway-export.md `status: draft → active` | 该文档 frontmatter + README | 机制已全量落地（债 #15/#19 已结项） |
| F18 | drift-guard 裸命令假绿（root 解析到全局池，项目 registry 不被扫） | 全局工具仓（移交） | 本仓侧动作 = workflow skill 文档改为显式 `--root`；根治在 meta-upgrade 域（引擎 root 默认 cwd） |

## P2 择要（2026-10-24 评估轮分档：A 批已全部落地；B/C/D 结论见各行标注）

- 【D 档·已否决】`CHANGE_WIFI_STATE` 权限「略超需」——**评估实证否决**：该权限是 Android 14 `connectedDevice` 前台服务 WifiLock 的 precondition（`GatewayForegroundService.kt:20` 注释已立法），安全审查此条判断有误，从清单剔除
- 【升 P1·并入 A 批·已落地】F19 连接中 abort 空操作（落地 S 方案：chat_page `_pendingAbort` + 赋值点补发，未动内核；assemble 取消管道 = M 根治留待触发）
- `streaming_rich_text.dart` 长流 O(n²)（每次 flush 全文正则扫描）【B：先加基准量化，有卡顿实证再修】
- 背压 per-connection（N 连接同 server 并发 4N）+ 队列无界；LRU 逐出不豁免活跃 SSE 订阅
- full/pruned 入站不做 isProjected 校验【**已拍板 2026-10-24：pruned 补边界校验；full 显式保持目录-only**（visibility 非 ACL 与 §1.1 规则 7 一致，裁决记录须同轮回写 host-tools-gateway-export.md；见 epic memory 拍板②）】；§6.2 主体矩阵未落地（ops 不记 actor）
- `server_probe` 工具计数不分页；`json_rpc` string id 抛裸 TypeError；`agent_loop` 无重入守卫；`ref_store` id 注释 128-bit 实际 64-bit；`goodshare_task_api` version_conflict 重试注释漂移
- UI 零散：`_pendingResources` 跨会话残留、`beginRun` 绕过 `setAutoFollow`、`gateway_consent_dialog` 硬编码字号、重命名弹窗 controller 未 dispose
- 超标件：chat_page 1469 行（仍在涨，破「只减不增」轨迹）、dual_track_stream 1411 行
- Bearer 非恒时间比较【升入 A 批 A13】；免鉴权 + 0.0.0.0【**已拍板 2026-10-24：强制绑 127.0.0.1**（token 空 ⇔ loopback；ADB 两姿势兼容、设置页地址展示同步改；依据见 epic memory 拍板①）】；插件可抢占 serverId【B：冲突语义需拍板】；本机侧 ops.log 未遮蔽错误原文【B：并入下个 gateway 轮】
- context/ 归档轮：~10 个已收尾 epic 驻留活跃区未物理归档

## 决策日志

- [2026-10-24] **P2 分档评估**：A 批 13 项（F19 升 P1 居首 + A02~A13）登记后全部落地；B 档 8 项按触发条件择机（两项当日拍板落地 = B14/B15，余 6 项见上表各行标注）；C 档 3 项观察；D 档 1 项实证否决——`CHANGE_WIFI_STATE` 系 Android 14 `connectedDevice` 前台服务 WifiLock 的 precondition（`GatewayForegroundService.kt` 注释立法），安全审查误判，从清单剔除。
- [2026-10-24] **拍板①（免鉴权绑定）**：免鉴权模式强制绑 127.0.0.1（与 `resolveGatewayToken` 决策联动：token 空 ⇔ loopback）。依据：免鉴权仅建议 ADB 转发，`adb forward/reverse` 两姿势均经设备侧 loopback，兼容性零损失；把「同网段无凭据可达」从文案劝阻升级为结构不可能（fail-closed 口径）。
- [2026-10-24] **拍板②（pruned 入站不对称）**：pruned 补入站 isProjected 校验（目录=调用边界）；full 保持开放并升格为显式裁决——full 若也边界化，等于把 visibility 标记升格为调用 ACL，与 coding-standards §1.1 规则 7「声明非 ACL」冲突；full 连接威胁模型由 L1/L2 裁决 + 私有服务防火墙兜住。裁决记录已回写 host-tools-gateway-export.md「入站边界裁决」表。
- [2026-10-24] **F9 验收降级**：网关广播修复镜像 `_heartbeatPing` 已测形态（拷贝遍历 + 单订阅者 try/catch 包裹）；死连接同步抛不可用真实 socket 确定性复现，无自动钉子。
- [2026-10-24] **F19 方案取舍**：装配期预中止走 chat_page S 方案（`_pendingAbort` 标志 + 赋值点补发 abort，未动内核），避免为闸门语义动 assemble 取消管道；M 方案根治留待出现新触发场景再评估。
