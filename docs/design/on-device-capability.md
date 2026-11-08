---
status: active
updated: 2026-11-06
---

# on-device-capability · 端侧能力公共服务设计

> 绑定 epic = `on-device`。本文件是「端侧推理能力」升格为**公共服务**的设计 SSOT（芯片平台分发 / 双后端 / 分期）。现状盘点见 `context/epics/on-device/memory.md`；本次为草案（draft），落地前须经 solution-admission 口径与产品侧分期拍板。
>
> **v3 路线修订（2026-10-28 用户拍板）：推理内核采用高通 GenieX Android SDK**——`:engine` 进程内部的 Tokenizer/KV-Cache/采样/Decode 循环/停用词下沉/流式回调由 Genie 内置管线承担，替换「手写 QNN C API 推理内核」计划；**外围防护架构全部不变**（`:engine` 独立进程隔离、AIDL 控制面 + Ashmem 数据面、两级熔断、三态状态机、磁盘门禁、切云降级）。资产格式改 GGUF（不再绑定 HTP 专属 context 二进制）。获取 = Qualcomm AI Hub `qai-hub download-model-assets`（免企业授权，免费 Qualcomm ID）。受影响章节细化修订待 SDK 落位实证后同轮回写。
>
> **v3.3 构型修订（2026-11-01 用户拍板）：多栈推理框架 = LiteRT-LM 内置底座 + GenieX 增配选装**——四裁决见 `context/epics/on-device/decisions.md` 同日 ADR：**D-1 双段路由**（资产分发期按资产族定栈：GGUF→GenieX 系、.litertlm→LiteRT-LM 系；运行期仅同栈内降级，**禁跨栈横跳**）；**D-2 D1 设备分档维持**（中低端纯云端不因底座解禁）；**D-3 停用词契约重构**（AIDL 改传 `stopSequences: List<String>`，编码下沉各 Runner Native 自治；施工须同轮修 goodshare `ai-dev-spec` §4）；**D-4 GPU 档双轨并存**（2026-11-01 用户修订：**llama.cpp 永久保留不删除**，不设退役条件、无 PATCH——llama.cpp 承载 GGUF 通用通路与已实证基线，LiteRT-LM 承载 .litertlm 标准化通路，LiteRT-LM GPU 真机基准仅作能力对照归档）。**联发科接口留位**（2026-11-01 用户修订：现阶段不支持）——路线认定 = LiteRT-LM + NeuroPilot Delegate 打 APU（联发科×Google 官方合作，免 GenAI Toolkit 企业 NDA），但 Runner 注册表仅预留 NeuroPilot 扩展位，不实现、不排期实证；重评触发 = `.litertlm` NPU 资产目录扩展或天玑真机到位。**首发节奏**（2026-11-01 用户修订：**llama.cpp 先不放出，从 LiteRT-LM 起步**）——D-4 的「永久保留」指代码保留不删，不指用户面放开：llama.cpp 通路（GGUF 导入/GPU 兜底档）首发关闸不暴露（GGUF 导入入口、分发推荐、设置面均不开放，feature flag/编译保留），首发资产路线 = **仅 `.litertlm` 族（LiteRT-LM 栈）**，双段路由 GGUF 分支为「在码未启用」；重评触发 = LiteRT-LM 首发稳定 + GGUF 资产链就绪，按新 ADR 立项放开。QAIRT 运行库**单源化**（一份 runtime 依赖两栈共用，防 `libQnnHtp*` 符号冲突）。

> **v3.2 路线修订（2026-10-31 用户拍板）：NPU 兜底**——`:engine` 的 `GenieSession.doLoad` 以 `QAIRT+NPU` 为主路，**仅高端 NPU 设备在 QAIRT build 失败（NPU 驱动/HTP 不可用）时回落 `llama_cpp+GPU` 运行时**完成本轮（同份 GGUF 资产 + tokenizer，两插件 AAR 均捆绑；2026-10-31 CPU 档全量退役改 GPU 档，2026-11-01 GPU 契约真机实证）；**热/OOM 不触发兜底**，仍经既有决策收口云端（遵「禁 CPU 分流」/「OOM CPU 反向」）；D1a 设备分档不变（中低端仍直收纯云端），仅推翻 D1「无 CPU 兜底」条款；Dart 路由层 / AIDL 不变（运行时无关）。详见 `context/epics/on-device/decisions.md` ADR。

