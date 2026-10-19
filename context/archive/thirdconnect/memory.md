---
dev-loop: memory
format: v1
epic: thirdconnect
total-merged: 0
last-merge: none
---

# thirdconnect

- [挂载] docs/design/thirdconnect.md

## 决策（TC1~TC4 已确认，2026-10-12）
- 分层传输定位：HTTP 保留为通用默认传输（现有 `McpClient` 不动），新增同机安卓 Binder(AIDL) 传输作为同机快路径；不替换通用宿主契约。
- 同机选型：Binder(AIDL) 为主，UDS(LocalSocket) 留作后续降级兜底（暂不实现）。
- 接口接法：抽 `McpTransport` 接口（connect / request(jsonRpc string) / incoming stream），`HttpTransport` 与 `BinderTransport` 并列，`McpClient` 构造注入；MCP 语义（initialize/tools/list/tools/call）不变，只换管子。
- 发现层：`PackageManager` 扫描 + `PACKAGE_ADDED/REMOVED` 广播监听，产出「同机 AIDL 服务目录」，与 `ServerEndpointStore` 并存（系统托管端点 vs 用户托管端点）。
- 生态开放：默认 `signature` 私有（零弹窗）；提供「开发者模式/信任第三方」开关，开启后走信任卡片（包名 + 签名 SHA-256）入白名单。
- 安全：Binder `getCallingUid()` + signature 权限验真；第三方走信任卡片白名单。
- 长期愿景：各平台底层方案（iOS 后续）+ HTTP 优化；当前只做安卓。
- 契约约束：服务方约定 Action `com.zzh.goodhub.action.MCP_SERVER` + meta-data（SERVER_ID/TITLE）；GoodHub 需 Android 11+ `<queries>` 声明。

## 网关决策（TC5~TC8 已确认，2026-10-12）
- 双角色定位：GoodHub 升为 Host + Gateway。对内 Binder 调度本地 App；对外起 Streamable HTTP 网关(:8766) 聚合暴露给 PC。
- 本地 App 一律 Binder-only：Release 绝对零端口监听；开发期经 ADB 转发/单测调试，不留运行时网络旁路。
- 网关路径：统一 `/mcp`（Streamable HTTP，协议 2025-06-18），入站出站复用同一套分帧/解析（json_rpc.dart + tool_router.dart）。
- 聚合范围：本地 Binder 工具 + 远端 HTTP server 工具全量聚合，PC 单入口（仅 `http://<IP>:8766/mcp`）。
- 路由复用：`ToolRouter` 前缀 `<server_id>__<tool>` 对本地/远端透明；网关按前缀分发（本地→Binder 唤醒，远端→HttpTransport 转发）。
- 安全闭环：入站 Bearer Token 校验 + PII 过滤 + L1/L2 权限卡片拦截 + ops.log 审计，统一在网关层；出站本地走 Binder UID/sig（TC4）。
- 文档待修订：thirdconnect.md 需补「本地插件(Binder 发现) / 远端服务(URL HTTP)」区分，原「手填 endpoint」仅剩远端路径。**（已补写于 2026-10-12 初版修订，本地/远端双接入 + §7 网关章节已落地）**

