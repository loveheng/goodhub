---
memo: todos
format: v3
epic: on-device
---

# on-device · 域内待办
- [ ] [2026-11-03] (风险) (long) llm_model.dart 内置目录三模型条目仍为代码数据（旧下载目录路径，有 manifest 云端覆盖通道；纯导入制后已边缘化）——随旧通道退役或迁配置时一并处置，暂登记防漂移 (src: ai) (src: ai)
- [ ] [2026-11-03] (功能) (候) TTS/STT 语音输入与朗读（竞品 Layla/MLC Chat 有；依附引擎侧能力成熟后一并评估）(重:重) (src: ai)
- [ ] [2026-11-03] (功能) 按模型绑定的 chat template / 会话预设机制（Qwen/Gemma 模板差异大，换模型即换模板是端侧刚需；竞品按 HF 元数据自动选）(层:L3)(重:中) (src: ai)
- [ ] [2026-11-03] (功能) 端侧 RAG 基座：端侧 embedding 模型 + 本地检索，与资源中心 $ref 句柄注入整合（竞品 Layla/本地知识库类已有，goodhub 全空位）(层:L2)(重:重) (src: ai)
- [ ] [2026-11-03] (优化) 端侧运行时性能统计透出 UI：tok/s、TTFT、上下文占用（on_device_bench 数据已有，缺消费面）(层:L4)(重:轻) (src: ai)
- [x] [2026-11-03] (功能) 端侧采样参数下发链：meta modelProfile.recommendedSampling 落地并下发 GenerationConfig（层:L3）(重:轻) (src: ai)
> 已收口（2026-11-03 落地，11-04 盘点轮销账）：S1 下发链落地（OnDeviceSamplingPreset + fromMeta 解析 + generateStream 请求级 temperature/topP + _deviceSend 覆盖）+ 规格声明迁 assets/model-specs.json per-bundle 规格表（e05bed9 通用实现纪律治理，加模型=加一行配置零代码；无命中行=字段缺席、表不可读=空表降级）
- [ ] [2026-11-03] (功能) 复活端侧模型管理链：本地 GGUF 导入 + 远程下载 + 量化版本选择（archive/local_model/ 已归档零接线，用户自带模型入口缺失，所有开源竞品的入门口）(层:L3)(重:重) (src: ai)
## IRIDIS 借鉴轮残留（2026-11-03 盘点降级：前提漂移，全触发器型，不排期）