## 0. 需求与范围

- **公共服务化**：端侧推理引擎从「聊天页私有内部 widget」升格为 App 级能力内核，经**纯 Dart 抽象接口**暴露，由 coordinator 装配注入，不限于 UI 私有调用。
- **芯片平台分发**（安卓，v2 修正；v3.3 修订）：Qualcomm → **QNN / QAIRT（HTP）**；MediaTek → **接口留位，现阶段不支持**（路线认定 = LiteRT-LM + NeuroPilot Delegate 打 APU，联发科×Google 官方合作、免 GenAI Toolkit 企业 NDA；Runner 注册表预留 NeuroPilot 扩展位，不实现不排期，重评触发 = `.litertlm` NPU 资产目录扩展或天玑真机到位）。NNAPI 已废弃、Google AICore 仅 Pixel/限定合作机型系统级开放、不对国内 OEM 第三方 App 提供加载任意大模型能力。
- **设备分层（产品决策 D1）**：**中低端设备明确不支持端侧能力**，直接收口为纯云端——不在该类设备启用端侧推理/摘要/提取；即便 LiteRT-CPU 可跑，亦不作为受支持能力对外暴露。仅高端旗舰（**QNN / NeuroPilot 可用**，即高通=QNN、联发科=NeuroPilot）启用端侧加速。
- **分期（P1 分阶段交付）**：
  - **P1-A（首发验证基线 · 高通 QNN）**：骁龙 8 Gen3/8 Elite 旗舰 + QNN（工具链完全开放，可打包进 APK/AAR）+ **独立进程 `:engine`** + 云端降级，率先拉通 Dart 接口与引擎全链路闭环。
  - **P1-B（跟进 · 联发科 NeuroPilot）**：以公司主体推进联发科企业 NDA / GenAI Toolkit 开发资质、ROM 兼容性验证与 DLA 编译环境，作为专项并行推进；**不在 P1-A 阻塞整体端侧上线节奏**。
  - **P2（待定）**：候选方向见 §4，未经拍板。
- **独立进程硬性前置（P1 阻塞项）**：重型 NPU 引擎（3B~4B 常驻 1.8~2.4GB + FastRPC 驱动交互）**必须运行于 `android:process=":engine"` 独立私有进程**，经 Binder / 共享内存（MemoryFile/Ashmem）与主进程通信；NPU 驱动 Panic 或 OOM 仅使主进程收到 `EngineDiedException` 并无缝收口云端，**绝不导致 Flutter 主进程闪退**。此条升格为 P1 强制验收标准（原 G6 由"建议"转为"刚性前置"，见 R3/§4）。
- **引擎深度设计**：NPU 最大化部署的系统方案（计算单元协同 / 量化适配 / 内存带宽优化 / 热调度 / 端到端评估与取舍）见 `docs/design/on-device-npu-deployment.md`。

## 1. 平台前提核实（评估要点 · 决定路由模型）

| 方案 | 技术实质 | 适用硬件 | 模型产物 |
|---|---|---|---|
| **高通方案** | Qualcomm AI Engine Direct（QNN）/ QAIRT SDK；模型经 QAIRT 转换+量化跑 Hexagon HTP | 骁龙旗舰（8 Gen3 等）| QNN 优化包（.so/.bin）|
| **联发科方案** | MediaTek NeuroPilot（Neuron Runtime / Neuron LLM）；官方 NPU 推理路径 | 天玑旗舰（9300/9400 等）| Neuron 编译产物（SoC 专属）|
| **轻量小模型执行器 LiteRT** | TensorFlow Lite Runtime；仅承载百兆级小模型（意图分类、PII 提取等）跨平台执行，CPU/GPU 运行 | 全平台 | 轻量 `.tflite`（非 LLM 级模型） |

