---
memo: todos
format: v3
epic: on-device
---

# on-device · 域内待办
- [ ] [2026-10-30] (功能) (层:L2) (重:中) OD2 前台提示消费（UI 侧）：场景 B 后台冷装载已打 PendingForegroundLoad 标记（TTL 30min），但『下次用户进前台时提示「已检测到后台任务，正在为您启动端侧加速…」并触发前台安全装载』的 UI 消费尚未接线——需在 chat_page 或设置页消费标记（Snackbar/顶部条），提示后 clear 标记；禁自动并发消费后台任务（避免与前台请求争抢端侧单执行槽） (src: ai,2026-10-30 OD2 遗留)
- [ ] [2026-10-30] (优化) (层:L1) (重:重) OD5 资产迁入应用内部私有目录：当前模型资产落外置 FUSE（/storage/emulated/0/Android/data/.../files/models）→ 装载期双份缓冲（FUSE 自有缓存 + 内核页缓存）且 mmap 映射下 fadvise 无效；改为内部私有目录（filesDir）以消除 FUSE 抽象层，是降低装载期内存与 I/O 抖动的最高杠杆项。步 0 数据落地后立刻排期；落地须含存量资产迁移（外置→内部）与导入通道落点改写 (src: 用户,2026-10-30 裁决 OD5（P0 专项）)

> 初始化盘点产生的候选缺口项；未经用户拍板，不构成工程排期。落地前须对应设计稿（draft 转正）+ solution-admission 口径。

## P1-A 开发任务切分（2026-10-28 准入拍板后切分；口径=两稿 v2.7 SSOT）

> 来源：devlog [决策][开工准入拍板] Sprint 切片 S1→S2→S3。每项开工前按 solution-admission 单项放行；锚点指向 NPU 部署稿（on-device-npu-deployment.md）/ 总纲（on-device-capability.md）。

### S1 通信脚手架（:engine 独立进程 + Mock 联调）

- [x] S1-1 `:engine` 独立进程骨架（Android Service + `BIND_AUTO_CREATE|BIND_IMPORTANT`、非 isolatedProcess）——NPU 稿 §6.2（2026-10-28 落地：Manifest + EngineService.kt + EngineServiceBridge.kt + lib/llm/on_device_engine_binding.dart；AIDL 占位 Binder，契约归 S1-2）
- [x] S1-2 `IOnDeviceEngineService.aidl` 契约落地（init/getSharedMemoryFd/getEventFd/startGenerate/cancelGenerate/truncateContext/releaseEngine/checkStatus；generationParams intArray 传 id 序列）——总纲 §2（2026-10-28 落地：AIDL 双接口 + EngineStatus 双端序数镜像；细化=initEngine 增 listener 入参承载 onEngineDied，已回写总纲 §2）
- [x] S1-3 数据面：Ashmem SPSC RingBuffer + eventfd 唤醒 + 单调自增掩码协议 + 500ms 写超时 IPC_DEADLOCK——NPU 稿 §6.1/§6.3（2026-10-28 落地：TokenRingBuffer.kt 纯逻辑件 JVM 单测 6 例 + EngineDataPlane.kt；契约细化=getSharedMemory():SharedMemory + 唤醒 fd 以 pipe 承载，已回写总纲 §2）
- [x] S1-4 轻量 Detokenizer（Native mmap 查表拼字节 + Dart `utf8.decoder` 流式重组，uint32 token id 载荷）——NPU 稿 §6.4（2026-10-28 落地：on_device_detokenizer.dart 单测 8 例跨微批无损；偏差=mmap 需 native 随 S3-6 下沉，S1 以 Uint8List 承载）
- [x] S1-5 Mock 生成器（35ms/token）+ `HybridCloudEngine` 接线 EngineDiedException 无缝切云联调——总纲 §2（2026-10-28 落地：Mock 生成器 + Listener onTokens/onGenerateFinished 过渡通道（S3-6 收编退役）+ OnDeviceEngine 完整粒度 + AidlOnDeviceEngine/AidlOnDeviceLlmEngineAdapter + 混合引擎死亡切云组 3 例）
- [x] S1-6 重启风暴两级熔断（L1 内存态 5min≥2 次→进程生命周期切云；L2 当天累计 2 次→持久化锁 24h；计数口径按 §6.5 收窄）——NPU 稿 §6.5（2026-10-28 落地：on_device_circuit_breaker.dart 单测 10 例 + 死亡信号两路分流（onEngineDied 计入/onProcessDied 不计入）+ generate 闸门熔断/冷却期快速失败切云）