- [ ] (触发: 真机出现「中断/取消后输出污染」证据) KV 失败对齐纪律——三个注入源已堵（SPSC 回退态竞态 P2-10 / 驱逐死亡反向同步 P0-3/P0-15 / 每请求 reset+坏后端记账），KV 复用系 Genie 黑盒（S2-5 零收益），攻击面大幅收窄 (src: ai, 2026-11-03 盘点)
- [ ] (触发: llama.cpp 重开发布) 温控中间降级档——动态减线程仅 llama.cpp 管线可行（已首发关闸）；litertlm/geniex 无线程控制面（S3-1 边界留痕），现有 SEVERE 全切云+迟滞已是上限 (src: ai, 2026-11-03 盘点)
- [ ] (触发: P2 多调用方并发立项) GenOwner 请求归属——现架构单执行槽+service_busy 驳回（S3-3 策略 B），「A 停止不杀 B」问题不存在，勿提前建机制 (src: ai, 2026-11-03 盘点)
- [ ] (触发: 真机踩到未映射的 geniex 错误码) geniex_get_error_message 结构化映射逐个补——库裁剪瘦身已被清单化+RuntimeChannel 按代际分发结构性消化（geniex-v79 仅 9.7MB），错误大头已被 cmaProbe+G2 死因指纹覆盖 (src: ai, 2026-11-03 盘点)
> 已收口（2026-11-03 盘点实证，代码面零缺口）：steppedWindow §4 User 回退修正（context_governor:88-92）、_withArchiveSummary §2.2 位置纪律（agent_loop:575）、§2.1/§2.3 阶梯与 DEGRADE 降级、§6.4 kTickTokenBudget 突发兜底（memory_governor:62 + chat_run_orchestrator:135 接线）全部在位。
> 已收口（2026-11-03）：§2.5 裁决 ADR 落稿（三依据：端侧零计费+前缀复用黑盒收益坍塌 S2-5 实测 / 阶梯降频已覆盖+D-4 NPU 档 TTFT 102~142ms / 复杂度不对称），draft → active；docs-lint OK + coordinator 507 全绿。
- [ ] [2026-10-31] (风险) [long] [Decision] G1 已关闭（ADR 终裁 2026-10-31）：QAIRT SDK 不装/私有方法不探测 → 维持现状为终态（SDK 文本回调+StreamTextSanitizer+Dart identity 直通）；唯一后续通道 = 向 geniex-android/Qualcomm 登记上游 issue（detokenize 单字节解码拆散 UTF-8 多字节字符，期望输出侧 token-id 或修复边界）；SDK 未来暴露 token-id 或修复 → 重开 G1 评估 (src: 用户) (src: ai)
> 已收口（2026-11-03 代码走查验证）：引擎层 cancel 通道（StreamController.onCancel→cancel(requestId)，aidl:485）与 _generateWithSlotWait await-for 消费机制正确在位；生产消费方（OnDeviceResultSummarizer.call / agent_loop 两处）全为 plain await，无 timeout/订阅取消/放弃在途路径——评审场景现网不可达。风险面=complete() 为 Future<String> 无取消入口，仅在 Step2/P2 原语对外导出后出现，改码触发器=届时导出立项（complete() 增取消句柄或改返回 Stream）。
> 已收口（2026-11-03 零星小改轮，留痕口径）：EngineService startGenerate 比对块补 [DEGRADE] 留痕——loadedModelId 空（dirName 退化存量合法形态）跳过比对时打观察面日志，禁静默；硬拒会打死既有会话故拒绝不可行。:app:compileDebugKotlin 绿。
> 双端锚定钉已就位（devlog 313：EngineStatusOrdinalTest exit 0，序数 9 unknownNeedReconcile 同轮锚定）。schema SSOT+双向生成脚本按原 todo 递延（待第三次加态触发），非阻塞。
> 驱动器+用例骨架已就位（`scripts/agent-tools/on-device-chaos-matrix.sh` 六例；devlog 314）。**用户 2026-11-01 确认 F 功能已实机验证**——devlog 315「验证: 未执行」为登记驱动器时的记录缺口，非未做。前置 F2/F4 已落地。
- [ ] [2026-10-31] (优化) [F5] 清账专项：C1~C8 物理删除（diagPanic/_batchDiagCount/过期注释/静默默认值/modelIdOf 静默降级收窄/吞异常面收窄/StreamTextSanitizer 与 StreamingDetokenizer 坏字节重建物理拆除）+ D2 序数编译期门禁（schema SSOT+双向校验脚本）+ 熔断双轨（PrimitiveFailureCounter 隔离，[DEGRADE] 标记化降级）+ PII 围栏原语入口收口；验收=uscan/dscan 零残留 (src: 用户) (src: ai)
> 已落地部分（devlog 312）：diagPanic 四处退役、`_batchDiagCount` 修正、过期注释收口、modelIdOf `DEGRADE` 留痕、熔断双轨 PrimitiveFailureCounter、PII 入口 PrimitiveInputFilter（fail-closed）。**作废项**：「StreamTextSanitizer 与 StreamingDetokenizer 物理拆除」被 G1 终裁取消（现状定性为合法方案，非治标补丁）。验收 `uscan/dscan 零残留` 未运行验证。
> 已落地（devlog 312 + `EngineService.kt:139` LOAD_STALLED 看门狗 90s 自裁、`IOnDeviceEngineListener` PARSING/ALLOCATING 回调）。残差：仅 PARSING/ALLOCATING 两阶段，**WARMING_UP 未实现**（AIDL 仅定义 0/1）。
> 已落地（devlog 312 + 316#1）：`promptJson>60000` 字符走临时文件 `promptFilePath`，:engine 受理段读后即删，Binder 只传短元数据；与 KV-Cache 推理窗口解耦立法。验收经用户 2026-11-01 确认 F 功能实机验证覆盖（含长上下文大载荷）。
> 已落地（devlog 312 + 代码四层：AIDL:57 / Bridge:215 / EngineService.kt:402 / Dart:617；序数 9 `unknownNeedReconcile` 双端锚定）。关联 评审#4 残差：loadedModelId 空值仍跳过比对。
> 已落地（devlog 310）：`on_device_capability.dart` 门面（complete + 三档 [DEGRADE] + 2s 槽位等待 + 懒加载边界）+ OnDeviceResultSummarizer 改接原语接入 mcp_runtime + debug_run_orchestrator 摘 ChannelLlmEngine generate 依赖。偏差：`ChannelLlmEngine` 探针引用按设计保留（devlog 明示），"删除废弃引用"以"摘 generate 依赖"口径达成。验收经用户 2026-11-01 确认 F 功能实机验证覆盖（含摘要器冒烟）。
- [ ] [2026-10-31] (功能) [long] [Decision] (暂缓) 扩展点：能力原语化 + 跨 App 转发——goodhub 侧只提供模型能力原语 complete(instruction,input,config)->String（不含任务模板）；摘要/翻译/打标签/文本优化等具体任务语义由其他 MCP 服务编排实现；其他 App（如 goodshare app）经 goodhub 转发调用端侧模型能力与云端能力。前置=OnDeviceCapabilityService 公共服务面（on-device-capability §2）+ G6 :gateway 独立进程 + P2 立项裁决 + 跨仓接缝同步 ai-app-split.md (src: 用户) (src: ai)
> 残差（已定谳销项 2026-11-01）：① `on_device_smoke.dart` 已随 S3 换线物理删除（devlog 98 退役清单第⑤条），全仓无 smoke 引用——外置路径不存在于任何生产代码；② 生产从未走外置 FUSE，无遗留资产需迁移。两项均空集，OD5 终态。