**关键修正（影响路由设计，v2 修订）**：

1. **联发科官方大模型路径是 NeuroPilot（Neuron Runtime），非 LiteRT/AICore**——NNAPI 在高版本 Android 已废弃、停止维护相关 delegate；AICore 仅 Pixel 与极少数合作机型系统级开放，国内 OEM 天玑旗舰不向第三方 App 提供加载任意大模型的能力。
2. **QNN 与 NeuroPilot 均为按芯片厂商确定性可走的官方 SDK**：路由基本可按 `SOC_MANUFACTURER` 二分（高通→QNN，联发科→NeuroPilot），但仍须 `CapabilityProbe` 探测 SDK 可加载性与 RAM 阈值作为可用性门禁（见 D1 分档）。
3. **LiteRT 仅作百兆级轻量小模型（意图分类、PII 脱敏等）跨平台执行器**，不承接 LLM 级模型的 CPU 兜底；两端 NPU SDK 均不可用时，端侧 LLM **直接收口纯云端**（非 CPU 跑大模型）；Google 系统模型（Gemini Nano/AICore）因不对第三方开放，不纳入本方案资产链。

## 2. 架构落点（对齐 coding-standards §1.3 / architecture §78）

- **纯 Dart 抽象接口（完整粒度，v2.5 补全）**：

  ```dart
  enum EngineStatus {
    ready,              // 就绪可用
    busy,               // 执行中（协作式打断：中断仅在生成循环检查点生效，见 §4 单任务互斥）
    assetMissing,       // 资产缺失（M4 起回归终态语义：真·未导入/校验不过）
    insufficientMemory, // 当前可用 RAM 低于门禁
    circuitBroken,      // 处于熔断保护期（引擎故障，需熔断器/人工介入）
    unsupportedDevice,  // 硬件 / 芯片架构不匹配（D1 中低端）
    thermalCutoff,      // 6 热降级切云期（**2026-10-31 退役**：序数保留防漂移，永不产出——温控全链摘除）
    loading,            // 7 M4 追加（受理态，P2-14 销账）：模型装载中
  }

  abstract interface class OnDeviceEngine {
    // M4 Contract：状态唯一来源 = :engine 票据面（checkSession）——
    // checkStatus 轮询面已退役。票据不可得返回 null = 未知态（禁猜测）。
    Future<EngineStatus?> authoritativeStatus();
    Future<bool> isAvailable() async =>                 // 语法糖（未知按不可用）
        (await authoritativeStatus()) == EngineStatus.ready;
    Future<void> warmup();
    Stream<EngineChunk> generate({
      required String requestId,
      required String prompt,
      ResponseFormat? responseFormat,
      GenerationConfig config = const GenerationConfig(),
    });
    Future<void> cancel(String requestId);              // 经 atomic stop_requested 下沉（§6.3）
    Future<void> truncateContext({int keepTokens = 0}); // 回滚/复用 KV-Cache（keepTokens=0 等价旧 resetContext）
    Future<void> release();                             // 主动回收 → Cold-Evicted
  }
  class EngineChunk { final String deltaText; final String finishReason; final TokenUsage tokenUsage; }
  class GenerationConfig {
    final int maxTokens;          // 生成长度上限截断
    final double temperature; final double topP;
    final List<String> stopSequences;  // 停用词字符串序列（D-3 契约，2026-11-01）：
    // 编码判定下沉各 Runner Native 自治（自绑 tokenizer 实时 match）——预编码 id
    // 跨后端词表不互通（GGUF BPE vs .litertlm SentencePiece），旧 stopTokenIds
    // 契约已退役。GenieX Runner 落点 = :engine 文本流跨帧匹配（SDK 拒收 stop
    // sequences，ErrorCode -100016；StopSequenceMatcher，默认 <|im_end|>）。
    const GenerationConfig({
      this.maxTokens = 512,
      this.temperature = 0.7,
      this.topP = 0.9,
      this.stopSequences = const [],
    });
  }
  ```

  - **结构化状态与调度纪律（v2.6；M4 修订）**：状态区分 `assetMissing` / `insufficientMemory` / `circuitBroken` / `unsupportedDevice` / `thermalCutoff` / `busy` / `ready` / `loading`——但**仅前四类可作短时缓存或持久化锁定**；**`busy` 与 `ready` 严禁任何 TTL 缓存，必须随查随废**。**M4 受理/终态两义分离（P2-14 销账）**：`loading`（序数 7，2026-10-31 追加）= 装载受理态；`assetMissing` 回归**终态**语义（真·未导入/校验不过），「装载中」不再呈现为「资产缺失」。**`thermalCutoff`（序数 6，2026-10-30 追加；2026-10-31 退役）**：热降级切云态已随温控全链摘除退役——序数保留防跨端漂移，**`:engine` 永不产出该态**（OEM 热档位以 SoC 限频档为准非壳温，误判史多次实证；极端发热交 OEM 自身限频/降频保护）。历史描述存档：~~环境性可自愈（温度回落即恢复），禁缓存、禁计入熔断，§5.2 Thermal→Cloud 切云——严禁与 `circuitBroken` 熔断序数复用（真机实证「端侧加载失败：模型装载失败（circuitBroken）」）。~~调度铁律：**业务分流决策绝不依赖状态查询的 `busy`**——`busy` 仅供 UI 状态展示、健康检查与打点监控。多调用方严禁"先 check 后调用"防御式写法（`if (status!=busy){generate();}` 存在 TOCTOU：A 过检未占槽时 B 插队，A 仍撞 `busy`）。正确路径：`HybridCloudEngine` 直接无脑调 `generate()`，由 `:engine` 内部 Mutex 原子抢占——抢占成功返流；槽被占且不可抢占（后台遇前台执行）立即抛 `ServiceBusyException`，调用方捕获即切云（见 §6.6）。`isAvailable()` 仅作 `== ready` 语法糖。
  - **流生命周期自动绑定（v2.5）**：实现层须用 `StreamController(onCancel: () => cancel(requestId))`——无论页面退出还是 `StreamSubscription.cancel()`，均自动透传至 Native 取消，杜绝孤儿任务空跑发烫。
  - **在途 Token 清理（v2.5）**：`cancel` 触发后 Native 直接清空 RingBuffer 未消费在途 Token，下发单条 `finishReason: "cancelled"` 的 `EngineChunk` 后闭合流，避免序号不一致。
  - **KV-Cache 复用 = Prefix Cache 唯一主路线（v2.6 确认）**：多轮对话/固定上下文复用经 `truncateContext(keepTokens: n)` 回滚末轮 KV；**高频固定上下文（System Prompt / Agent 指令 / Tool 模板）截断对齐到固定分块（256/512 tokens），首次暖机跑完前缀将其 KV 保留在 NPU ION Buffer `[0, Prefix_Length)` 槽位，后续会话经 DMA 维持前缀 KV 指针不动、推理指针从 `Prefix_Length` 起写，免去重复 Prefill 算力**（详见 NPU 稿 §2.4）。**增量 Prefill 标记"未来探索项（需 SDK 动态图/Reshape 能力成熟）"，不作为本期验收标准**——NPU 静态图依赖编译期确定张量形状与 HTP 块对齐，动态长短增量 Prefill 易打乱 VTCM/SRAM Stationary 数据流、致编译失败或静默回退。
  - 平台实现经装配注入（沿用 `LlmBridge.kt` 范式）；`EngineChunk` 携带流式 `deltaText` / `finishReason` / `tokenUsage`。