### S2 QNN 真机拉通（资产 + 实测）

- [x] S2-1 QAIRT jniLibs 集成（HTP v75；W^X 陷阱：原生驱动库强制 jniLibs、OTA 仅发 .bin）——NPU 稿 §4.7（2026-10-28 工程面落地：dlopen/dlsym 冒烟探针 cpp/engine_probe.cpp + CMake/gradle 接线 + QnnProbe.kt + jniLibs README GenieX 获取指引；**v3 路线拍板同日：推理内核改用 GenieX Android SDK**，探针升级位改 `GenieSession.create()` 冒烟，GGUF 取代 context 二进制；**边界如实记录**：GenieSession 冒烟与驱动握手实测需 SDK 落位 + 8 Gen3 真机，.so 本体不入 git）
- [x] S2-2 OTA 资产分发（按 HTP 版本单选下载 ≈1.8GB、Zip 含 tokenizer.json 版本对齐、filesDir 落盘 + ≥5GB 门禁 + 原子 rename 防 SIGBUS；驱动指纹三要素不兼容脏删重拉不计熔断）——NPU 稿 §3.5/§3.6/§4.5/§4.6/§4.8（2026-10-29 落地：on_device_asset_manager.dart manifest 分发+sha256 三重校验+磁盘门禁+staging 原子替换+指纹元数据/漂移自愈；冒烟 PATCH 已撤，委托正式通道；边界=指纹三要素现仅 Build.FINGERPRINT，远端 manifest 服务端面未建走内网通路）
- [x] S2-3 Prefill 分桶编译（128/256/512/1024 对齐 + SoC×HTP×Bucket 资产矩阵）+ Prefix Cache 256/512 分块固化（KV 前缀 DMA 复用）——NPU 稿 §2.4/§3.6（**2026-10-29 重扫面收口**：原实现项系手写 QNN 路线，GenieX 拍板后结构性吸收——前缀复用 Genie 内置、ctx-bin 由 AI Hub 离线预编译下发、桶编译矩阵归云端 CI；App 侧遗留仅 §2.4 v2.7 Prompt 拓扑正规化，核对已由 agent_loop P1-3b/§6.5 既有编排满足，测试钉子 :486/:876 在案，无新码。S2-5 真机实测补 Genie 前缀复用收益观测）
- [x] S2-4 三态生命周期状态机（ACTIVE/WARM-STANDBY 3~5min TTL/COLD-EVICTED RSS<50MB + onTrimMemory 驱动）——NPU 稿 §4.1（2026-10-29 落地：engine/EngineLifecycle.kt 纯逻辑件（代次机制防旧计时器杀新会话）+ EngineService 接线（warmup/生成钩子/trim 驱动/内存护栏）；UNCERTAIN=护栏阈值 2.5GB 待 S2-5 真机校准；边界=RSS<50MB 由 close() 承载未独立测量）
- [x] S2-5 3B@INT4 真机实测（TTFT≤800ms 短上下文 / 2K≤5s+Prompt Cache、TPOT≤35ms、两级熔断全链验证）——NPU 稿 §1.2/§4 验收（**2026-10-29 收口**：TTFT 短 515ms✅/2K 2147ms✅；TPOT ≈81ms/token ❌ 距 35ms 目标 2.3 倍——debug 包+过渡回调开销，归 S3-6 数据面+release 复测；两级熔断 L1/L2/reset 真机全链绿（diagPanic 诊断面，PATCH）；外部 SIGKILL 向量无 root 不可达（`am kill` 杀不动=BIND_IMPORTANT 防杀正向佐证）；护栏 2.5GB 线实测不可达（GenieX 权重走 ION 不入 PSS，:engine PSS ~103MB 稳定），真指标归 S3 内存面；前缀复用同字重发无收益=过渡口径会话有状态结构性限制，归正式 truncateContext/§2.4 接线后复测；bench 触发收口 dart-define=ON_DEVICE_BENCH，诊断=ON_DEVICE_BREAKER_DIAG/RESET）