> 初始化盘点产生的候选缺口项；未经用户拍板，不构成工程排期。落地前须对应设计稿（draft 转正）+ solution-admission 口径。

## P1-A 开发任务切分（2026-10-28 准入拍板后切分；口径=两稿 v2.7 SSOT）

> 来源：devlog [决策][开工准入拍板] Sprint 切片 S1→S2→S3。每项开工前按 solution-admission 单项放行；锚点指向 NPU 部署稿（on-device-npu-deployment.md）/ 总纲（on-device-capability.md）。

### S1 通信脚手架（:engine 独立进程 + Mock 联调）

### S2 QNN 真机拉通（资产 + 实测）

### S3 调度边界（热/后台/并发/终止）

## 机制审计缺口（2026-10-30 只读审计轮 · 用户已拍板登记）

> 来源：全量机制审计（19 项），按 P0/P1/P2 三档登记；P3 五项属清理债，落全局 `context/todos.md` misc 节。
> 纪律：每项开工前按 solution-admission 单项放行；P0-1 与 P0-3 与「FGS 绑定即挂」复测**必须成组收口**（审计结论：分开修会让复测通过的是意外路径而非设计路径）。

### P0（核心机制断裂）

### P1（机制缺口 / 特定场景功能降级）

### P2（机制脆弱 / 文档-实现不一致）

- [x] [2026-10-30] (风险) (重:中) ~~**P2-12 Prefix Cache 复用声称与每请求 `reset()` 相矛盾**~~（2026-11-04 收口）：11-03 KV 实证 [Fact] 已定谳「每请求全量重 prefill、无跨请求前缀复用」，幻影声称三处同轮退役——AIDL truncateContext 注释改单发隔离语义、EngineService.kt 注释 [Fact] 化、NPU 稿 §2.4 补实证修正引注（SSOT=context-stepped-pruning §2.5 ADR） | 落点 `IOnDeviceEngineService.aidl` + `EngineService.kt` (src: ai, 机制审计)

## 治本工程待实施（2026-10-31 决策落定·代码未落地）

> 来源：decisions.md 两条 ADR（数据面唯一真相源 / 死因可见性·墓碑机制）。代码层核实结论 = 两条均"已拍板、零落地"，当前仍是决策要废止的双补丁架构 + `livedMs<30000` 概率推断。开工前按 solution-admission 单项放行；锚点 = decisions.md 对应 ADR 的"最终决定/收敛条件"。

### G1 数据面唯一真相源落地（token-id + GHDT 替文本双补丁）

> ⛔ **阻塞于 SDK·等 Qualcomm 上游 issue**：SDK 流式回调仅返回文本（`LlmStreamResult.Token.text`，见 `GenieSession.kt:349`），无 token-id 出口；ADR（2026-10-31，见 `:14`）已终裁「维持现状为终态」，重开条件 = SDK 暴露 token-id 或修复输出侧 UTF-8 边界。G1-1/2/3 在 SDK 提供 token-id 前**无法开工**，唯一推进通道 = 向 `geniex-android/Qualcomm` 登记上游 issue。