- **单任务互斥（v2.4 拍板，详见 NPU 稿 §6.6）**：端侧 NPU 引擎物理单重入，`:engine` **单执行槽 + 策略 B（后台任务快速驳回 `ServiceBusyException` 切云）**，**不维护堆积队列**。~~补充抢占规则——前台对后台可主动 `cancel` 让槽、前台连发新消息时对旧请求 `cancel(requestId)` 快速中断后执行最新请求，**绝不驳回用户**。~~ **[SSOT 修正 2026-11-06：打断术语改协作式打断（打断语义实证收口，与 task-capability 评审修正同轮对齐）]**——底层算子阻塞不可切分，**中断只在生成循环检查点生效**：前台对后台、前台连发新消息仍对旧请求 `cancel(requestId)`，但取消请求须等旧生成到达检查点才被消费，**等待窗口耗尽不得假设打断已生效**（旧流继续占用执行槽，新请求按 `ServiceBusyException` 策略性降级切云）；**不得以重启引擎腾算力**（重启即冷装载，代价远超等待）。
- **生命周期状态（v2.3，详见 NPU 稿 §4.1）**：引擎暴露 `ACTIVE → WARM-STANDBY(3~5min TTL) → COLD-EVICTED` 三态；`isAvailable()` 在熔断（§5 R7）或冷卸载未暖机时返回对应状态，调用方据其决定本地执行或云端降级。
- **后端工厂**：`OnDeviceEngineFactory.resolve()` —— 先 `CapabilityProbe` 探测（`SoC 识别 → QNN/NeuroPilot 原生驱动与动态库可加载性 → NPU Delegate 初始化测试 → 系统可用 RAM 门禁`），再按芯片启发式（`Build.SOC_MANUFACTURER`：`qualcomm`→QNN；`mediatek`→NeuroPilot）选后端；**任一 NPU 后端不可用直接收口 `HybridCloudEngine` 纯云端，不回落 CPU 跑大模型**。
- **复用既有**：`engineFor` 装配入口、`HybridCloudEngine` 云↔端路由、`OnDeviceResultSummarizer` 既有的「单一提取/分类 + 约束解码（Grammars/Regex）」职责（architecture §78 端侧职责硬约束不变）。
- **IPC 通信架构（详见 NPU 部署稿 §6；S3-7 UDS 化收编 2026-10-30，TLV 协议定型）**：**控制面 Binder/AIDL**（init/generate/cancel/release/EngineDied 低频）+ **数据面 UDS socketpair 流式管道**（token 流式高频，TLV 成帧 `[2B 魔数 0x5A 0xA5][2B 帧类型][4B 大端 len][payload]`：TOKEN_CHUNK/EOS 在用，IMAGE_META/PROGRESS 留位多模态；魔数失步 fail-fast + 未知类型 skip 前向兼容；唤醒/背压/崩溃隔离由内核 socket 语义承载，写端 3s 有界超时判 IPC_DEADLOCK）——数据面消费 = 主进程 native worker（libgdw：epoll 等 socket 读端可读 + 帧重组 + `Dart_PostCObject_DL` 直投 Dart，EOF=数据面死亡判活自愈重建；S1-5 的 Binder onTokens 过渡通道已退役）；`:engine` 绑定须 `BIND_AUTO_CREATE | BIND_IMPORTANT` + `onTrimMemory` 驱动状态机；`cancel/release` 经 atomic `stop_requested` 下沉中断 NPU，避免后台空跑；FGS 保活须在 Activity 前台时预挂（Android 12+ 后台启动限制，见 NPU 稿 §6.2）。
- **控制面 AIDL 契约（开工即落码，v2.7 拉齐；S1-2/S1-3 施工细化；M2/M3/M4 修订）**：`IOnDeviceEngineService.aidl` 方法集 = `int initEngine(in Bundle config, IOnDeviceEngineListener listener)`（细化：listener 入参承载 `onEngineDied()` 由 `:engine` 侧主动通知，v2.7 未指定传输面）/ `ParcelFileDescriptor getDataSocketFd()`（S3-7 UDS 化：数据面 socketpair 读端，:engine 持写端，fd 经 Binder detachFd 移交；成帧协议与 EOS 语义见 NPU 稿 §6.1 v3.1）/ `void startGenerate(String requestId, String promptJson, in Bundle generationParams, String expectInstanceId, long expectSeq)`（M3 原子自证：epoch 复合键入口闸，拒绝分码 `SESSION_EPOCH_MISMATCH`/`SESSION_LOADING`）/ `int loadModel(String modelDir, String modelId)`（M2：modelId = 资产面单点计算，票据回显承载 I3）/ `void cancelGenerate(String requestId)` / `void truncateContext(int keepTokens)` / `void releaseEngine()` / `Bundle checkSession()`（M4 起为**唯一**状态查询面：权威状态 + 代次 + 资产身份票据，`checkStatus` 轮询面已删）。约束：`generationParams` 须承载 `GenerationConfig` 字段，**停用词以 intArray/intArrayList 传预编码 id 序列**（§6.7，禁字符串级匹配）。
- **公共服务注册**：作为 App 级内核纳入注册中心（类比 `ServiceDirectory`），UI 零直连；对外暴露面走既有 `host` 虚拟服务纪律（`host-tools-gateway-export.md`），**零隐私只读默认**，推理/写能力须单独立项。