## 架构重构决策（TC9~TC14 已确认，2026-10-12）
- TC9 控制/数据面分离原则：Binder 退化为纯控制信令面，大报文下沉到物理句柄通道。128KB 警戒线——`< 128KB` 走 `IMcpChannel.call` 常规 JSON-RPC；`≥ 128KB` 或文件/图片改 `ParcelFileDescriptor` / `SharedMemory` / `Ashmem`。长负载以标准 `$ref` 句柄（`mcp-blob://…`）返回，GoodHub 经 `FileProvider` / `ContentResolver.openFileDescriptor()` 只读跨进程读取，绕开 Binder 1MB。细化 §1.2.3 事务约束，绑定 T-trans-2/3 实现。
- TC10 Dual-Stack 双栈插件引擎：插件加载器分层——Tier A 原生 Binder 插件（现有 §1.2，无端口/sig 防伪）；Tier B 标准 stdio 容器插件（Dart `Process.start` 接管子进程 stdin/stdout，直跑 GitHub 开源 MCP 配置）。Tier B 工具经 §3 前缀路由与网关聚合暴露。新增子项目 **T-stdio**（待排期）。
- TC11 原生层进度节流：GoodHub 原生层 `ProgressThrottler` 强制 200ms 滑动窗口聚合，丢弃中间冗余进度帧，仅推最新状态 + 累计百分比入 `EventChannel`；网关旁路直通——PC 远程调用时 HTTP/SSE 长连接原生层维系，数据面与 Dart UI 解耦。绑定 G1~G5。
- TC12 PC 60s 超时对策：网关等待手机冷启动/长任务期间，每 15s 主动推轻量 `notifications/progress`（如 `Warming up local plugin...`）重置 PC 超时计时；L2 确认卡片触发 `FULL_SCREEN_INTENT` + 短时 `WakeLock` 震动亮屏，显式 45s 确认时限，超时未点即主动回 JSON-RPC 拒绝响应。联动 §7 入站安全。绑定 G1~G5。
- TC13 双进程物理隔离（破 SPOF）：拆 `:gateway` 独立守护进程（`android:process=":gateway"`，`foregroundServiceType="connectedDevice"`，仅监听 :8766 + 管理本地 Binder 连接，内存 < 30MB 高可用）与 `:main` UI 进程（Flutter + 本地模型推理）。UI OOM/闪退不影响 PC 远程连接，主界面重启重连 `:gateway` 恢复。新增网关子任务 **G6**。
- TC14 通用插件接入 SDK：把 AIDL/1MB 分包对第三方透明化，封装为 `goodhub-mcp-plugin-core.aar`（Tier A 官方接入通道，对齐 TC10）。第三方继承 `GoodHubPluginService` + `@McpTool` 注解 + Manifest 一行即接入，零手写 AIDL。SDK 仅实现 `IMcpChannel.Stub`（server 端）；client 端连接生命周期（§9.1 状态机/PendingRequestQueue）仍属 GoodHub 宿主。SDK 必满足 §1.2.7 四条红线：`_async` 透明降级（§1.2.2）、URI 统一 `mcp-blob://`（TC9）、命名不上仲裁（§9.3）、安全闸门无关（TC4）。跨平台三档：Android SDK / Flutter bridge（MethodChannel 包装）/ 非 Android 走 TC7 HTTP。属 net-new 插件侧交付物，独立于 T-trans/G 系列。