- [ ] [2026-10-31] (风险) (重:重) (层:跨端) **G1-1 废弃 Kotlin `StreamTextSanitizer`**：`GenieSession.query()` 仍活跃使用（`val sanitizer = StreamTextSanitizer()` L336 + `feed/fluash` L370/378/385），是决策要彻底废弃的 SDK 文本回调修复层；与 Dart 侧修复层并存 = 决策点名的"双端补丁" | 红线：删除前必须先有 token-id 生产链路接管（G1-3），否则删后乱码回归 | **阻塞于 SDK·等 Qualcomm 上游 issue** | 落点 `GenieSession.kt` (src: ai, 代码核实 2026-10-31)
- [ ] [2026-10-31] (风险) (重:重) (层:跨端) **G1-2 Dart `StreamingDetokenizer` 退出 identity 直通态**：生产态用 `_identityTable`（i→[i]，L832-835）做 UTF-8 字节重组，**非** GHDT token-id 解码；真 `TokenByteTable` 仅 `on_device_detokenizer_test.dart` 测试态，未入生产流 | 红线：identity 表路径随 G1-3 真 GHDT 接管后整体退役，含 `on_device_detokenizer_test.dart` 中 identity 用例 | **阻塞于 SDK·等 Qualcomm 上游 issue** | 落点 `on_device_engine_aidl.dart` + `on_device_detokenizer.dart` (src: ai, 代码核实 2026-10-31)
- [ ] [2026-10-31] (功能) (重:重) (层:跨端) **G1-3 数据面载荷切 token-id + `libgdw` 原子组装**：现状 `engine_data_worker.cpp` 仅 TLV 帧转发 UTF-8 文本字节（kTypeToken 原样 postFrame），无 token-id 解码、无 GHDT 表加载、无多字节滞留 RingBuffer | 实施：① Kotlin `SocketTokenWriter` 写 token-id 微批（非 text），帧协议增 token-id 承载（复用 TOKEN 帧改 int 数组或新类型）② `libgdw` 加载 `tokenizer.id2byte.bin`，Worker 内做 `id→bytes→UTF-8` 滑动窗口原子组装（未完成多字节滞留 RingBuffer 绝不外抛），只向 Dart 投合法 String ③ Dart 只收 String | 验收：生产路径全量 token-id（无文本字节越数据面）；`StreamingDetokenizer`/identity 表退役；`libgdw` 单测覆盖"跨帧多字节滞留 + 完整字符才外抛"；真机「中→ä¸­」类乱码零复现 | **阻塞于 SDK·等 Qualcomm 上游 issue** | (src: ai, decisions.md ADR + 代码核实 2026-10-31)

### G2 死因可见性·墓碑机制（排除法裁定 LMK_SIGKILL vs 硬崩溃）

> 注：G2 三项代码已落地（实现落点实为 `EngineService.kt` + `engine_tombstone.cpp` + `on_device_death_cause.dart`，与原清单落点描述略有偏差）。残存验收余项（非阻塞）：① `.stack` 读墓碑后未清理，PID 复用时可能误判 `hardCrash`；② 真机 `am kill`/LMK 场景 100% 裁定收敛未回归。

## 多栈框架构型子步骤（2026-11-01 四裁决落盘·代码未落地）

> 来源：decisions.md 同日 ADR「LiteRT-LM 内置底座 + GenieX 增配选装」四裁决（D-1~D-4）+ 联发科通道升格。开工前按 solution-admission 单项放行。