## 3. 芯片分发与模型分发

- **模型产物按芯片 + HTP 架构版本分（均为 3B~4B 级 LLM）**：高通 QNN 优化包须**按 HTP 架构版本精确到 SoC**（8 Gen2=HTP v73、8 Gen3=HTP v75、8 Elite=HTP v79；**跨版本 context 二进制互不兼容**，针对 v75 编译的产物无法在 v73/v79 加载，见 NPU 稿 §3.5/§4.5）；联发科**现阶段不支持**（v3.3 修订：接口留位）——届时路线 = **LiteRT-LM + NeuroPilot Delegate** 下发 `.litertlm` 资产（按天玑 SoC 分发：MT6989=9300 / MT6991=9400 已入官方 NPU 支持表），原生 Neuron 编译产物不作基线；二者均**不随包**，按本机 SoC/HTP 版本动态下发。**LiteRT `.tflite` 仅作为百兆级轻量小模型（意图分类/PII 提取）产物，不承载 3B~4B LLM**。Google 系统模型（Gemini Nano / AICore）因不对第三方开放，不纳入本方案资产链。
- **原生驱动库内置 `jniLibs`（v2.5 新增）**：`libQnn*.so` / Neuron 运行时 `.so` 必须随 APK/AAR 的 `jniLibs` 发布（单架构 ~30MB），**不**经 OTA 下发——规避 Android W^X / `dlopen` 限制（详见 NPU 稿 §4.7）；OTA 仅分发模型 `.bin` 静态数据资产。
- **分发策略**：APK **不内嵌**大模型（体积/合规，Google Play AAB ≤200MB、国内商店禁数 GB 包）；经既有自更新 / 资源中心通道**按需分片下载 + 校验 + 签名 + 本地解密**（对齐 `self-update.md` 的 sha256 + R2 源），按探测到的后端/SoC 选对应产物。
- **双段路由与降级链（v3.3 定型）**：路由拆两段——**资产路由（静态/下载面）**：按机型与资产族定栈，GGUF→GenieX 系、`.litertlm`→LiteRT-LM 系，二选一下载，跨栈推荐只发生在此层；**运行时降级链（同栈内闭环）**：GGUF 族 `QAIRT(NPU) → llama_cpp+GPU → 云端 [DEGRADE]`、`.litertlm` 族 `LiteRT-LM(NPU) → LiteRT-LM(GPU) → 云端 [DEGRADE]`；**禁运行期跨栈横跳**（资产内存镜像不互通，切栈=1.5~2GB 卸载+冷装载，单请求内不可达）。热/OOM 不触发兜底，直接收口 `HybridCloudEngine` 纯云端（遵「禁 CPU 分流」，CPU 全程出局；D-4 修订：llama.cpp 永久保留，双栈长期并存无退役条件）。既有 `HybridCloudEngine` 降级判据不变。