## 断点
- [断点] 下一步：唯一挂起 = reverseDemo 宿主推理闭环真机验证（手机配置端侧模型或 BYOK 后重跑，推理方=宿主引擎）；手动验收①信任卡片②FSI/L2 全屏呼叫③电池白名单已于 2026-10-13 全部闭环
  - [已完成] T-sdk-1：插件侧 SDK MVP 骨架 + sample-dummy-plugin 靶子 APK（assembleDebug 通过）
  - [已完成] T-trans-2：宿主 BinderTransport（状态机/挂起队列/5s/DeathRecipient + Dart BinderTransport + McpClient.binder）；真机同步链路联调待设备
  - [已完成] T-trans-3：宿主事件回传（onEvent→onProgress + _async 终帧唤醒 + 反向→answerReverse）；宿主收端代码已落，flutter analyze lib/ 0 错误
  - [已完成] T-sdk-2：SDK 事件发射端（McpToolContext + 反向在途表/answerReverse + handleAsync 守护线程 + slowEcho/reverseDemo 靶子）；plugin-core AAR + sample APK assembleDebug 通过
  - [已完成] T-trans-4：本地插件发现（PackageManager.queryIntentServices + 包变更广播 → 运行时自动挂载 BinderTransport + chat_page/gateway 调试页集成 + onServerRequest(sampling) 接线）；宿主 Kotlin :app:compileDebugKotlin SUCCESSFUL、flutter analyze 0 error
  - [已完成] G1+G2：嵌入式网关 + 聚合单入口（lib/gateway/ 三件：handler 聚合分发 + server Streamable HTTP JSON/SSE 双模/会话强制/Bearer 最小件/§9.2 list_changed 下行/15s 心跳 + controller 双源装配与包变更重扫；chat_page ⚙ 网关开关+Token；回环 HTTP e2e 单测 4/4 过、analyze 0 issue；任务卡 g1.md）；真机 PC 连调待设备
  - [已完成] G3：入站安全闭环（gateway_security.dart：PermissionGateway.classify 复用裁决 + DialogGateDelegate 手机屏确认卡（appNavigatorKey 后台弹层）+ 双重 45s 超时熔断 + C7 会话豁免（stop 清）+ PII 出站 fail-closed 遮蔽（progress message redactSync 同步遮蔽）+ ops.log server=gateway 入站审计；单测 6 例新增全过 10/10、analyze 0 issue；任务卡 g3.md）；FULL_SCREEN_INTENT/WakeLock 原生件归 G4
  - [已完成] G4：前台保活（GatewayForegroundService connectedDevice 型 + WifiLock HIGH_PERF/WakeLock PARTIAL + GatewayServiceBridge :goodhub/gateway_service 通道 + Dart controller 起停联动（MissingPlugin DEGRADE 不阻断）+ Manifest 七权限补齐；:app:compileDebugKotlin 与 processDebugMainManifest 均 exit 0、网关单测 10/10 无回归；任务卡 g4.md）；**TC12 FULL_SCREEN_INTENT 醒目呼叫收口（2026-10-13）：L2AlertActivity + GatewayConsentBridge + NativeConsentDelegate + Manifest 权限**；电池优化白名单留真机后收口
  - [已完成] G5 收尾：Wi-Fi IP 展示（GatewayController.lanAddresses 枚举 IPv4 + 设置面板运行中副标题展示 PC 可配 URL）+ §9.6 背压（PerServerBackpressure per-server max 4 FIFO 排队/零间隙槽位移交，handler 只包真实执行段不占确认等待；单测 3 例新增 13/13 全过、analyze 0 issue；任务卡 g5.md）。教训：async* 生成器取消时仅 finally 保证执行——假传输计数递减必须放 finally（callWithProgress 终帧即提前 return）
  - **[已完成] §1.2.6 信任卡片 UI 收口（2026-10-13）**：scanLocalPlugins 增 signatureSha256/sameSignature + TrustedPlugins 持久化 + chat_page 信任闸门/卡片 + ⚙ 设置管理 + gateway headless 跳过；本地插件「系统托管端点」v1 落地为装配期运行时 face（未持久化到用户 JSON store）
  - [已完成] T-trans-3 全链路 e2e（progress/_async/反向）：宿主收端(T-trans-3) + SDK 发射端(T-sdk-2) + 发现挂载(T-trans-4) 均就绪；**设备 e2e 通过（2026-10-13）**
  - [已完成] 设备 e2e 联调（2026-10-13，设备 3B161700Y0600000）：integration_test/thirdconnect_e2e_test.dart 全过——发现 dummy + Binder 同步 tools/list + slowEcho _async 流式 + reverseDemo sampling 反向闭环 + 网关 :8766 HTTP async 全链路
  - **[已完成] PC 远程连调（2026-10-13，G1~G3 PC 入站验收）**：外部 MCP 客户端（AtomCode）LAN 直连 `:8766/mcp`——Bearer 鉴权 / initialize / tools/list 聚合 4 工具 / tools/call 实调 echo+add 全通（G1「真机 PC 连调待设备」收口）。
  - **[已完成] 手动真机验收全部闭环（2026-10-13）**：① 信任卡片=integration_test 真机过（顺带修 TrustedPlugins 空白名单崩溃）；② FSI/L2=息屏态 FSI 拉起 L2AlertActivity 全屏页（用户一手确认 A）+ 45s 熔断 ops.log 实锤（45038ms→user_rejected）+ C7 会话豁免生效（add 20ms）；③ 电池白名单=adb 持久写入 + force-idle 深度 Doze 下 :8766 HTTP 200。关键认知：dummy 全工具因 SDK 不发 annotations 双缺从严落 L2（echo 即 L2 靶子，无需新写工具）；L2 确认链全靠 ops.log 审计还原。唯一挂起：reverseDemo 宿主推理闭环（手机缺推理源，配置端侧模型/BYOK 后即验，非阻塞）
  - [已修复→已验证] 网关 SSE 缓冲 bug（AtomCode 流式实测发现）：slowEcho progress 4 帧挤压收尾 1ms——gateway_server.dart 两处 SSE 起点漏 `bufferOutput=false`（goodshare 同坑未继承）；已修 + 逐帧计时回归钉子（撤修复验证能咬人）；**真网复测 PASS**（gaps≈0.4s 逐条即达，签名与单测一致）。注：AtomCode 曾误归因「冷启动瞬态」已驳回（确定性缓冲/不同构建/缺对照三论据）。reverseDemo 未达 PC=预期（宿主 sampling 层闭环，推理方=宿主引擎；该机无推理源故失败 status，属环境未就绪非 bug）
  - **待手动真机验证（UI 流）**：~~① 信任卡片~~ → **已自动化（2026-10-13）**：integration_test/trust_gate_test.dart 真机全过（卡片展示/信任并挂载持久化/拒绝不入白名单），并顺带修出 TrustedPlugins 空白名单首次信任必崩 bug（_map 返回 const map 不可变）；信任卡片抽公共件 lib/ui/trust_plugin_dialog.dart（showTrustCard + TrustPluginDialog，chat_page 复用）。剩余手动：② PC 触发 L2 写操作时 L2AlertActivity 全屏醒目呼叫（息屏亮屏+震动+45s）——独立原生 Activity + 需 PC 触发，integration_test 无法干净覆盖；③ 电池优化白名单（REQUEST_IGNORE_BATTERY_OPTIMIZATIONS，视真机 Doze 表现）——系统设置项
  - [已完成] 真机黑屏修复（2026-10-13，CPH2767/Oppo-ColorOS）：Impeller(Vulkan) 该 GPU 静默不出首帧→启动闪屏不移除→黑屏；AndroidManifest 加 `io.flutter.embedding.android.EnableImpeller=false` 回退 Skia，截屏确认 UI 完整渲染（上机启动前置条件已解除）
  - [已完成] 开 PC 远程网关闪退修复（2026-10-13，G4 FGS）：`GatewayForegroundService.onStartCommand` 缺 `createChannel()` 即 startForeground→Android12+ IllegalArgumentException 崩宿主；已在 startForeground 前补建通道。uiautomator 真机点开关验证：进程存活+前台通知 goodhub_gateway 正常+:8766 initialize 合法响应，无崩溃
  - ✅ 存量债已清（2026-10-13，[test]）：8 个旧测试文件 + integration_test/gateway_external_probe 共 67 issue（66 error + 1 warning）全修复——`McpClient(baseUrl:/httpClient:)` 命名构造改 `McpClient.http(...)` 工厂。`flutter analyze test/ integration_test/` → No issues found，受影响单测实跑 31 例全过。全仓 analyze 仅剩 lib/ui/gateway_loop_debug_page.dart:635 `value` deprecated 警告（pre-existing，非测试债）