> 已落地（devlog 同日）：AIDL 注释/`GenerationParams`（Bundle stringArrayList + fromArgs）/`EngineService` 传参贯通；新增 `engine/StopSequenceMatcher`（跨帧滑动窗口匹配，默认 `<|im_end|>` 保持现行为，匹配在 sanitizer 输出后 = 用户可见边界；Kotlin 单测 6 例）；`GenieSession.query` 加 `stopSequences` 参、硬编码 im_end 截断退役；Dart `GenerationConfig` 字段 `stopSequences: List<String>`（预编码 id 字段双端同轮退役）；goodshare `ai-dev-spec.md` §4 新增「端侧推理接缝」条款。验证：`:app:compileDebugKotlin` + Kotlin 单测 11 绿；flutter analyze 0 issue + test/llm 200 全绿。关联 P1-8 的停用词失效面随本项收口（采样参数面 P1-8 仍开）。
- [ ] [2026-11-01] (功能) (重:中) ~~QAIRT 运行库单源化~~ **[SSOT 修正 2026-11-02 → 三下载点独立]**：GenieX 增配（GenieXRuntime 4 件套）与 LiteRT-LM QNN dispatch 共享一份 `libQnnHtp*` runtime 依赖，统一 `nativeLibraryDir`/`setQairtRuntimePath` 指向，防双份捆绑符号冲突 (src: 用户拍板 2026-11-01)
> **[SSOT 修正 2026-11-02 用户拍板：推翻单源化]** 基座同源（两栈都吃 QNN/HTP v 系列）但**实例不共用**——两栈各自的 split/AAR 与模型版本自洽配对，混用 QNN 版本会产生跨栈版本耦合（一栈升级打碎另一栈 context 二进制），故障归因无法夹逼。运行库分发终态 = **三个下载点独立、功能不降级**：① GenieX 增配 AAR（`hexagonArch()` 键，现状不动）② LiteRT-LM NPU split（`split_qualcomm_npu_runtime_v{arch}`，**解绑 v79 硬编码**——`NPU_VARIANT` 常量退役、assets 内置降级为首发机快捷路径、键复用 `GenieXRuntime.hexagonArch()` 单源勿再写 SoC 映射）③ 联发科 NeuroPilot（留位）。**另出 v79 合集包**（首发机 Ace 6 一键路径：GenieX v79 + LiteRT-LM NPU v79 单工件）。
- [ ] [2026-11-02] (功能) (重:中) **运行库增配通道泛化 + v79 合集包**：把 `GenieXInstaller` 下载骨架（双镜像 + sha256 pin + arch 抽取 + 旧版清理 + `recoverIfDriverChanged` 驱动指纹失效脏删重探）泛化为按「库族 × hexagonArch()」键控的通用增配通道，承载 GenieX AAR 与 LiteRT-LM NPU split 两个注册工件；v79 合集包 = 通道上的预组合工件（首发机零拼装）；`LiteRtLmRunner.NPU_VARIANT` 解绑（arch 键注入，非 v79 静默回落 GPU 的无感知降级改为显式提示）。与 DispatchProfile 准入探针轮合并施工（共享注册表结构与 arch 键） (src: 用户拍板 2026-11-02)
> 已收口（2026-11-03 真机实测，Ace 6，数据归档 devlog 同日）：bench 双段改造（注册表装载 + backendHint GPU 段 + ctx 感知 padding + messages JSON 契约修复）后三档对照齐——① NPU 档（sm8750 专用 bundle）TTFT 102~142ms / TPOT 2.6~3.9ms ≈ 259~378 tok/s（6.6~9.7× 基线）② GPU 档（通用 bundle 强制 gpu）TTFT 284~572ms / TPOT 9.1~12.2ms ≈ 82~110 tok/s（2.1~2.8×）③ generic 档（通用 bundle auto，TF_LITE_AUX 缺失非 NPU 加速）TTFT 3337~7536ms ≈ 53~64 tok/s（陷阱档，TTFT 恶化 6~13 倍）。内存 :engine PSS 854MB（GPU bundle 驻留）/ 热 GPU ~52°C 良性。附带真发现：sm8750 NPU 专用 bundle 无 GPU 张量（backendHint gpu 必失败）——通用 litertlm bundle 应路由 GPU 档，观测后端画像天然覆盖无需新机制；陷阱档探针排除验证为可选后续。
> 已落地（devlog 同日）：编译期开关 `kOnDeviceLlamaCppEnabled`（`ON_DEVICE_LLAMACPP` ~~默认 false~~ **[SSOT 修正 2026-11-05 用户拍板 → 默认 true]**：llama_cpp 通路经 Qwen 真机轮实证健康（装载 3s/生成 9 tok/s 慢档画像在案），GGUF 导入即导入即用——推翻本行与 devlog 2026-11-01「首发节奏关闸」口径，关闸点结构保留（导入 UI/_select/enable() 三闸，`ON_DEVICE_LLAMACPP=false` 可再关））+ 三闸（导入 UI 拒收 GGUF 直选 / `_select` 拒选 llama_cpp 模型 / `enable()` 装载闸兜底非 retryable 终态报错）；analyze 0 issue + test/llm 200 全绿。
> 已落地（devlog 同日）：`OnDeviceAssetFamily`（geniex/litertlm/unknown + `familyOf` 单源映射）+ `OnDeviceRuntime.litertlm` + meta `family` 字段 + 结构校验 `.litertlm` 识别 + `kOnDeviceLiteRtLmEnabled` 装载闸（Runner 未集成 fail-fast）+ UI 徽标；test/llm 202 全绿。**SoC 分发键未实现**——导入制下无在线分发面，键=`ro.soc.model` 待分发面立项时接线（官方 NPU 资产按 SoC 精确分发，跨 SoC 不互通同 GGUF ctx-bin）。后续主体 = LiteRT-LM Runner 集成（独立工程，落地时翻 `kOnDeviceLiteRtLmEnabled`）。
> 联发科（2026-11-01 用户修订）：**接口留位，现阶段不支持**——Runner 注册表预留 NeuroPilot 扩展位，不实现、不排期真机实证；重评触发 = `.litertlm` NPU 资产目录扩展（出 3B 级/多模型）或天玑旗舰真机到位，届时回 decisions.md ADR 立项（路线 = LiteRT-LM + NeuroPilot Delegate，免 GenAI Toolkit 企业 NDA）。