## 4. 分期

### P1（本期 · 已定范围，分阶段交付）

- 公共服务内核 + 后端工厂 + 能力探测 + 与云端搭配（提取/分类/摘要/约束解码 + 断网兜底）。
- **仅 App 内 AgentLoop 消费；不对外导出**。
- **能力供给面收口（task-capability W3 升格，2026-11-04）**：算力供给经 `OnDeviceCapabilityService` 统一入口——`complete` 唯一推理入口（无状态/幂等）+ `completeStream` 流式（取消随退订下沉）+ `availability()`/`loadExplicit()` 可用性查询与幂等显式装载 + `PrimitiveSuspension` 挂起态契约 + 约束解码规格 `GenerationConfig.responseFormat` 双端承载（键面 = `SessionTicketWire.kt` GenerationParams，跨仓立法源 goodshare `ai-app-split.md` §3.11 已同轮修订）；语义注入走 `supply/` Skill 命名空间（宿主内置语义，端侧资产零模板）。
- **P1-A（首发）**：骁龙 8G3/8 Elite + QNN + `:engine` 独立进程 + 云端降级，拉通 Dart 全链路闭环（详见 §0 分期）。
- **P1-B（跟进）**：联发科 NeuroPilot，依赖企业资质/ROM 验证专项（见 R1），与 P1-A 解耦。
- **强制验收（P1 阻塞项）**：① `:engine` 独立进程架构；② NPU 不可用/异常时直接收口 `HybridCloudEngine` 纯云端（**无端侧 LLM CPU 兜底**）；③ 引擎进程崩溃/OOM 仅触发 `EngineDiedException`，主进程零闪退；④ **两级熔断保护**（L1 5min≥2 次→进程内切云冷启自愈、L2 当天累计 2 次→持久化锁 24h，`isAvailable=false`，详见 NPU 稿 §6.5）；⑤ **单执行槽 + 策略 B 驳回**（并发 `generate` 不导致 KV 覆盖/驱动 Panic，前台连发 `cancel` 快速中断不驳回用户，详见 NPU 稿 §6.6）；⑥ **存储落地合规**（filesDir 非 cacheDir + ≥5GB 空间门禁 + 原子替换，详见 NPU 稿 §4.5/§4.7）。
- 验收：真机旗舰 warmup/推理/降级链路；约束解码（regex/json）实证；`EngineDied` 注入测试（模拟驱动 Panic 验证无缝切云）；**Crash→重启死亡循环熔断测试（5min≥2 次→休眠）**；**并发 `generate` 互斥测试（后台 `Summarizer` 触发时返回 `ServiceBusyException` 不 Panic）**；**模型热更新原子替换不 SIGBUS 测试**；与既有 `HybridCloudEngine` 等价回归。

