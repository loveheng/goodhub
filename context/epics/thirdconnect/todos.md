# thirdconnect 实现拆解（T-trans / G）

> 决策底：TC1~TC8 全确认（context/epics/thirdconnect/memory.md）；契约：docs/design/thirdconnect.md。
> 待确认台账 W1/W2 属 m4 周计划，不阻塞本 epic。

## 传输底座（T-trans）
- [x] T-trans-1 抽 `McpTransport` 抽象 + `HttpTransport`；`McpClient` 协议层委托 transport（行为等价，flutter analyze 通过）
- [x] T-trans-2 `BinderTransport` 实现（宿主 AIDL 客户端 + 状态机/挂起队列/5s 冷启动/DeathRecipient；Dart `BinderTransport`+`McpClient.binder`；**代码已落，真机同步链路联调待设备**；契约见 §1.2.2/§1.2.3/§9.1）
- [x] T-trans-3 Binder 事件回传（`onEvent`→`onProgress` + `_async` 终帧唤醒 + 反向请求→`answerReverse`；**宿主收端已落，flutter analyze lib/ 0 错误；progress/_async/反向 e2e 待 T-sdk-2 发射端 + 设备**；契约见 §1.2.2/§5/§1.2.3）
- [x] T-trans-4 本地插件发现（`PackageManager.queryIntentServices` + `PACKAGE_ADDED/REMOVED` 广播 → 运行时自动挂载 BinderTransport + chat_page/gateway 调试页集成；宿主 Kotlin `:app:compileDebugKotlin` SUCCESSFUL、flutter analyze 0 error；**系统托管端点实现为装配期运行时 face，未持久化到用户 JSON store（v1 口径）**；反向请求 e2e 接线闭环待设备）

## 网关（G）
- [x] G1 嵌入式 HTTP Server（`:8766` `/mcp`，Streamable HTTP 2025-06-18；JSON/SSE 双模 + 会话强制 + GET 订阅流 15s 心跳；任务卡 g1.md）
- [x] G2 `tools/list` 聚合（本地 Binder + 远端 HTTP）→ PC 单入口（前缀分发直达 face.client 流式；包变更重扫 → §9.2 list_changed 下行；任务卡 g1.md）
- [x] G3 入站安全（Bearer（G1）+ L1/L2 手机屏确认卡 45s 熔断 + PII 出站 fail-closed 遮蔽 + ops.log 入站审计；任务卡 g3.md；FULL_SCREEN_INTENT/WakeLock 原生件归 G4）
- [x] G4 前台保活（GatewayForegroundService connectedDevice 型 + WifiLock/WakeLock + gateway_service 通道联动起停 + 七权限补齐；任务卡 g4.md；FULL_SCREEN_INTENT 醒目呼叫独立收口）
- [x] G5 物理通道（局域网 `0.0.0.0`+Token 与 ADB forward 随 G1/G4 可用；Wi-Fi IP 展示 UI + §9.6 背压并发信号量（单 server max 4 排队）收尾完成；任务卡 g5.md；Tailscale 零改动）

## 插件接入 SDK（TC14）

> 把 AIDL / 1MB 分包对第三方透明化（thirdconnect.md §11）。SDK 仅 server 端 Stub；client 生命周期归宿主。详细任务卡：context/epics/thirdconnect/t-sdk-1.md

- [x] T-sdk-1 插件侧 SDK MVP 最小骨架（`GoodHubPluginService` + `@McpTool`/`@Param` + 运行时反射派发器 + `sample-dummy-plugin` 靶子 APK；assembleDebug 通过；红线见 §1.2.7 / §11；作为 T-trans-2 真机联调靶子）
- [x] T-sdk-2 SDK 事件发射端（`McpToolContext`：progress/_async 终帧/reverseRequest；`GoodHubPluginService` 反向在途表 + `answerReverse` 回程；`ToolDispatcher` context 首参注入 + `handleAsync` 守护线程 + 异常转 fail；`DummyPluginService` 加 slowEcho/reverseDemo 靶子；plugin-core AAR + sample APK assembleDebug 通过；闭环 T-trans-3 e2e 待设备）

## 验收发现的后续项（2026-10-13 手动验收轮）
- [ ] SDK `@McpTool` 补 `readOnlyHint` 注解并在 tools/list 下发 `annotations`：当前 SDK 不发注解 → 第三方插件全部工具双缺从严落 L2，PC 每次调用都要手机确认（C2 未知从严口径正确，但生态体验差——echo 类只读工具应能声明 L1 静默放行）；改动点=McpTool.kt 注解字段 + ToolDispatcher.toolsList 输出 annotations + sample 靶子声明
- [ ] reverseDemo 宿主推理闭环真机验证：手机配推理源（端侧模型包或 BYOK 云）后 AtomCode 重跑 reverseDemo，验 sampling 反向 → 宿主引擎推理 → 插件消费回传（当前该机无推理源，结构化失败 status 已验降级路径）