### S3 调度边界（热/后台/并发/终止）

- [x] S3-1 热调度：ThermalStatusListener 四模式 + SEVERE 全切云（禁 CPU 分流）——NPU 稿 §5（2026-10-29 落地：engine/EngineThermal.kt 纯逻辑热状态机（BALANCED/POWERSAVE/THERMAL_CUTOFF 映射 + 进出沿迟滞 ≥SEVERE/≤MODERATE；Performance/Duty-cycle 非热触发不随热迁移）+ AIDL onThermalCutover 切云沿回调（initEngine 即时回报初态）+ EngineService 接线（thermal listener 注册/切云沿 abort 在途/startGenerate 冗余热闸/checkStatus=circuitBroken）+ Dart EngineThermalGate（generate 热闸置于熔断闸前，环境降级不计熔断）；边界=MODERATE POWERSAVE 档 geniex 管线无 per-stage/OPP API 仅留痕钩子、在途生成遇切云 abort 收尾不 fail 活跃流防云端重发重复、真机 SEVERE 触发验证归热源实验）
- [x] S3-2 FGS 前台时序硬约束（前台预挂 + `dataSync` 类型，API 31 起后台启动限制；否决 shortService）——NPU 稿 §6.2（2026-10-29 落地：AIDL 增 promoteForeground() + EngineService 执行面（IMPORTANCE_LOW 极简通知 + 显式 FOREGROUND_SERVICE_TYPE_DATA_SYNC 三参 startForeground + ForegroundServiceStartNotAllowedException catch 防御 + 生成 finally 自动 stopForeground 免 demote 面）+ EngineServiceBridge 前台闸（Application.ActivityLifecycleCallbacks started 计数，后台请求跳过留痕=禁后台补救）+ Dart 侧 kFgsPromoteMinTokens=256 长生成阈值（§6.2「判定可能耗时时即附着」口径，拍板兜底值）；时序验证 on_device_fgs_promote_test 3 例（promote 先于 startGenerate/短生成不发起/常量锚定）；边界=前台态判定与真机 ForegroundServiceStartNotAllowedException 路径归真机验收 ⑦）
- [x] S3-3 并发原子抢占（策略 B：`ServiceBusyException` 快速驳回切云 + 前台对后台 cancel 让槽 + 绝不驳回用户；`EngineStatus.busy` 仅瞬时快照禁缓存防 TOCTOU）——NPU 稿 §6.6 / 总纲 §2 v2.6（2026-10-29 落地：engine/EngineSlot.kt 纯逻辑单执行槽（CAS 原子授予/后台忙即 DENIED_BUSY/前台 preempt→有界等待 1.5s 让槽/超时兜底驳回；并发 8 线程单 GRANTED 防护）+ ServiceBusyException.kt（message 前缀 service_busy 跨进程机器判别——AIDL RuntimeException 类型不保真）+ EngineService 接线（startGenerate 原子判定、not-ready/dataPlane 失败路径补槽释放、checkStatus 读 slot）+ GenieSession.busy 字段退役单源化 + Bridge 注入 foreground（Activity started 计数）+ service_busy 单独分码 + Dart 侧 service_busy→EngineDiedException 切云（无 breaker.report 不进熔断）；测试 EngineSlotTest 7 例 + on_device_busy_preempt_test 2 例；边界=真机并发抢占实跑归验收 ⑤）
- [x] S3-4 终止下沉收口（盘点=cancel 链已满足 §6 下沉语义：abortRequested @Volatile + SDK stopStream + collect 循环 token 粒度检查；缺口修正=releaseEngine 改 abort 前置 + EngineLifecycle.onRelease() 单源驱动；EngineLifecycleTest 13 例含新增 3 例）
- [x] S3-5 OEM 冻结与中断防护（盘点结论 NPU 稿 §6.2 v2.7 四条防护落地标注：①FGS=S3-2 ②降档=geniex 路线不适用 ③电池白名单引导行 ④SIGKILL 不计熔断；边界：OEM 冻结(暂停)检测面外归真机验收 §7.1）
- [x] S3-6 Dart/FFI 闭环收尾（eventfd→Dart 消费线程 Native Epoll worker + Dart_PostCObject；StreamController.onCancel 自动下沉 cancel；truncateContext KV 前缀复用）——NPU 稿 §6.4/§6.5 / 总纲 §2（**2026-10-29 落地**：native 数据面收编 Binder 过渡通道（libgdw libgdw 链接修复 dart_api_dl.c vendor 补齐 + CMake C 语言）+ Dart binding startDataWorker/stopDataWorker + onDataBatch 微批消费 + onIpcDeadlock 切云沿 + onTokens 退役；onCancel 自动下沉 cancel=S1-5 既有在案核验；truncateContext(0)=query 每请求 reset 天然满足（geniex 内置前缀缓存）/ >0 不支持 DEGRADE 留痕；新增 on_device_data_plane_test 6 例；边界=真机 TPOT 复测 + truncateContext(0) 前缀复用观测归真机钩子）