### P2（待定 · 候选方向，须经拍板）

- **P2-a**：经 `host` 虚拟服务导出为网关可调用能力（PC 经 `:8766` 反向 sampling / tool 调端侧推理）——**属产品定位问题，须单独立项**（architecture §59）。
- **P2-b**：跨 App / 本地插件经 Binder 复用端侧引擎（复用 `local-plugin` 通道）。
- **P2-c**：多模态端侧（图片/PDF）——依赖 LiteRT/FM 多模态 + FC2 端侧 PII 检测。

## 5. 风险与缺口登记（关联 on-device epic）

| # | 风险 | 说明 / 关联 |
|---|---|---|
| R1 | 联发科厂商资质与 ROM 隔离 | Neuron Compiler / GenAI Toolkit 需企业 NDA；`libneuron_runtime.so` 受 SELinux 与厂商 ROM 符号暴露限制，第三方 JNI 直调存在准入/兼容风险——P1-B 专项推进，不阻塞 P1-A |
| R2 | 模型分发体积/合规 | 不内嵌，按需下载 + 校验 |
| R3 | 独立进程隔离（**P1 刚性前置**） | 3B~4B 引擎常驻 1.8~2.4GB + FastRPC 驱动交互，若在主进程则驱动 Panic/OOM Killer 直接闪退主业务；**必须 `:engine` 独立进程（Binder/Ashmem）**，崩溃仅 `EngineDiedException` 无缝切云（承接 thirdconnect §9.5，G6 由建议升为 P1 阻塞） |
| R4 | 双芯片私有编译器与 context 产物维护成本 | QNN 与 NeuroPilot(Neuron) 两套模型产物 + 各 SoC 专属编译 context + NDK 依赖；proguard keep 教训（context/lessons.md）|
| R5 | 对外导出是产品定位 | 非工程默认（architecture §59），P2-a 须单独立项 |
| R6 | iOS 双端纪律 | iOS 端侧引擎 = MLX/Core ML 适配位（M2 做）；本期 Android-only |
| R7 | 重启风暴（Crash 死亡循环） | 恶性 Prompt 命中 NPU 驱动算子越界 → 崩溃重启再崩溃，耗尽资源/被系统前台强杀；**两级阶梯熔断（L1 内存态 5min≥2 次→进程生命周期切云、冷启自愈；L2 当天累计 2 次→持久化锁 24h，见 NPU 稿 §6.5）** |
| R8 | 并发推理互斥 | NPU 物理单重入，多调用方并发 `generate` 致 KV 覆盖/驱动 Panic；`:engine` Priority FIFO 队列 + `ServiceBusyException` 驳回（见 NPU 稿 §6.6） |
| R9 | 资产落盘 / 热更新 | 误放 cacheDir 被静默清空致反复模型重下（≈1.8GB）；热更新覆盖 mmap 致 SIGBUS；须 filesDir + ≥5GB 空间门禁 + 原子 rename/link（见 NPU 稿 §4.5/§4.7） |