> **已收口（2026-11-03 用户确认真机验证完成）**：①~⑥ 全链落地——Runner 集成 + 装载链 + 停用词 + DispatchProfile/准入探针（NPU 败再探 GPU，backendHint）+ 运行库增配通道泛化（三下载点独立、清单化、多机型口径）+ 导入面/资源中心展示 + 历史策略模式（⓪真裸为端侧默认）。真机合验（Ace 6，devlog 2026-11-02~03）：装载→生成→停用词→降级链绿；12222 复读归因闭环（system 中文长指令触发，litertlm 0.18.1 + 显式 SamplerConfig + RepetitionGuard 阈值 4 兜底，ttft=71ms）；全量 flutter test 1538 绿。残差移交：① D-4 GPU/NPU 同口径基准数据归档仍待系统跑一轮（条目单列）② 端侧 system 精简策略（决策点）③ stopMatcher pending 尾巴 flush 观测 todo。

## 待裁决（需产品/架构拍板优先级）

- [ ] A1 端侧模型管理链复活拍板（archive/local_model 已归档零接线，需翻转裁决）——**现在不做（2026-11-03 盘点）**：现「导入制 + 资源中心」已覆盖首发全部场景，下载式分发与导入制双轨徒增维护面；触发 = 用户规模上来需要免 SAF 的在线 OTA 分发
- [ ] A2 G6 网关独立进程化（防端侧模型 OOM 拖垮 PC 远程网关；thirdconnect §9.5/§10.5）——**现在不做（2026-11-03 盘点）**：OOM 连坐风险已多轮降级（权重走 mmap/ION 不入 PSS、TTL+内存护栏+FGS 提权防线在位）；触发 = 真机实测出现网关连带死亡
- [ ] A3 iOS 端侧引擎适配（MLX/Core ML 适配位；双端策略 §133-145，前置 macOS/Apple 账号）——**现在不做（2026-11-03 盘点）**：硬前置缺位（无 macOS/Apple 开发者账号）且 Android 首发未收官；纯留位，不排期
- [ ] B1 端侧摘要器 `$ref` 注水真机实证（m3 头注 / host-gateway §3.5）——**现在不单独立项（2026-11-03 盘点）**：机制码面在位、纯验证性质——随下次真机轮顺带实证，零开发成本
- [ ] C1 端侧 PII 模型层（非结构化 PII；架构 §219 T7+）——**现在不做（2026-11-03 盘点）**：小模型遮蔽质量不可靠（误拦高频=宁拦不放语义放大伤害），且无真实用户案例驱动；触发 = 真实受损案例或产品重定位
- [ ] C2 多模态 PII 检测模型（FC2，触发=M3+ 多模态接入）——**现在不做（2026-11-03 盘点）**：触发条件本身未到（goodhub 未接多模态）；等 M3+ 多模态接入再立项

## 已锁定（机制已落地，仅跟踪）

## 挂起（外部依赖，机制已就绪）

- [ ] (外部依赖: 高通 Maven 发版) 增配包换版实战 0.10.0→N：checklist 四步见 `docs/design/on-device-npu-runtime-split.md` §8 P4 行（VERSION/PINS 重生成 → 插件 API 面复查 → REINSTALL 换版演练 → bench 对照）
- [ ] (外部依赖: 真机到位) 多机型增配覆盖 v73/v75/v81：installSet 三档映射已走查确认，缺各档真机实证（v73/v75 仅核心档 llama.cpp GPU、v81 QAIRT 集）

## 存量债

- [x] (功能·已收口) **GGUF hexagon NPU 通路清单补件**（2026-11-05 实验→同日收口）：补件完成（manifest v79 段 + `libggml-htp-v79.so`，zip 因 CDN 边缘缓存旧版换新 key `geniex-v79-b.zip`）、fastrpc cdsp 装载成功（compute_unit=HTP0）——geniex-android 0.10.0 hexagon 后端真机实测**劣于 GPU**：Qwen3.5-2B Q4_0 short 例 5.5 tok/s（GPU 9）、long 例 TTFT 20~25s → stall/看门狗死亡；**终态 = NPU 首选 + 按模型负记忆**（`engine/NpuFitStore.kt`：模型自身原因留痕跳 NPU 直 GPU、系统原因不留痕、SdkVersion 键升版自动重评，真机双轮验证过，见 devlog 同日）——升版后无需改码自动重评 NPU 通路 (src: ai, Qwen 轮延伸实验)