## 机制审计缺口（2026-10-30 只读审计轮 · 用户已拍板登记）

> 来源：全量机制审计（19 项），按 P0/P1/P2 三档登记；P3 五项属清理债，落全局 `context/todos.md` misc 节。
> 纪律：每项开工前按 solution-admission 单项放行；P0-1 与 P0-3 与「FGS 绑定即挂」复测**必须成组收口**（审计结论：分开修会让复测通过的是意外路径而非设计路径）。

### P0（核心机制断裂）

- [x] [2026-10-30] (风险) (重:重) **P0-1 `releaseEngine` MethodChannel 接线缺失**（已修：桥面补 `releaseEngine` case + `release()` 异常收口；R11 落地同时抓出**审计漏项** `truncateContext` 一并补接线——该漏接会让 Dart 侧 `truncateContext()` 穿透未捕获的 MissingPluginException，因该方法只 catch PlatformException；由 arch-guard R11 防复燃）：Dart `release()` 调 `invokeMethod('releaseEngine')`，但桥面 case 表无此项 → 恒落 `notImplemented()` → `MissingPluginException`；`release()` 无 catch，异常穿透 finally 由 `main.dart` 的 `unawaited()` 无人监听 → 每次退后台一个 root zone 未捕获异常；AIDL 侧的 `lifecycle.onRelease`（作废旧 TTL 定时器 + 与驱逐同一路径）从未被调用 | 红线：补 case 后须同步 `arch-guard` R11 契约比对，禁再手抄 case 表 | 落点 `android/.../EngineServiceBridge.kt` + `lib/llm/on_device_engine_aidl.dart` (src: ai, 机制审计)
- [x] [2026-10-30] (风险) (重:重) **P0-2 `GdwNative.start` 返回值三态不可区分**（已修：失败码统一为 0 + `lastError()`/`lastErrno()` 诊断通道 + 两侧注释钉死 `!= 0` 判定）：成功返回 `reinterpret_cast<jlong>(w)`（tagged 堆指针，负值），失败返回 -1~-6，而宿主侧判 `!= 0L` → **失败被判成功**；后果三连 = ① worker_start_failed 诊断路径恒不可达 ② 后续 `startDataWorker` 被 handle!=0 幂等短路，数据面死而不重建 ③ 任何后续 stop 路径 `reinterpret_cast<Worker*>(-6)` 解引用 → **主进程确定性 SEGV** | 红线：返回值不承载错误分类（0 = 唯一失败码；成功为指针，宿主侧恒判 != 0 不判正负）；errno 诊断经独立通道取 | 落点 `android/app/src/main/cpp/engine_data_worker.cpp` + `GdwNative.kt` + `EngineServiceBridge.kt`（钉 gdw-handle-sign 修了一半） (src: ai, 机制审计)
- [x] [2026-10-30] (风险) (重:重) **P0-3 懒加载状态机无反向同步沿**（已修：`onEngineEvicted` 上行 + 桥面清数据面句柄 + Dart 复位 loadState）：`:engine` 侧自发状态变更（TTL 驱逐 / onTrimMemory 驱逐 / 内存护栏驱逐 / 进程死亡重启 / SDK init 失败 / worker HUP 终态退出）**无一条通知主进程**，Dart `loadState` 说谎仍为 ready → `enable()` 幂等 no-op 不重装 → 下次端侧请求必撞 `genie session not ready` / `data plane not initialized`，且错误文案显示 `assetMissing`（立法语义=模型未下载）→ 补救方向被误导为「重新下载模型」 | 红线：驱逐/死亡必须经 listener 上行，Dart 侧复位 loadState + 清数据面 handle；无自愈路径的死锁属 P0 | 落点 `IOnDeviceEngineListener.aidl` + `EngineService.kt` + `EngineServiceBridge.kt` + `on_device_engine_binding.dart` + `on_device_engine_aidl.dart` (src: ai, 机制审计)

