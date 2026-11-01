---
memo: todos
format: v3
epic: on-device
---

# on-device · 域内待办
- [ ] [2026-11-01] (风险) UDS 数据面断线自愈重建时借鉴 IRIDIS「KV 失败对齐纪律」：任何失败/中断后强制 KV 状态与会话记录重新对齐再重试，防脏 KV 静默污染后续生成 (src: ai) (src: ai)
- [ ] [2026-11-01] (优化) 温控中间降级档评估：IRIDIS 式 currentThermalStatus 动态减线程+绑核热生效（llama_set_n_threads / sched_setaffinity），作为 Thermal→全量切云前的缓冲档；注意与「热降频绝不分流矩阵运算到 CPU」禁令的边界 (src: ai) (src: ai)
- [ ] [2026-11-01] (功能) capability 转发层多调用方并发预留请求归属：:engine 数据面协议借鉴 IRIDIS GenOwner 归属制取消（A 入口停止不杀 B 入口生成），落到 UDS 成帧协议或 AIDL 层评估 (src: ai) (src: ai)
- [ ] [2026-11-01] (功能) GenieX 落位时照抄 IRIDIS 踩坑清单：运行库按需下载 + 按 Hexagon 代际裁剪库文件（GenieXLibs：51 库→≤20，82MB 大幅瘦身，goodhub :engine AAR 同法）+ geniex_get_error_message→结构化错误码映射（含 QAIRT 上下文编译期固定/Parameter not supported 等真坑）+ 错误信息保留原始异常链不吞 (src: ai) (src: ai)
- [ ] [2026-11-01] (功能) 上下文治理落地：按 draft §4 落 steppedWindow 纯函数 + agent_loop 挂钩，摘要块位置纪律（System 后独立 UserMessage + frozenBase）照搬；kTickTokenBudget token 突发兜底从 §5 后续演进提为同期实现 (src: ai, 用户) (src: ai)
- [ ] [2026-11-01] (文档) 修订 context-stepped-pruning.md：补「端侧不做前缀稳定裁剪」裁决 ADR（Genie 前缀复用不可控+无计费压力，阶梯降频已覆盖）并把 draft 翻 active（待 GPU Spike KV 数据）；采纳用户拍板「云端逻辑精简版」而非 IRIDIS 式 (src: ai, 用户) (src: ai)
- [ ] [2026-10-31] (风险) [long] [Decision] G1 已关闭（ADR 终裁 2026-10-31）：QAIRT SDK 不装/私有方法不探测 → 维持现状为终态（SDK 文本回调+StreamTextSanitizer+Dart identity 直通）；唯一后续通道 = 向 geniex-android/Qualcomm 登记上游 issue（detokenize 单字节解码拆散 UTF-8 多字节字符，期望输出侧 token-id 或修复边界）；SDK 未来暴露 token-id 或修复 → 重开 G1 评估 (src: 用户) (src: ai)
- [ ] [2026-10-31] (修复) [评审#6] 原语流取消传导：OnDeviceCapabilityService._generateWithSlotWait 消费方取消后未调 cancel(requestId)——在途生成跑满 maxTokens 占单执行槽挤占前台 2s 窗口；修法=await-for onCancel 联动引擎 cancel 通道；随原语对外导出（Step2/P2）立项评估 (src: ai) (src: ai)
> 引擎层取消通道已就位（`StreamController(onCancel: () => cancel(requestId))`，`on_device_engine_aidl.dart:485`）；`_generateWithSlotWait` 经 `await for` 消费该流，取消可向上传导。残差：是否真传导到消费方（AgentLoop/mcp_runtime 切实 cancel 上层 Future）未验证，devlog 未记录收口 → 保留待验证。
- [ ] [2026-10-31] (修复) [评审#4] F2 比对旁路收口：:engine 侧 loadedModelId 为空时 modelId 失配检查整体跳过（静默放行）——按「身份锚点缺失应留痕或拒绝」精神收口（实际难达：modelId 空值已退化目录名）；随真机轮评估 (src: ai) (src: ai)
> F2 已落地（devlog 312）但 `EngineService.kt:402` 比对仍以 `loadedModelId.isNotEmpty()` 为前提——空值（modelId 退化目录名）时整体跳过静默放行，正是本评审点。属已知难达项，保留 open。
- [x] [2026-10-31] (优化) [F5 余项·D2] 序数编译期门禁评估：双端锚定钉（test/llm/on_device_engine_status_test.dart ↔ EngineStatusOrdinalTest.kt，已含 7/8/9 锚）即当前门禁；schema SSOT+双向生成脚本需走 agent-toolbox spec 登记制，工具化收益待第三次加态时再评（届时触发） (src: ai) (src: ai)
> 双端锚定钉已就位（devlog 313：EngineStatusOrdinalTest exit 0，序数 9 unknownNeedReconcile 同轮锚定）。schema SSOT+双向生成脚本按原 todo 递延（待第三次加态触发），非阻塞。
- [x] [2026-10-31] (测试) [F6] 混沌矩阵真机回归（kill×rebind×evict×reload×资产替换）扩矩阵：新增 modelId 失配重装用例 + 装载停滞 LOAD_STALLED 用例；验收=§6 验收 1 全组合零漂移；前置=F2/F4 (src: 用户) (src: ai)
> 驱动器+用例骨架已就位（`scripts/agent-tools/on-device-chaos-matrix.sh` 六例；devlog 314）。**用户 2026-11-01 确认 F 功能已实机验证**——devlog 315「验证: 未执行」为登记驱动器时的记录缺口，非未做。前置 F2/F4 已落地。
- [ ] [2026-10-31] (优化) [F5] 清账专项：C1~C8 物理删除（diagPanic/_batchDiagCount/过期注释/静默默认值/modelIdOf 静默降级收窄/吞异常面收窄/StreamTextSanitizer 与 StreamingDetokenizer 坏字节重建物理拆除）+ D2 序数编译期门禁（schema SSOT+双向校验脚本）+ 熔断双轨（PrimitiveFailureCounter 隔离，[DEGRADE] 标记化降级）+ PII 围栏原语入口收口；验收=uscan/dscan 零残留 (src: 用户) (src: ai)
> 已落地部分（devlog 312）：diagPanic 四处退役、`_batchDiagCount` 修正、过期注释收口、modelIdOf `DEGRADE` 留痕、熔断双轨 PrimitiveFailureCounter、PII 入口 PrimitiveInputFilter（fail-closed）。**作废项**：「StreamTextSanitizer 与 StreamingDetokenizer 物理拆除」被 G1 终裁取消（现状定性为合法方案，非治标补丁）。验收 `uscan/dscan 零残留` 未运行验证。
- [x] [2026-10-31] (优化) [F4] D5/D6 装载活体：AIDL 分阶段回调（PARSING/ALLOCATING/WARMING_UP）+ 阶段有界硬超时；超时由 :engine 自签 LOAD_STALLED 终态票据走 reloading 冷重载链路自裁，主进程不新增 SIGKILL 权（保墓碑排除法纯粹性）；验收=混沌矩阵含装载停滞用例；前置=F2 (src: 用户) (src: ai)
> 已落地（devlog 312 + `EngineService.kt:139` LOAD_STALLED 看门狗 90s 自裁、`IOnDeviceEngineListener` PARSING/ALLOCATING 回调）。残差：仅 PARSING/ALLOCATING 两阶段，**WARMING_UP 未实现**（AIDL 仅定义 0/1）。
- [x] [2026-10-31] (优化) [F3] D1 大载荷通道：长 Prompt/历史走共享内存或 fd，解除 Binder 事务上限；传输约束与 2B 模型 KV-Cache 推理窗口解耦立法（阶梯截断保留）；验收=长上下文真机回归无 TransactionTooLarge；前置=F2 (src: 用户) (src: ai)
> 已落地（devlog 312 + 316#1）：`promptJson>60000` 字符走临时文件 `promptFilePath`，:engine 受理段读后即删，Binder 只传短元数据；与 KV-Cache 推理窗口解耦立法。验收经用户 2026-11-01 确认 F 功能实机验证覆盖（含长上下文大载荷）。
- [x] [2026-10-31] (修复) [F2] expectModelId 进 startGenerate 原子比对（:engine 单入口加维度，SESSION_MODEL_MISMATCH 新拒绝码，Dart 作废镜像走重装）+ engineStatusFromOrdinal 越界映射 UNKNOWN_NEED_RECONCILE；验收=纯 Dart 回归钉+双端序数锚定钉；前置=F1 (src: 用户) (src: ai)
> 已落地（devlog 312 + 代码四层：AIDL:57 / Bridge:215 / EngineService.kt:402 / Dart:617；序数 9 `unknownNeedReconcile` 双端锚定）。关联 评审#4 残差：loadedModelId 空值仍跳过比对。
- [x] [2026-10-31] (功能) [F1] OnDeviceCapabilityService 门面落地：complete(instruction,input,PrimitiveConfig,fallbackPolicy) 无状态原语（failFast/degradeToCloud/degradeToTruncate 三档类型化降级，[DEGRADE] 标记化），摘要器改接原语并接入 mcp_runtime 生产链，删除 ChannelLlmEngine 废弃引用；验收=flutter analyze+相关测试+真机摘要冒烟 (src: 用户) (src: ai)
> 已落地（devlog 310）：`on_device_capability.dart` 门面（complete + 三档 [DEGRADE] + 2s 槽位等待 + 懒加载边界）+ OnDeviceResultSummarizer 改接原语接入 mcp_runtime + debug_run_orchestrator 摘 ChannelLlmEngine generate 依赖。偏差：`ChannelLlmEngine` 探针引用按设计保留（devlog 明示），"删除废弃引用"以"摘 generate 依赖"口径达成。验收经用户 2026-11-01 确认 F 功能实机验证覆盖（含摘要器冒烟）。
- [ ] [2026-10-31] (功能) [long] [Decision] (暂缓) 扩展点：能力原语化 + 跨 App 转发——goodhub 侧只提供模型能力原语 complete(instruction,input,config)->String（不含任务模板）；摘要/翻译/打标签/文本优化等具体任务语义由其他 MCP 服务编排实现；其他 App（如 goodshare app）经 goodhub 转发调用端侧模型能力与云端能力。前置=OnDeviceCapabilityService 公共服务面（on-device-capability §2）+ G6 :gateway 独立进程 + P2 立项裁决 + 跨仓接缝同步 ai-app-split.md (src: 用户) (src: ai)
- [x] [2026-10-30] (功能) (层:L2) (重:中) OD2 前台提示消费（UI 侧）（已接线 2026-11-01：`chat_page.didChangeAppLifecycleState→resumed` 消费 `OnDevicePendingLoad.hasPending()`——命中即 `_toast('已检测到后台端侧任务：下次对话将自动启动端侧加速')` 并 clear；**只提示不抢槽**（devlog 227④）：不主动调 enable()，下次对话请求经会话闸门自然触发装载，单执行槽零争抢；无论回前台时是否有在途请求都消费——在途请求本身就是前台流程；措辞按「不抢槽」口径诚实化，不谎称已在装载。验证：chat_page analyze 0 issue + chat_page_smoke_test 10/10 绿）：场景 B 后台冷装载已打 PendingForegroundLoad 标记（TTL 30min），UI 消费未接 (src: ai,2026-10-30 OD2 遗留)
- [x] [2026-10-30] (优化) (层:L1) (重:重) OD5 资产迁入应用内部私有目录（已落地：生产 OTA 通道 `OnDeviceAssetManager.ensureAssets` + 导入通道 `importFromPickedFiles` + 导入校验 `_isImportedVerified` 均落 `getApplicationSupportDirectory()/models/`（内部私有目录）；todos 文字「外置 FUSE」系 S2-1 冒烟通路旧状态，已被 S2-2 取代）；todos 中「存量迁移/导入通道改写」亦随导入制（2026-10-31）落地完成：外置 FUSE 双份缓冲 + mmap fadvise 失效已消除 (src: 用户,2026-10-30 裁决 OD5（P0 专项）)
> 残差（已定谳销项 2026-11-01）：① `on_device_smoke.dart` 已随 S3 换线物理删除（devlog 98 退役清单第⑤条），全仓无 smoke 引用——外置路径不存在于任何生产代码；② 生产从未走外置 FUSE，无遗留资产需迁移。两项均空集，OD5 终态。

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

- [x] [2026-10-31] (风险) (重:重) **P0-15 空闲驱逐后恢复链路断裂 + 端侧运行零感知**（已修三缺口，详见 decisions.md 同日 ADR）：① `loadedOnce` 拒绝同进程重载复用 `assetMissing` 终态序数 → 「回收后重载」报「请重新导入模型」且判死不重试（改 `EngineStatus.reloading` 序数 8 + Dart 可重试中断 + 短退避分档 + `expectRestart` 防快死棘轮误抬水位）；② 桥面 `bind()` 幂等判据 `connection != null` → 断连后永久 no-op、恢复只剩 AMS 自动重启一条腿（改「活引擎在位」判据 + 断连即时重绑 + 连接对象缓存复用）；③ `OnDeviceLoadState.loading` 全仓无人写入（UI 加载指示死代码）+ 驱逐静默零提示（装载起跑即置 loading + AppBar 端侧状态芯片 + 转场瞬态提示 + 装载在途时进程死亡不复位 loadState）| 红线：`reloading` 为可重试中断非终态，禁再借用任何终态序数捎带过程语义；双端序数锚定钉（`on_device_engine_status_test` ↔ `EngineStatusOrdinalTest`）漂移即红 | 落点 `EngineService.kt` + `EngineServiceBridge.kt` + `EngineStatus.kt` + `IOnDeviceEngineService.aidl` + `on_device_engine.dart` + `on_device_engine_aidl.dart` + `chat_page.dart` (src: ai, 用户报告「端侧过段时间不可用且无感知」评估轮)

### P1（机制缺口 / 特定场景功能降级）

- [x] [2026-10-30] (风险) (重:重) **P1-4 路由无前台/后台维度 + `paused→release` 主动击杀在途**（已修：路线 B 一次收口两半 —— ① FGS 改「绑定即挂」使后台任务期间 :engine 受前台提权保护，免 OEM 冻结 / mem-pressure 回收；② 退后台钩子移除 release，权重回收完全交 `:engine` 侧 TTL（空闲 5min）+ 内存预算护栏）：`HybridCloudEngine.send` 判据仅 offline/降级冷却/偏好/工具面，不含前后台；`main.dart` paused/hidden/detached 无条件 `release()`（不看在途、不看 FGS）→ 交互式生成中息屏必被 abort 空产出；后台任务×端侧组合无 FGS 且被 trim 击杀；FGS 预挂与 paused→release 语义相反无仲裁 | 红线：有在途生成或 FGS 挂着时禁止 release（走 `releaseIfIdle`）；与 P0-1/P0-3 成组收口 | 落点 `lib/coordinator/hybrid_cloud_engine.dart` + `lib/main.dart` + `lib/llm/on_device_engine_aidl.dart` (src: ai, 机制审计)
- [ ] [2026-11-01] (风险) (重:中) **P1-5 端侧路径输入零预算（设计已定稿 2026-11-01，机制落地挂 draft）**：`_deviceSend` 把 system + 全部历史（含 tool result）压平单发，输入侧无 token 预检；`n_ctx` 编译期固定，超窗 SDK 行为未实证 | **设计定稿（2026-11-01）**：① 预算来源 = 资产面声明（asset-meta 携带 n_ctx），运行时无读取通道（G1 已关闭不可用），未知时保守默认并 UNCERTAIN 标注；② 超窗处置 = **拒绝优先**——预检超窗显式报错切云（产出优先），**不在设备路径发明第二套截断**，阶梯截断（高低水位+端侧摘要归档）是上下文治理唯一机制，归 context-stepped-pruning.md draft 落地时统一接入；③ 预检位置 = `_deviceSend` 入口、`buildOnDeviceChatPromptJson` 之后 `generateStream` 之前；④ 超窗 SDK 行为（尾部截断 vs 报错）UNCERTAIN，观测钩子与 P2-12 同批真机执行 | 红线：机制未定稿前禁写截断代码；拒绝路径须复用「可自愈 vs 终态」口径 | 落点 `lib/coordinator/hybrid_cloud_engine.dart` (src: ai, 机制审计)
- [x] [2026-10-30] (功能) (重:重) **P1-6 端侧流式在 hybrid 层被截成单发聚合**（已修 2026-11-01：Expand-Contract 三步单轮收口——`OnDeviceLlmEngine` 契约 `Future<String?> generate` → `Stream<String> generateStream`（零产出=无事件 close、失败经流错误穿透、取消=退订联动 cancelActive），AIDL 适配器真流式覆写（双层控制器），hybrid `_deviceSend` 逐 delta 投递 `CloudTextDelta`，零产出归因/切云/取消链路全保留；archive 探针页与测试桩同步迁移，旧 generate 物理删除；flutter analyze 0 issue + 1468 测试全绿）：契约 await 收满全文才一次投递 → 512 token×~60ms≈30s 无出字 | 红线：纯装配层缺口，引擎侧零改动（成立：AIDL 引擎 `Stream<EngineChunk>` 原样消费） | 落点 `lib/llm/llm.dart` + `lib/llm/on_device_engine_adapter.dart` + `lib/coordinator/hybrid_cloud_engine.dart` (src: ai, 机制审计)
- [x] [2026-10-30] (风险) (重:中) **P1-7 `waitReady` 3s 超时判终态失败**（已修 2026-11-01：装载(:217)与生成(:548)两处硬编码 3s → 共享常量 `kWaitReadyTimeout=10s`（与 binding 默认窗口对齐防双源，覆盖冷启动实测 3~8s）；超时口径本就 retryable/交会话闸门走装载链或切云非终态，注释钉死；test/llm 192 项全绿，无测试钉 3s）：弱机冷启动 3~8s 常态 > 3s → 新装首请求「未就绪」空转 | 红线：可自愈等待与终态失败分口径（守住了：超时归 retryable） | 落点 `lib/llm/on_device_engine_aidl.dart` (src: ai, 机制审计)
- [ ] [2026-10-30] (风险) (重:中) **P1-8 停用词/采样参数三层「存在但失效」**：AIDL 注释已诚实标注（temperature/topP 过渡期取资产默认、stopTokenIds 归 S3），但 Dart `GenerationConfig` 注释不标失效；`EngineService.startGenerate` 只读 maxTokens/foreground；`GenieSession.query` 不传采样参数；detokenizer 纯字节重组无 stop-sequence 事后扫描补偿 | 红线：单发提取语义最依赖终止边界，失效=过度生成（NPU 空烧 + 输出边界漂移 + 提取解析可能破）；契约「看起来生效」与实际背离须在三层各标一行 | 落点 `IOnDeviceEngineService.aidl` + `EngineService.kt` + `GenieSession.kt` + `lib/llm/on_device_engine.dart` (src: ai, 机制审计)

### P2（机制脆弱 / 文档-实现不一致）

- [x] [2026-10-30] (风险) (重:中) **P2-9 熔断 L2 24h 锁「当天」边界未实现**（已修 2026-11-01：L2 判据重定为持久化 L1 触发时间戳列表（新键 `on_device.engine.l1_trigger_at`），report 时本地自然日剪枝 + 同日 ≥2 次跨重启累计触发 L2 并清列表，reset 同步清持久化；新增跨重启同日累计/跨日剪枝两条回归，全量 1468 全绿）：`_l1TriggerCount` 进程内存计数无日界 → 稀疏崩溃（>5min 间隔，坏驱动画像）永不达 L2，文档双向不符 | 红线：L2 覆盖稀疏崩溃场景（已达成：跨重启累计）；`_l1WindowStart` 锚点式窗口非真滑动（维持可接受） | 落点 `lib/llm/on_device_circuit_breaker.dart` + `docs/design/on-device-npu-deployment.md` §6.5（文档 §6.5 表述对齐待 docs 轮） (src: ai, 机制审计)
- [x] [2026-10-30] (风险) (重:中) **P2-10 SPSC `read_idx` 双写竞态（回退态未覆盖）**（已修：消费端推进改 CAS max 单调 + 写侧游标只向前 + 满判据 `>=`）：两个写者 = 消费端 drain 推进 + `:engine` `clearPending`（readIdx=writeIdx）；失步钳制只处理 `avail > capacity`（回绕态，gdw-ring-desync 已修），未覆盖回退态 = 在途 drain 已读 r=100 → clearPending 写 120 → drain 回写 101（lost update）→ 上一代请求尾字节混入新流；identity UTF-8 载荷大概率仍合法文本 → 静默污染无 FormatException | 红线：最高频触发 = 前台连发（第二消息抢占 abort × 在途 drain，~40ms 微批窗口）；游标单调性须由单一写者保证 | 落点 `cpp/engine_data_worker.cpp` + `engine/TokenRingBuffer.kt` (src: ai, 机制审计)
- [x] [2026-10-30] (风险) (重:轻) **P2-11 内存护栏单点采样 + 增量指标对全系统波动敏感**（已修 2026-11-01：生成期护栏周期采样——`startGuardSampler()` 守护线程每 5s 调 `checkMemoryGuard()`，query 前 start、finally 中断后保留收尾单次终态快照；护栏触发与收尾同走 `lifecycle.onGuardBreached`；绝对地板（availMem 1GB）评估器本已具备，`:app:compileDebugKotlin` 通过）：`checkMemoryGuard` 只在 finally 采样一次，生成峰值段零覆盖 → 「逼近 LMK 提前驱逐」只兑现 1/N | 红线：其他 app 增配误驱逐——增量线 6GB（用户拍板）+ 地板 8MB 抖动容差已对齐；**阈值真机校准仍归 S2-5 批次（2.5GB 推拍遗留已随 6GB 拍板销项）** | 落点 `EngineService.kt` + `engine/MemoryGuardEvaluator.kt` (src: ai, 机制审计)
- [ ] [2026-10-30] (风险) (重:中) **P2-12 Prefix Cache 复用声称与每请求 `reset()` 相矛盾**：AIDL/EngineService 声称「重放同前缀命中运行时前缀缓存（llama.cpp prompt cache 层）」，但 `GenieSession.query` 每请求前置 `w.reset()` 清空上下文；若 geniex 的 `reset()` 连带清 prompt cache（SDK 无源码、未实证），则 §2.4 Prefix Cache 主路线在端侧整体失效，多轮压平每次全量 prefill | 红线：文档声称须实证后再留，否则属幻影契约；S2-5 复用观测钩子未执行 | 落点 `IOnDeviceEngineService.aidl` + `EngineService.kt` + `GenieSession.kt` (src: ai, 机制审计)
- [x] [2026-10-30] (风险) (重:中) **P2-13 cancel/热切云经 `runBlocking stopStream` 阻塞共享线程**（已修：devlog 206 `GenieSession.abort()` 改后台线程 + 有界等待 ≤300ms，占死 Binder 线程池场景消除）：`GenieSession.abort()` 的调用方含 Binder 线程池（cancelGenerate）、PowerManager listener 无 executor 版 = `:engine` 主线程（热切云）、前台抢占 → 热状态突变瞬间 stopStream 阻塞主线程，全部 Binder 分派停摆；抢占等待 1.5s 可能被 stopStream 吃掉 → DENIED_TIMEOUT → 前台请求切云（「绝不驳回用户」降级为「绝不立刻满足」） | 红线：注释「生成循环 token 粒度检查 m_abort 即时跳出（SDK 源码实证）」是旧裸 Genie C API 语义，S3 换线后已过期，现靠 SDK stopStream，响应性未实证 | 落点 `GenieSession.kt` + `EngineService.kt` (src: ai, 机制审计)
- [x] [2026-10-30] (功能) (重:中) **P2-14 装载失败原因丢失**（核心已修：loading 序数 7 解耦受理/终态 + getLoadError 查询面 + assetMissing 短路修复，devlog 177/185/257/270；残差=getLoadError 终态归因细化 仍 open，decisions.md 15）：loadModel 的「受理中」「资产缺失」「SDK init 失败」「管线 build 失败」在 checkStatus 下全部呈现为 `assetMissing`（受理/终态共用序数），enable 轮询满后报「模型装载失败（assetMissing）」→ 把驱动/SDK 故障导向「重新下载模型」的错误补救；`loadError` 仅供 `:engine` 本地日志，AIDL 无 `getLoadError` 查询面 | 红线：终态归因不可与过渡态共用枚举序数（gdw-enable-accepted 的半开缺口） | 落点 `IOnDeviceEngineService.aidl` + `EngineService.kt` + `GenieSession.kt` + `lib/llm/on_device_engine_aidl.dart` (src: ai, 机制审计)

## 治本工程待实施（2026-10-31 决策落定·代码未落地）

> 来源：decisions.md 两条 ADR（数据面唯一真相源 / 死因可见性·墓碑机制）。代码层核实结论 = 两条均"已拍板、零落地"，当前仍是决策要废止的双补丁架构 + `livedMs<30000` 概率推断。开工前按 solution-admission 单项放行；锚点 = decisions.md 对应 ADR 的"最终决定/收敛条件"。

### G1 数据面唯一真相源落地（token-id + GHDT 替文本双补丁）

> ⛔ **阻塞于 SDK·等 Qualcomm 上游 issue**：SDK 流式回调仅返回文本（`LlmStreamResult.Token.text`，见 `GenieSession.kt:349`），无 token-id 出口；ADR（2026-10-31，见 `:14`）已终裁「维持现状为终态」，重开条件 = SDK 暴露 token-id 或修复输出侧 UTF-8 边界。G1-1/2/3 在 SDK 提供 token-id 前**无法开工**，唯一推进通道 = 向 `geniex-android/Qualcomm` 登记上游 issue。

- [ ] [2026-10-31] (风险) (重:重) (层:跨端) **G1-1 废弃 Kotlin `StreamTextSanitizer`**：`GenieSession.query()` 仍活跃使用（`val sanitizer = StreamTextSanitizer()` L336 + `feed/fluash` L370/378/385），是决策要彻底废弃的 SDK 文本回调修复层；与 Dart 侧修复层并存 = 决策点名的"双端补丁" | 红线：删除前必须先有 token-id 生产链路接管（G1-3），否则删后乱码回归 | **阻塞于 SDK·等 Qualcomm 上游 issue** | 落点 `GenieSession.kt` (src: ai, 代码核实 2026-10-31)
- [ ] [2026-10-31] (风险) (重:重) (层:跨端) **G1-2 Dart `StreamingDetokenizer` 退出 identity 直通态**：生产态用 `_identityTable`（i→[i]，L832-835）做 UTF-8 字节重组，**非** GHDT token-id 解码；真 `TokenByteTable` 仅 `on_device_detokenizer_test.dart` 测试态，未入生产流 | 红线：identity 表路径随 G1-3 真 GHDT 接管后整体退役，含 `on_device_detokenizer_test.dart` 中 identity 用例 | **阻塞于 SDK·等 Qualcomm 上游 issue** | 落点 `on_device_engine_aidl.dart` + `on_device_detokenizer.dart` (src: ai, 代码核实 2026-10-31)
- [ ] [2026-10-31] (功能) (重:重) (层:跨端) **G1-3 数据面载荷切 token-id + `libgdw` 原子组装**：现状 `engine_data_worker.cpp` 仅 TLV 帧转发 UTF-8 文本字节（kTypeToken 原样 postFrame），无 token-id 解码、无 GHDT 表加载、无多字节滞留 RingBuffer | 实施：① Kotlin `SocketTokenWriter` 写 token-id 微批（非 text），帧协议增 token-id 承载（复用 TOKEN 帧改 int 数组或新类型）② `libgdw` 加载 `tokenizer.id2byte.bin`，Worker 内做 `id→bytes→UTF-8` 滑动窗口原子组装（未完成多字节滞留 RingBuffer 绝不外抛），只向 Dart 投合法 String ③ Dart 只收 String | 验收：生产路径全量 token-id（无文本字节越数据面）；`StreamingDetokenizer`/identity 表退役；`libgdw` 单测覆盖"跨帧多字节滞留 + 完整字符才外抛"；真机「中→ä¸­」类乱码零复现 | **阻塞于 SDK·等 Qualcomm 上游 issue** | (src: ai, decisions.md ADR + 代码核实 2026-10-31)

### G2 死因可见性·墓碑机制（排除法裁定 LMK_SIGKILL vs 硬崩溃）

- [x] [2026-10-31] (风险) (重:重) (层:跨端) **G2-1 `:engine` 写 `<pid>.flag` 墓碑**：当前 `GenieSession` 仅 `creating`/`ready` 内存位（进程死即失），无 `FLAG_LOADING`/`FLAG_READY` 标记文件；loadModel 受理前 FLAG_LOADING、SDK `create` 返回后 FLAG_READY，正常退出清标记（PID 复用须 stale flag 处理） | 落点 `GenieSession.kt` + 标记文件读写工具 (src: ai, decisions.md ADR + 代码核实 2026-10-31)
- [x] [2026-10-31] (风险) (重:重) (层:跨端) **G2-2 JNI `sigaction` 落盘 Crash Stack**：`engine_data_worker.cpp` 仅 `::signal(SIGPIPE, SIG_IGN)`（L262），无 SIGSEGV/SIGABRT/SIGBUS 处理器；需注册捕获并将 PC/寄存器/backtrace 落盘崩溃目录（`:engine` 独立进程沙箱内可写） | 落点 `engine_data_worker.cpp` + `GdwNative.kt` (src: ai, decisions.md ADR + 代码核实 2026-10-31)
- [x] [2026-10-31] (风险) (重:重) (层:跨端) **G2-3 `DeathRecipient` 排除法裁定 + 结构化死因**：现状分类仍靠 `livedMs < 30000` 概率推断（fastKill 启发式残留）；须改为死亡时读 `<deadPid>.flag` + 崩溃目录 = 有 Stack→`HARD_CRASH`（驱动/SDK 崩溃，硬故障）/ 无 Stack + FLAG_LOADING + 整机内存低→`LMK_SIGKILL`（软故障）/ 无 Stack + FLAG_READY→运行期外部终止；裁决写结构化死因文件供下次启动被 `kEngineInterruptCodes` 消费驱动退火（#五 指纹分类前置） | 验收：真机 `am kill`/LMK 场景 100% 裁定 LMK_SIGKILL（不再靠猜）；野指针类硬崩溃落 Stack 判 HARD_CRASH；崩溃来不及清 flag 被 stale 处理不误判 | 落点 `EngineService.kt` + `on_device_circuit_breaker.dart` + `kEngineInterruptCodes` (src: ai, decisions.md ADR + 代码核实 2026-10-31)

> 注：G2 三项代码已落地（实现落点实为 `EngineService.kt` + `engine_tombstone.cpp` + `on_device_death_cause.dart`，与原清单落点描述略有偏差）。残存验收余项（非阻塞）：① `.stack` 读墓碑后未清理，PID 复用时可能误判 `hardCrash`；② 真机 `am kill`/LMK 场景 100% 裁定收敛未回归。

## 多栈框架构型子步骤（2026-11-01 四裁决落盘·代码未落地）

> 来源：decisions.md 同日 ADR「LiteRT-LM 内置底座 + GenieX 增配选装」四裁决（D-1~D-4）+ 联发科通道升格。开工前按 solution-admission 单项放行。

- [x] [2026-11-01] (功能) (重:重) (层:跨端) **D-3 AIDL 停用词契约重写**：`stopTokenIds: intArray` → `stopSequences: List<String>` 字符串下发，编码判定下沉各 Runner Native 自治（自绑 tokenizer 实时 match）；须覆盖 Genie 拒收现状（ErrorCode -100016，`GenieSession` 文本截断+sanitize 兜底不回归）；施工同轮修 goodshare `ai-dev-spec.md` §4（立法源） (src: 用户拍板 2026-11-01)
> 已落地（devlog 同日）：AIDL 注释/`GenerationParams`（Bundle stringArrayList + fromArgs）/`EngineService` 传参贯通；新增 `engine/StopSequenceMatcher`（跨帧滑动窗口匹配，默认 `<|im_end|>` 保持现行为，匹配在 sanitizer 输出后 = 用户可见边界；Kotlin 单测 6 例）；`GenieSession.query` 加 `stopSequences` 参、硬编码 im_end 截断退役；Dart `GenerationConfig` 字段 `stopSequences: List<String>`（预编码 id 字段双端同轮退役）；goodshare `ai-dev-spec.md` §4 新增「端侧推理接缝」条款。验证：`:app:compileDebugKotlin` + Kotlin 单测 11 绿；flutter analyze 0 issue + test/llm 200 全绿。关联 P1-8 的停用词失效面随本项收口（采样参数面 P1-8 仍开）。
- [ ] [2026-11-01] (功能) (重:中) **QAIRT 运行库单源化**：GenieX 增配（GenieXRuntime 4 件套）与 LiteRT-LM QNN dispatch 共享一份 `libQnnHtp*` runtime 依赖，统一 `nativeLibraryDir`/`setQairtRuntimePath` 指向，防双份捆绑符号冲突 (src: 用户拍板 2026-11-01)
- [ ] [2026-11-01] (功能) (重:重) (层:真机) **LiteRT-LM GPU/NPU 基准探针（D-4 能力对照）**：同口径真机基准（TTFT/TPOT/内存/发热），对照 llama_cpp+GPU 39 tok/s 基线；**llama.cpp 永久保留不删除**（2026-11-01 用户修订），基准数据仅归档作能力对照，不触发分支删除 (src: 用户拍板 2026-11-01)
- [x] [2026-11-01] (功能) (重:重) **首发节奏关闸（llama.cpp 先不放出，从 LiteRT-LM 起步）**：llama.cpp 通路代码保留但用户面不暴露——GGUF 导入入口、分发推荐、设置面关闸（feature flag/编译保留，代码与已实证能力不删）；首发资产路线 = 仅 `.litertlm` 族（LiteRT-LM 栈）；重评触发 = LiteRT-LM 首发稳定 + GGUF 资产链就绪，届时新 ADR 立项放开 (src: 用户拍板 2026-11-01)
> 已落地（devlog 同日）：编译期开关 `kOnDeviceLlamaCppEnabled`（`ON_DEVICE_LLAMACPP` 默认 false）+ 三闸（导入 UI 拒收 GGUF 直选 / `_select` 拒选 llama_cpp 模型 / `enable()` 装载闸兜底非 retryable 终态报错）；analyze 0 issue + test/llm 200 全绿。
- [x] [2026-11-01] (功能) (重:中) **资产路由 backend 维度（D-1 落地）**：`asset-meta`/分发推荐层加资产族（gguf/litertlm）→ 栈映射；`.litertlm` 按 SoC 分发（官方 NPU 目录现仅 Gemma3-1B，SM8550/8650/8750 + MT6989/6991，ctx 1280）；**首发仅接 `.litertlm` 分支**（GGUF 分支在码未启用） (src: 用户拍板 2026-11-01)
> 已落地（devlog 同日）：`OnDeviceAssetFamily`（geniex/litertlm/unknown + `familyOf` 单源映射）+ `OnDeviceRuntime.litertlm` + meta `family` 字段 + 结构校验 `.litertlm` 识别 + `kOnDeviceLiteRtLmEnabled` 装载闸（Runner 未集成 fail-fast）+ UI 徽标；test/llm 202 全绿。**SoC 分发键未实现**——导入制下无在线分发面，键=`ro.soc.model` 待分发面立项时接线（官方 NPU 资产按 SoC 精确分发，跨 SoC 不互通同 GGUF ctx-bin）。后续主体 = LiteRT-LM Runner 集成（独立工程，落地时翻 `kOnDeviceLiteRtLmEnabled`）。
> 联发科（2026-11-01 用户修订）：**接口留位，现阶段不支持**——Runner 注册表预留 NeuroPilot 扩展位，不实现、不排期真机实证；重评触发 = `.litertlm` NPU 资产目录扩展（出 3B 级/多模型）或天玑旗舰真机到位，届时回 decisions.md ADR 立项（路线 = LiteRT-LM + NeuroPilot Delegate，免 GenAI Toolkit 企业 NDA）。

- [ ] [2026-11-01] (功能) (重:重) **LiteRT-LM Runner 集成（多栈主体工程，独立会话开工）**：① `:engine` 内新增 LiteRT-LM Runner（litertlm-android 0.16.0 钉版数据已在 geniex-0.10.0-pins.txt 备查；`ModelRunner` 执行契约 = 装载/生成流/release + getHardwareType）② 装载链：资产族路由进 doLoad——family=litertlm → LiteRT-LM Runner（翻 `kOnDeviceLiteRtLmEnabled`），geniex 系走既有 GenieSession ③ 停用词：Runner 自治匹配（复用 `StopSequenceMatcher`，D-3 契约）④ QAIRT 运行库单源化随本轮（GenieX 4 件套与 LiteRT-LM QNN dispatch 共享一份 `libQnnHtp*`，统一 `nativeLibraryDir`/`setQairtRuntimePath`）⑤ 基准探针：LiteRT-LM GPU/NPU 同口径真机基准（TTFT/TPOT/内存/发热，对照 llama_cpp+GPU 39 tok/s，仅归档不触发删除）⑥ 真机 = Ace 6（SM8750，.litertlm NPU 支持表在列）；验收 = 装载→生成→停用词命中→降级链全绿 + 关闸面回归。前置阅读：decisions.md 2026-11-01 多栈 ADR + capability v3.3 + 本节已落地三项（关闸/D-3/资产族） (src: 用户拍板 2026-11-01)

## 待裁决（需产品/架构拍板优先级）

- [ ] A1 端侧模型管理链复活拍板（archive/local_model 已归档零接线，需翻转裁决）
- [ ] A2 G6 网关独立进程化（防端侧模型 OOM 拖垮 PC 远程网关；thirdconnect §9.5/§10.5）
- [ ] A3 iOS 端侧引擎适配（MLX/Core ML 适配位；双端策略 §133-145，前置 macOS/Apple 账号）
- [ ] B1 端侧摘要器 `$ref` 注水真机实证（m3 头注 / host-gateway §3.5）
- [ ] C1 端侧 PII 模型层（非结构化 PII；架构 §219 T7+）
- [ ] C2 多模态 PII 检测模型（FC2，触发=M3+ 多模态接入）
- [ ] D1 移动端生命周期与重连韧性钩子（host-gateway §10.1）

## 已锁定（机制已落地，仅跟踪）

- [x] 超大 Tool Result 硬截断（D-I `kToolResultHardCap=2000t`）
- [x] Loop Storm 环路防护（`hop_count≤2` 熔断）
- [x] N7 正则四类 PII + 无人值守 fail-closed

## 挂起（外部依赖，机制已就绪）

- [ ] (外部依赖: 高通 Maven 发版) 增配包换版实战 0.10.0→N：checklist 四步见 `docs/design/on-device-npu-runtime-split.md` §8 P4 行（VERSION/PINS 重生成 → 插件 API 面复查 → REINSTALL 换版演练 → bench 对照）
- [ ] (外部依赖: 真机到位) 多机型增配覆盖 v73/v75/v81：installSet 三档映射已走查确认，缺各档真机实证（v73/v75 仅核心档 llama.cpp GPU、v81 QAIRT 集）