## 6. 评估结论（拍板建议）

1. **方案可行**：与既有 `HybridCloudEngine` + 纯 Dart 抽象纪律（coding-standards §1.3）契合，无架构冲突；公共服务化是既有 `host` 虚拟服务纪律的自然延伸。
2. **修正路由模型（v2）**：从「谷歌方案二分」改为「**芯片厂商官方 SDK 路由（高通=QNN，联发科=NeuroPilot）+ CapabilityProbe 可用性门禁 + 不可用直接收口纯云端**」，剔除已废弃的 NNAPI、不对第三方开放的 AICore，以及端侧 LLM 的 CPU 兜底。
3. **P1 范围收敛得当**：App 内 + 云端搭配是正确 MVP，复用既有降级判据，工程增量可控。
4. **P1 前置依赖（刚性）**：**`:engine` 独立进程（G6）为 P1 阻塞项**，须与模型分发同步落地；P2-a 立项 + 模型分发齐备方可启动；多模态（P2-c）另受 FC2 约束。
5. **前置交付物**：QNN 优化模型包 + Neuron 编译产物就绪、`CapabilityProbe` API（SoC 识别 + 驱动可加载性 + NPU Delegate 初始化 + RAM 门禁）、`:engine` 独立进程通信骨架。

## 决策日志

> devlog 决策/权衡类条目的归档专节（dev-loop §4；机械件 `toolbox run dlog <epic>` 同文幂等追加）。

- [2026-11-08] W6 联调 executor 空产出终态归因 = litertlm 0.16.0 NPU 管线对 Gemma3 特定内容族的间歇性零产出（内容敏感 + 非确定性），缺陷位于 SDK 内部，宿主侧（含会话生命周期管理）无可修缝位；产品口径 = Qwen3.5-2B（llama_cpp）为 W6-a 验收基准档（e2e 3/3 绿），Gemma3×litertlm 档恢复使用前须升 AAR 0.16.0→0.18.1 重验（待拍板）（否决: 会话生命周期实现层修复——沉降闸/close 延后两轮实验均证伪；采样档/prompt/装载窗口/requestId 变量排除——逐项证伪；探测闸类缓解——user-only 形态假阳性）