### P1（机制缺口 / 特定场景功能降级）

- [x] [2026-10-30] (风险) (重:重) **P1-4 路由无前台/后台维度 + `paused→release` 主动击杀在途**（已修：路线 B 一次收口两半 —— ① FGS 改「绑定即挂」使后台任务期间 :engine 受前台提权保护，免 OEM 冻结 / mem-pressure 回收；② 退后台钩子移除 release，权重回收完全交 `:engine` 侧 TTL（空闲 5min）+ 内存预算护栏）：`HybridCloudEngine.send` 判据仅 offline/降级冷却/偏好/工具面，不含前后台；`main.dart` paused/hidden/detached 无条件 `release()`（不看在途、不看 FGS）→ 交互式生成中息屏必被 abort 空产出；后台任务×端侧组合无 FGS 且被 trim 击杀；FGS 预挂与 paused→release 语义相反无仲裁 | 红线：有在途生成或 FGS 挂着时禁止 release（走 `releaseIfIdle`）；与 P0-1/P0-3 成组收口 | 落点 `lib/coordinator/hybrid_cloud_engine.dart` + `lib/main.dart` + `lib/llm/on_device_engine_aidl.dart` (src: ai, 机制审计)
- [ ] [2026-10-30] (风险) (重:中) **P1-5 端侧路径输入零预算**：`_deviceSend` 把 system + 全部历史（含 tool result）压平单发，`GenerationConfig` 仅输出侧 maxTokens，输入侧无长度/token 预检；`n_ctx` 编译期固定，Agent 多轮历史易超窗，超窗 SDK 行为（尾部截断 = 丢最新指令 / 报错 = 生成失败）未实证 | 红线：输出有预算、输入无预算的不对称须补预检；阶梯截断机制仍 draft（memory B 表） | 落点 `lib/coordinator/hybrid_cloud_engine.dart` (src: ai, 机制审计)
- [ ] [2026-10-30] (功能) (重:重) **P1-6 端侧流式在 hybrid 层被截成单发聚合**：引擎侧 token 流全链已建（Ashmem ring → native worker → `Stream<EngineChunk>`），但 `OnDeviceLlmEngine` 契约为 `Future<String?>`，`await device.generate(...)` 收满全文才一次投递 → 512 token × ~60ms ≈ 30s 无出字；双轨形态下端侧轨与云轨体验落差极大 | 红线：纯装配层缺口，引擎侧零改动 | 落点 `lib/llm/llm.dart` + `lib/llm/on_device_engine_aidl.dart` + `lib/coordinator/hybrid_cloud_engine.dart` (src: ai, 机制审计)
- [ ] [2026-10-30] (风险) (重:中) **P1-7 `waitReady` 3s 超时判终态失败（retryable=false）**：首次 enable = 首次 bind + `:engine` 进程冷启动（JVM + geniex AAR），弱机 3~8s 常态 > 3s → 新装首次端侧请求大概率「引擎未就绪」终态失败；有界退避重试只对 `kEngineInterruptCodes` 生效，漏了冷启动慢场景 | 红线：可自愈的等待与终态失败必须分口径（同 gdw-load-notbound） | 落点 `lib/llm/on_device_engine_aidl.dart` (src: ai, 机制审计)
- [ ] [2026-10-30] (风险) (重:中) **P1-8 停用词/采样参数三层「存在但失效」**：AIDL 注释已诚实标注（temperature/topP 过渡期取资产默认、stopTokenIds 归 S3），但 Dart `GenerationConfig` 注释不标失效；`EngineService.startGenerate` 只读 maxTokens/foreground；`GenieSession.query` 不传采样参数；detokenizer 纯字节重组无 stop-sequence 事后扫描补偿 | 红线：单发提取语义最依赖终止边界，失效=过度生成（NPU 空烧 + 输出边界漂移 + 提取解析可能破）；契约「看起来生效」与实际背离须在三层各标一行 | 落点 `IOnDeviceEngineService.aidl` + `EngineService.kt` + `GenieSession.kt` + `lib/llm/on_device_engine.dart` (src: ai, 机制审计)