- [ ] (触发: 真机压测) 崩溃后快速重载另一大模型的 CMA 碎片残余（DMA-BUF 内核回收延迟：探针通过但实载失败）：现有拦截链 = cmaProbe 前置试分配 → CMA_UNAVAILABLE 干净切云（不重试、不计熔断）+ 进程死 500ms 冷却窗口；App 层无内核回收干预钩子，「装载前冷却增强」待真机压测数据到手再评估（2026-11-02 盲区 1 评定）
- [ ] (演进参考: IRIDIS 对比) Dart 侧熔断器演进 armed/disarm + exit-reason 状态机：装载前写 armed 标记，重启时 `getHistoricalProcessExitReasons`（REASON_CRASH_NATIVE/CRASH/SIGNALED/ANR）判定真崩溃才记坏，精确替代 onServiceDisconnected 启发式区分「真崩溃 vs LMK 处决」（对照 IRIDIS BackendCrashMemory，2026-11-02）
- [x] (观测性) 熔断 trip / 资产卸载的 reason 随下次动作一起打日志（装载 log 带上次 trip 原因）——对照 IRIDIS「卸载 reason 随下次 load 打 logcat」实践（2026-11-02）
> 已收口（2026-11-04 零星修改轮）：breaker 增 reason 参数 + `_lastEvent`/`lastEventReason` 留痕（L1/L2 trip 覆盖写入）；装载入口 `_runBackgroundLoad` 起手 debugPrint 上次事件；生成闸门拒绝消息携带现场。测试钉 4 例（on_device_circuit_breaker_test 16 全绿）
- [ ] (已知限制: 用户拍板 2026-11-02 接受) Gemma3-1B-it-q4-ekv1280（LiteRT-LM 栈，1280 ctx）长指令场景（~2000 字符 prompt = 长 system 指令 + 提问）复读环严重：真机受控实验首问 7 字符即环、第二轮 523 字符环（均被 RepetitionGuard 截停，无误伤），无价值产出；定谳 = 模型能力边界（Q4-1B + 长指令），非架构 bug/非上下文污染/非云端路径；复评触发 = 用户换模型族（如 Qwen3.5-2B GenieX 栈）或产品重定位端侧质量要求；采样参数未调（temp 0.7/topP 0.9 为 Dart 默认）
> 复评（2026-11-04 Qwen 真机轮，触发条件「换模型族」已发生）：Qwen3.5-2B（llama_cpp 栈）bench 三例含 3000 字长 padding（≈2K tok，与原触发器同量级）输出全部干净短产出、RepetitionGuard 零触发——**初判 Qwen 族未复现复读环**。边界：原触发器形态（长 system 指令 + 提问多轮）bench 显式模式无 system 消息未单独复现，完整复评归采样 A/B 真机轮（规格表 recommendedSampling 策展同批）
- [ ] (观测性) **session-mirror drift @generate**（2026-11-04 Qwen 轮新发现）：显式 loadModel 诊断路径（ON_DEVICE_BENCH_MODEL_DIR）装载后，主进程 loadState 镜像停在 unloaded 而 :engine=busy——每次 generate 刷 `[DEGRADE] session-mirror drift`，票据面兜底未断链（生成正常），观测债非阻塞 | 落点 `on_device_engine_aidl.dart` 显式装载链的 loadState 写回 (src: ai, Qwen 真机轮)
> 已收口（2026-11-03）：判定=有意设计非缺陷——abort 滞留尾巴=跨帧防切断缓冲+复读环/抢占残留，Completed/onDone 才终态冲刷，abort 放出反而交付取消后残余；~78 字节差主体是 UTF-8 多字节展开。处置=GenieSession Token 分支 abort 早退处补语义注释（LiteRtLmRunner:386 已有），:app:compileDebugKotlin 绿。
> 已收口（2026-11-05 真机回归轮）：三形完成——a) TTL 竞态引擎面通过（TTL 驱逐后首发请求 EOS frames=25 bytes=73 正常产出，frames=0 不复现）b) trim 驱逐打断在途→EOF→EngineDied 白话报错 + EXCLUDED(crash) 记账缺席（归因过滤生效）c) 就绪态空产出无法真机驱动，由 Fix-2 代码守卫保证；顺带实证空闲 TTL 常规回收正常 + GGUF 放开口径真机收包 + llama_cpp NPU 生成健康。UI 面产出被新登记的「自杀重启 vs 在途流收口」竞态挡住（见下方缺陷项）。
> 已收口（2026-11-05 修复轮）：显式自杀契约落地（:engine clean exit 前上行 `cold-reload-restart` + Dart 60s 重启窗口豁免 `_failAllActive`）+ 真机闭环实证（TTL 驱逐后首发请求 `window armed → keep active generations → query done status=0` 截图确认答案完整渲染零错误卡）。门禁全绿（analyze 0 issue + 编译成功 + 400 测试）。
> 已收口（2026-11-05 三件一批轮）：① 文案误归因修复——票据双端增 `loadError` 字段承载真因（getLoadError 立法意图），terminal 失败按真因归因（运行库未装 → 运行库文案，禁再报「请导入模型」）② hardCrash 观测核实——墓碑三分类正确（真机三轮实证各归其位），无代码缺陷，hardCrash 本体归 geniex 层下次抓 tombstone ③ SSOT 回填——§2.1/§2.8/§4 + frontmatter 全部落。
> 已归因（2026-11-05 真机轮）：两次独立复现（12:21 trim 驱逐在途 / 16:29 长输入 prefill）SIGSEGV 落 **`libggml-cpu.so`（geniex-runtime/0.10.0）`ggml_cpu_extra_compute_forward`** 同 BuildId——geniex 层缺陷非 goodhub 代码。重评触发器 = geniex-android 升版 >0.10.0（与 hexagon NPU 重评触发器合并）；期间**长输入（>800 token 级）路径不可用**（B 组采样 A/B 被此阻塞），端侧对话按短输入形态使用。抓 tombstone 手续已由墓碑面自动完成（death cause=hardCrash stack=true）。
- [ ] [2026-11-05] (观测) (轻) **trim 驱逐在途时 `death cause=hardCrash stack=true`**：crash buffer 无 FATAL，疑 geniex 0.10.0 在途 destroy 路径；下次真机轮遇驱逐+崩溃组合时抓 tombstone 确认 | 落点 观测 (src: ai, 2026-11-05 真机回归轮)
- [x] [2026-11-06] (功能) (重:中) (层::engine) **qairt 主路 0.3.5 性能补测（降版 0.3.5 放行前置门）**：qwen3_1_7b qairt bundle 0.3.5 vs 0.10.0 对照跑 QAIRT+NPU——**结果（2026-11-06 收口）：前置门硬失败**。0.10.0 基准 decode 41.34 tok/s/prefill 2479 tok/s 健康；0.3.5 `create() error -100201` / QNN err 5000（旧 QNN 运行库加载不了新版 QAIRT 编译的 .bin）——整包降版打穿 qairt 主路，**整包降版方案否决** (src: ai, 准入评估 ADR [2026-11-06])
- [ ] [2026-11-06] (观测) (轻) **纯 decode 慢未被留痕机制覆盖**：ttft_stall 留痕门=15s（NpuFitStore.TTFT_STALL_MS）只盖 prefill stall；TTFT 正常但 tok/s 低的模型不会触发 NPU→GPU 自动降级（会话内无档位切换，仅下次装载级）；ngl=-1 激活 NPU 档后此盲区首次有实际意义——下次真机轮遇「NPU 档 TTFT 正常但 decode <10 tok/s 级」时评估补 decode 慢留痕（如首 64 tok 滑动速率门） (src: ai, 2026-11-06 用户提问核降级链)
- [ ] [2026-11-06] (功能) (轻) (层::engine) **ngl=-1 修复 commit + push（已验证待提交）**：GenieSession.kt 三处改动（ggufConfigBase 基线/buildGguf 窗口配置/NPU 阶梯注释更正），验证=构建通过 + flutter analyze 0 issue + 真机生产路径 31.5~32.7 tok/s（5.6×）；**等用户指令提交** (src: ai, 2026-11-06 ngl 修复轮)
- [ ] [2026-11-06] (功能) (轻) (层:跨仓) **上游 issue 提交（用户侧动作，本机无 GitHub 凭据）**：稿=issue-draft-geniex-0.10.0-llamacpp-regression.md（Title/Body 分段提交就绪）→ https://github.com/qualcomm/GenieX/issues/new ；**提交后把 issue 编号回填本条 + ADR [2026-11-06] + 记忆** (src: ai, 2026-11-06 归因反转轮)
- [ ] [2026-11-06] (功能) (重:重) (层::engine) **混合栈降版评估（取代整包降版，前置门否决后转向，待用户拍板开工）**：保持 0.10.0 AAR 不动（qairt 栈 + QNN 运行库维持最新、主路健康），仅把 llama_cpp 后端的 ggml 运行库（libggml-hexagon/libggml-htp-v79 等）替换为 0.3.5 版本以恢复 llama_cpp 性能；**评估要点**：①插件本体 libgeniex_plugin_llama_cpp.so 是否必须随 ggml 库同版（0.10.0=289KB/0.3.5=256KB，接口是否兼容）②增配运行库机制（GenieXRuntime 下载通道 + filesDir/geniex-runtime/）能否承载「0.10.0 插件 + 0.3.5 ggml 库」的混搭并保证 W^X/权限③qairt 栈与 llama_cpp 栈混用同进程是否有 QNN/ggml 符号冲突④0.3.5 ggml 库单独可取性（从 0.3.5 AAR 摘 lib，无 QNN 依赖）；**若混合栈不可行 → 唯一剩余路线 = 等上游修复版（issue 已就绪），llama_cpp 档维持现状 5~6 tok/s** | 落点 `GenieXRuntime.kt` + `build.gradle.kts` (src: ai, 准入评估 ADR [2026-11-06])
