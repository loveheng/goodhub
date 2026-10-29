---
memo: todos
format: v3
epic: on-device
---

# on-device · 域内待办

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