### P2（机制脆弱 / 文档-实现不一致）

- [ ] [2026-10-30] (风险) (重:中) **P2-9 熔断 L2 24h 锁「当天」边界未实现**：`_l1TriggerCount` 为进程生命周期计数（无自然日边界重置），且 L1 触发后窗口清空 → 达 L2 需「再在 5min 内凑齐 2 次」；后果双向失真 = ① 稀疏崩溃（间隔 >5min）永不达 L2，24h 持久锁近死信，而「坏驱动设备」恰是稀疏崩溃 + 进程重启清 L1 的画像 ② 文档「当天累计 L1 达 2 次」与实现「进程生命周期 + 两组各 2 次」两个方向都不符 | 红线：L2 覆盖的正是稀疏崩溃场景，缺口即保护失效；另 `_l1WindowStart` 为锚点式窗口非真滑动窗口（可接受但与字面不符） | 落点 `lib/llm/on_device_circuit_breaker.dart` + `docs/design/on-device-npu-deployment.md` §6.5 (src: ai, 机制审计)
- [x] [2026-10-30] (风险) (重:中) **P2-10 SPSC `read_idx` 双写竞态（回退态未覆盖）**（已修：消费端推进改 CAS max 单调 + 写侧游标只向前 + 满判据 `>=`）：两个写者 = 消费端 drain 推进 + `:engine` `clearPending`（readIdx=writeIdx）；失步钳制只处理 `avail > capacity`（回绕态，gdw-ring-desync 已修），未覆盖回退态 = 在途 drain 已读 r=100 → clearPending 写 120 → drain 回写 101（lost update）→ 上一代请求尾字节混入新流；identity UTF-8 载荷大概率仍合法文本 → 静默污染无 FormatException | 红线：最高频触发 = 前台连发（第二消息抢占 abort × 在途 drain，~40ms 微批窗口）；游标单调性须由单一写者保证 | 落点 `cpp/engine_data_worker.cpp` + `engine/TokenRingBuffer.kt` (src: ai, 机制审计)
- [ ] [2026-10-30] (风险) (重:轻) **P2-11 内存护栏单点采样 + 增量指标对全系统波动敏感**：`checkMemoryGuard` 只在生成结束 finally 采样一次，生成期（内存活动峰值、数十秒）无采样 → 「逼近 LMK 提前驱逐」只兑现 1/N；增量指标（暖机基线 − 当前）无法区分引擎足迹与其他 app 波动 | 红线：其他 app 增配即可顶过阈值 → 误驱逐（下次请求重装，体验卡顿） | 落点 `EngineService.kt` + `engine/MemoryGuardEvaluator.kt` (src: ai, 机制审计)
- [ ] [2026-10-30] (风险) (重:中) **P2-12 Prefix Cache 复用声称与每请求 `reset()` 相矛盾**：AIDL/EngineService 声称「重放同前缀命中运行时前缀缓存（llama.cpp prompt cache 层）」，但 `GenieSession.query` 每请求前置 `w.reset()` 清空上下文；若 geniex 的 `reset()` 连带清 prompt cache（SDK 无源码、未实证），则 §2.4 Prefix Cache 主路线在端侧整体失效，多轮压平每次全量 prefill | 红线：文档声称须实证后再留，否则属幻影契约；S2-5 复用观测钩子未执行 | 落点 `IOnDeviceEngineService.aidl` + `EngineService.kt` + `GenieSession.kt` (src: ai, 机制审计)
- [ ] [2026-10-30] (风险) (重:中) **P2-13 cancel/热切云经 `runBlocking stopStream` 阻塞共享线程**：`GenieSession.abort()` 的调用方含 Binder 线程池（cancelGenerate）、PowerManager listener 无 executor 版 = `:engine` 主线程（热切云）、前台抢占 → 热状态突变瞬间 stopStream 阻塞主线程，全部 Binder 分派停摆；抢占等待 1.5s 可能被 stopStream 吃掉 → DENIED_TIMEOUT → 前台请求切云（「绝不驳回用户」降级为「绝不立刻满足」） | 红线：注释「生成循环 token 粒度检查 m_abort 即时跳出（SDK 源码实证）」是旧裸 Genie C API 语义，S3 换线后已过期，现靠 SDK stopStream，响应性未实证 | 落点 `GenieSession.kt` + `EngineService.kt` (src: ai, 机制审计)
- [ ] [2026-10-30] (功能) (重:中) **P2-14 装载失败原因丢失**：loadModel 的「受理中」「资产缺失」「SDK init 失败」「管线 build 失败」在 checkStatus 下全部呈现为 `assetMissing`（受理/终态共用序数），enable 轮询满后报「模型装载失败（assetMissing）」→ 把驱动/SDK 故障导向「重新下载模型」的错误补救；`loadError` 仅供 `:engine` 本地日志，AIDL 无 `getLoadError` 查询面 | 红线：终态归因不可与过渡态共用枚举序数（gdw-enable-accepted 的半开缺口） | 落点 `IOnDeviceEngineService.aidl` + `EngineService.kt` + `GenieSession.kt` + `lib/llm/on_device_engine_aidl.dart` (src: ai, 机制审计)

## 待裁决（需产品/架构拍板优先级）

- [ ] A1 端侧模型管理链复活拍板（archive/local_model 已归档零接线，需翻转裁决）
- [ ] A2 G6 网关独立进程化（防端侧模型 OOM 拖垮 PC 远程网关；thirdconnect §9.5/§10.5）
- [ ] A3 iOS 端侧引擎适配（MLX/Core ML 适配位；双端策略 §133-145，前置 macOS/Apple 账号）
- [ ] B1 端侧摘要器 `$ref` 注水真机实证（m3 头注 / host-gateway §3.5）
- [ ] B2 阶梯截断 + 端侧摘要归档（context-stepped-pruning.md draft 转正）
- [ ] C1 端侧 PII 模型层（非结构化 PII；架构 §219 T7+）
- [ ] C2 多模态 PII 检测模型（FC2，触发=M3+ 多模态接入）
- [ ] D1 移动端生命周期与重连韧性钩子（host-gateway §10.1）

## 已锁定（机制已落地，仅跟踪）

- [x] 超大 Tool Result 硬截断（D-I `kToolResultHardCap=2000t`）
- [x] Loop Storm 环路防护（`hop_count≤2` 熔断）
- [x] N7 正则四类 PII + 无人值守 fail-closed