## 归并补充（2026-10-19 · 自 devlog 20 条提炼，memory 此前缺失项）

- **流内间隙超时误杀思考修复（2026-10-15）**：`HybridCloudEngine._cloudSend` 原以「两事件静默 > interEventGapTimeout(30s)」判卡流，思考期模型不产 token 即误触发 TimeoutException 中断任务。改为「传输层字节活体 + 自适应预算」：`parseSse` / `sendSseRequest` 暴露 `onActivity`（任意行到达，含 SSE `:` 心跳注释帧）→ `CloudLlmEngine.send({onActivity})` 透传至 Anthropic/OpenAI 客户端与 Fenced 装饰器；看门狗由字节活体与事件共同重置（**心跳帧只作存活证据、不作工作推进**）；预算自适应 = 首字节前 `firstTokenTimeout`(8s) 快速判死连接，已有活体后随 `elapsed*0.5` 放宽（下限 interEventGapTimeout、上限新增 `maxThinkingGap`=5min）。`DegradationController.interEventGapTimeout` 默认 30s→120s（仅作死连接兜底下限）。接口增可选命名参 `onActivity`，11 个实现（含 6 测试 fake、debug 页 `_ScriptedEngine`）同步；`flutter analyze` 0 issue、全仓 585 测试通过。
- **网关 SSE 缓冲 bug**：`gateway_server.dart` 两处 SSE 起点漏 `bufferOutput=false`，progress 4 帧挤压到收尾 1ms（AtomCode 真网流式实测抓到；loopback e2e 用 `join()` 读完再断言故未暴露）。已修 + 逐帧计时回归钉子 `test/gateway/gateway_server_test.dart`「SSE 进度帧即达」（撤修复验证能咬人）；真网复测 gaps≈0.4s 逐条即达。曾误归因「网关冷启动瞬态」已驳回（response 级确定性缓冲、两次跑不同构建、缺修复前干净复跑对照）。
- **reverseDemo「反向请求未达 PC」= 预期架构非 bug**：网关模式下本地插件 sampling 反向请求由宿主 `gateway_controller._assemble` 的 `samplingRequestHandler` 闭环（走宿主自身引擎，TC8/§15 临时会话隔离），不经外部 PC 客户端。「端侧生成失败：未下载模型包（云端未配置）」= 该机无可用推理源，属环境未就绪；`isError:false` + 结构化失败 status 符合 M3 降级语义（防熔断误计数）。
- **thirdconnect.md 增补**：§9 运行时鲁棒性守则（6 暗坑：冷启动挂起队列/状态机、list_changed 下行、SERVER_ID 命名仲裁、多用户 MATCH_CURRENT_USER、hop_count/_meta 防环、背压信号量 max_concurrent=4）+ 红线速查表 + 落点映射；§10 架构重构（控制/数据面分离 / Dual-Stack stdio / 原生 200ms 节流 + 旁路直通 / Keep-Alive 15s+L2 45s 熔断 / 双进程 :gateway/:main 隔离）；§11 插件接入 SDK（接入体验 + SDK 脏活 + 五处纠正 + 跨平台三档 + 工程约束）。
- **信任闸门两修复**：① 信任卡片抽公共件 `lib/ui/trust_plugin_dialog.dart`（`showTrustCard` + `TrustPluginDialog`，chat_page 复用、删内联 51 行，调用点补 `mounted` 守卫）；② TrustedPlugins 空白名单首次信任必崩——`_map()` 白名单空/损坏时返回 `const {}` 不可变，`add`/`remove` 原地变更抛 `UnsupportedError`，改为一律 `Map.of` 可变副本；由 `integration_test/trust_gate_test.dart` 真机钉死（**绕过闸门的 e2e 对闸门自身路径零覆盖，故闸门必须独立集成测试**）。
