---
dev-loop: memory
format: v1
epic: on-device
total-merged: 1
last-merge: 2026-11-07
---

# on-device（端侧能力 · 现状盘点与缺口治理）

> 初始化状态文档（2026-10-28 立项）。本 epic 盘点 goodhub「端侧（设备侧 / App 本体）」能力现状与缺口，作为后续端侧能力补齐的断点基线。

- [挂载] docs/design/on-device-capability.md（端侧能力公共服务设计，本 epic 主设计稿：芯片分发/双后端/分期，v3.3 多栈构型修订）；关联稿同域：on-device-npu-deployment（引擎深度设计 v2.8）/ on-device-npu-runtime-split（运行库拆分）/ on-device-lifecycle-single-source（会话一致性 v2.3）/ context-stepped-pruning（阶梯截断）/ on-device-admission-probe / on-device-asset-metadata / on-device-residency（常驻评估，独立 epic）——全量指针见 docs/README.md 与 docs/project/index.md
- [横切·task-capability W3 升格（2026-11-04）] 端侧算力供给面服务形态 = `OnDeviceCapabilityService` 统一入口（`complete` 唯一推理入口无状态/幂等 + `completeStream` 流式取消随退订下沉 + `availability()`/`loadExplicit()` 可用性查询与幂等显式装载 + `PrimitiveSuspension` 挂起态契约）；约束解码规格经 `GenerationConfig.responseFormat` 双端承载（键面 = `SessionTicketWire.kt`，跨仓立法源 goodshare `ai-app-split.md` §3.11 已修订）；语义注入走 `supply/` Skill 命名空间（宿主内置，端侧资产零模板）——SSOT = `on-device-task-capability.md` §4.1/§5.1，本条为挂载锚（防双源，只指不抄）
- [关联] docs/design/resource-center.md（一期不做二进制多模态）/ thirdconnect.md（G6 独立进程 §9.5/§10.5）/ host-gateway-accessibility-memory.md（§10.1 韧性/§10.4 硬截断/§3.5 摘要器）/ docs/product/architecture.md（端侧引擎职责/双端策略/N7 围栏）/ future-considerations.md（FC2 多模态 PII）

## 定位（域界）

本 epic 归属「端侧」四类能力，**服务端 / 云端链路不归本 epic**：

1. **端侧推理引擎**：LiteRT-LM 接入、模型管理（目录/下载/清单）、多模态支持、iOS 适配位、端侧 OOM 进程隔离。
2. **端侧摘要与上下文治理**：`OnDeviceResultSummarizer` 串联、超大 Tool Result 确定性地板、阶梯截断归档摘要。
3. **端侧 PII 遮蔽**：非结构化 PII 的端侧模型层、多模态 PII 检测。
4. **移动端生命周期与 Agent 韧性**：`AppLifecycleState` 钩子、重连降级、端侧 Agent 失控环路防护。

## 现状盘点（按四类分组）

### A. 端侧推理引擎

| 项 | 现状 | 缺口 / 描述 | 落点 | 触发 / 状态 |
|---|---|---|---|---|
| 端侧模型管理链（目录/下载/清单缓存） | `archive/local_model/` 已归档，**零接线零测试**；`lib/llm/llm_model.dart` 仍作活代码被 `llm.dart` 引用 | 端侧推迟拍板未翻转前不复活 | `archive/local_model/` | 未复活（需拍板翻转） |
| 端侧 LiteRT-LM 多模态 | 一期资源中心**不做**图片/PDF 直读 | 「端侧 LiteRT-LM 不支持，云端 BYOK 多模态通路未验证」 | resource-center §1 | 一期拒收二进制 |
| iOS 端侧引擎适配位 | Android=LiteRT-LM(`LlmBridge.kt`)；**iOS=MLX/Core ML 适配位（接口 M1 留、实现 M2 做）** | 端侧引擎缺失在 iOS 初期视作「引擎未挂载」既有分支 | architecture 双端策略 §133-145 | 前置：macOS 构建环境 / Apple 开发者账号 / MLX 适配 |
| 端侧引擎内存与冷启动 | Q8 1.5B 文件 1.49GB，全量加载增量 ~1.9GB、进程峰值 PSS 2.70GB（CPH2767 实测） | **加载模型改为按需懒加载（2026-10-29）**——启动不预载/不占权重内存、:engine 不预启，首次命中端侧路径才显式 enable()（bind→就绪→资产→loadModel→数据面 worker，loadState 可见）；冷加载真空期反馈=「⏳ 端侧模型加载中…」 | architecture §78 | 已落地（懒加载兜底 + 显式加载态，q-1 加载失败显式报错不切云） |
| 端侧模型 OOM 拖垮 PC 网关 | 单进程硬约束仍生效，`:gateway` 未拆独立守护进程 | 拆 UI 与网关为独立进程防端侧模型 OOM 拖垮 PC 远程网关 | thirdconnect §9.5 / §10.5（G6） | **未落地（G6 未排期）** |
| 端侧 LLM 设计 SSOT | 跨仓只读 = goodshare 仓 `docs/design/on-device-llm.md` | 本仓不持有端侧 LLM 设计立法 | index 文档落点 | 跨仓只读 |

### B. 端侧摘要与上下文治理

| 项 | 现状 | 缺口 / 描述 | 落点 | 触发 / 状态 |
|---|---|---|---|---|
| 端侧摘要器实证 | `OnDeviceResultSummarizer` 已证「异步小模型管线可行」(`context_governor.dart:75-98`) | `$ref` 句柄注水真机路径**待端侧摘要器实证** | m3 §头注 / host-gateway §3.5 | 实证待补 |
| 超大 Tool Result 确定性地板 | 仅模型摘要路径，存在 `summarizer==null` 与摘要失败两条原文直出旁路 | 缺端侧引擎或摘要失败时零上限直入上下文，击穿单轮窗口 | host-gateway §10.4 | **已锁定** D-I 硬截断 `kToolResultHardCap=2000t≈8KB`（Head50+Tail20） |
| 阶梯截断 + 端侧摘要归档 | 朴素逐轮滑动窗口「每轮 100% Cache Miss」+「出窗即失忆」 | 高低水位双缓冲(6~12) + 被裁轮次经端侧摘要器归档回注 | context-stepped-pruning.md | **已落地**（2026-11-03 盘点代码面零缺口；§2.5 ADR draft→active；KV 实证 [Fact] 每请求全量重 prefill、无跨请求前缀复用）；§5 含「端侧引擎不可用时云端摘要降级（默认不做）」 |

### C. 端侧 PII 遮蔽

| 项 | 现状 | 缺口 / 描述 | 落点 | 触发 / 状态 |
|---|---|---|---|---|
| 端侧遮蔽模型质量 | 正则四类（手机/邮箱/身份证/银行卡）已落地；地址、人名等非结构化 PII 归端侧模型层 | 「端侧遮蔽模型质量未实证（M2 实测）」；遮蔽失败宁可拦截请确认，禁静默放行 | architecture §219 N7 | T7+ 端侧模型层 |
| 多模态 PII 边界失效 | 正则仅覆盖 UTF-8 文本 | MCP 二进制 Resource(image/png、PDF、音频) 围栏对非文本失效 | FC2 | 已留锚：非文本 MIME 默认禁直塞云端、需 L2 放行；**触发=M3+ 多模态接入 → 评估端侧图像 PII 检测模型** |

### D. 移动端生命周期与 Agent 韧性

| 项 | 现状 | 缺口 / 描述 | 落点 | 触发 / 状态 |
|---|---|---|---|---|
| 移动端生命周期与重连 | D1 已落地（2026-11-03）：ConnectionHealth pause/resume（pause 仅摘定时器、resume 立即探活压 SSE 假死窗口）+ 静态注册表 `_live` + main.dart 生命周期挂钩（resumed→resumeAll+端侧预热 / paused/hidden/detached→pauseAll）+ 测试钉 3 例 | unreachable「仅 Public 工具」不建显式机制（裁决：不可达工具经 ToolRouter 熔断收敛 isError，语义已覆盖） | host-gateway §10.1（现状已回填） | **已落地** |
| 端侧 Agent 失控环路（Loop Storm） | Trace-ID + Hop-Count 跨协议强制透传已落地（`gateway_loop_guard.dart` `hop_count≤2` 熔断） | 风险：PC→网关→本地 App→自动化脚本→又调 `:8766`，或端侧 Agent 失控无限递归 | thirdconnect §9.5 | **已防护**（机制存活，非缺口） |

## 已锁定 vs 未落地（速判）

- **回退链终态（2026-11-01 拍板，演进史=多次推翻收敛）**：**NPU(QAIRT) → GPU(llama_cpp) → 云端 [DEGRADE]，CPU 彻底出局**——llama_cpp nGpuLayers 0→-1（2026-11-06 [Fact]：ngl=0 静默落 CPU，全部历史 bench 均兜底路径；修复后生产 31.5~32.7 tok/s = 5.6×）；**旧「NPU build 失败回落 llama_cpp+CPU」ADR（2026-10-31）已被本条推翻**（decisions.md 对应条标记）；准入探针与坏后端记忆合并为单一 `DispatchProfile`（`.admission.json`，键=`modelId # Build.FINGERPRINT`，驱动指纹漂移脏删重探）。
- **现在不做（2026-11-03 盘点裁决，均带触发器）**：模型管理链复活（A1，触发=需免 SAF 的在线 OTA 分发）、iOS 端侧引擎适配（A3，硬前置缺位纯留位）、端侧模型 OOM 独立进程化 G6（A2，触发=真机网关连带死亡）、端侧摘要器 `$ref` 注水实证（B1，随下次真机轮顺带）、端侧 PII 模型层（C1，触发=真实受损案例）、多模态 PII（C2，触发=M3+ 多模态接入）。阶梯截断 / 移动端生命周期钩子已于 11-03 落地，不再列。

## 实施史与关键定音（2026-11-07 自 devlog 552 行全量归并；细节见 devlog 归并注记与 git 历史）

- **设计立稿与拍板（10-28）**：两稿 v2.0→v2.8 六轮评审硬化（D1 中低端不支持纯云端 / HTP v79 修正 / :engine 独立进程刚性前置 / 两级熔断 L1 内存态+L2 24h 持久 / Prefix Cache 唯一 KV 复用主路线 / busy 禁缓存 TOCTOU / W^X .so 入 jniLibs / FGS Android 12+ 时序硬约束）；**GenieX 路线拍板**（Genie/llama.cpp 管线替换手写 QNN C API 推理内核，外围防护 100% 保留）；QAIRT 免 NDA（需 NDA 的是联发科 NeuroPilot）。
- **S1+S2 交付（10-28~29）**：:engine 进程骨架 / AIDL 控制面契约 / TokenRingBuffer SPSC（单调掩码协议）/ 轻量 Detokenizer（GHDT 表）/ Mock 切云联调 / 两级熔断；S2 真机三坑（extractNativeLibs / uses-native-library / run-as 禁——均入 lessons）+ http 大文件静默截断根因（流式+字节级校验）+ OTA 资产通道（sha256/原子替换/指纹自愈）。
- **TPOT 归因与换线（10-29）**：roofline 判 35ms 物理边界（可达 62~66ms 参考件基准）/ 全部用户态 knob 证伪（cpu-mask/rpc/采样/投递链）/ perf_profile burst→sustained +32% / 官方 App 4B 23 tok/s vs 我方裸 Genie 8.9（参考件同速定音）→ **运行时管线代差，换线 geniex-android 0.3.5**（首验 21.85→24.01 tok/s；坑：OTA manifest 必须携带 metadata.json）。
- **S3 调度边界（10-29）**：EngineSlot 原子抢占 + ServiceBusyException（Binder 只保 message 禁 is 判别）/ FGS promote 前置 kFgsPromoteMinTokens=256 / MemoryGuardEvaluator availMem 判据（GenieX 路线 PSS 恒 ~103MB 不可达）/ native worker S3-6（dart_api_dl 纯 C 件独立 STATIC 目标 / AGP cmake 缓存 touch 坑）。
- **生命周期风暴与数据面定音（10-29~30）**：懒加载拍板（q-1 显式加载失败不切云）；JNI tagged 指针判负（恒判 !=0L）；装载被杀链（**BIND_ABOVE_CLIENT 反噬定音**→BIND_IMPORTANT / 单例装载纪律 loadedOnce / 快死棘轮）；**ipc-deadlock 三缺陷定音**（写者等空间必唤醒 / 40ms 兜底节拍 / 判活重建）+ **VarHandle 坐标语义 JVM 字节偏移 vs ART 元素下标**（运行时自检自适应——JVM 单测测不出的同型病第二次）；尾字节丢失（先投递后推进 read_idx + awaitDrained）+ 无进展看门狗 30s；S3-7 UDS 化 TLV 协议（魔数/EOS 单源/前向兼容）；场景 A/B/C 切云语义拆分（后台未装载不切云禁数据外发 OD2）；OD1~OD5 裁决（两段式保留 :engine / 暂存 TTL30min / 资产迁内部目录）；**导入制转型**（纯导入制无默认模型/SAF/压缩包）；机制审计 19 项 + P0-1/2/3 修复 + arch-guard R11 双向护栏（落地即抓 2 漏接）。
- **会话一致性重构（10-31）**：lifecycle-single-source v2.1 封板（SessionTicket `(instanceId,seq)` 复合键 / 投影作废禁猜测复位 / 五不变量+装载单飞 I7 / M1~M4 落地 / checkStatus 退役 / loading 序数 7）；复读环双刀闭环（ChatML 多轮→**SDK applyChatTemplate 单源**，OOD 复述根因）；温控全链摘除 + 门禁降 advisory（用户裁决：OEM 热档≠体感）；GPU 档落地 CPU 退役（39 tok/s 基线）；F1~F6（complete 原语门面 / expectModelId / 大载荷临时文件 / 混沌矩阵骨架 / G2 墓碑三件）；流式契约 Stream<String>。
- **多栈构型（11-01~03）**：运行库拆分终态（LiteRT-LM 内置 +10~12MB / GenieX 增配 ~47MB 减重 / Spike 4 件套装载集 / 弱网续传 / 换版 checklist）；D-1~D-4 四裁决+三修订（双段路由禁跨栈 / 联发科接口留位 / llama.cpp 首发关闸→11-05 放开默认 true）；LiteRT-LM Runner 集成（双实例注册表 / StopSequenceMatcher 跨帧匹配 / stopSequences 字符串契约跨仓立法 goodshare ai-dev-spec §4）；DispatchProfile 准入画像（陷阱档「慢而活着」=已知限制）；多机型清单化（R2 四工件 family schema，新芯片代际=改清单零发版）；GGUF header 解析器 + 元数据管线（来源分级 S0>S1>S2 / **model-specs.json per-bundle 规格表**=模型适配单源 / KV 区 32MB 预算）；RepetitionGuard（阈值 4，命中 abort 不计熔断）；历史策略模式（⓪真裸=端侧默认 / ②锚点+近窗 / ③摘要实验位——**价值仅小窗模型成立**，Gemma「玄鸟」对照实证，Qwen 大窗 ①≡②）。
- **Qwen 真机轮（11-04~06）**：通路三前置跑通 / contextTokens 收敛 n_ctx 防满窗 LMK / 超窗=SDK 硬失败 [Fact] / 版本退化侦查（二分 0.3.5→0.8.0 引入 → AAR 本体定性 → qairt 0.3.5 前置门硬失败 err 5000）→ **归因反转：ngl=0 静默兜底，无版本退化；ngl=-1 修复 5.6×**（生产 31.5~32.7 / demo 33.1 tok/s）；libggml-cpu SIGSEGV 长输入观测（NPU 路径可能绕开，复验在 todos）。
- **真机驱动工具链（11-05~06）**：debug-bridge 宿主动作面（list_models / set_history_policy / get_history_policy / query_on_device 强制端侧 / tap_bounds / wait_log / system-ui / system-tap / --file）；on-device-chaos-matrix 六例驱动器；装机判据修正（dart-define 值烤入串判构建变体 + 哈希比对纪律）。
- **验证批次 P0~P3 收口（11-06）**：S11 任务对照 classify pass（迁移前提成立）；P2 12222 复评闭环（Qwen 族不复现，触发器=长 system 指令）；P3 独立核验通过。**待立项**：P4 端侧 2B 工具调用质量实验（S2 前置）、P5 ③摘要器接线。

## 断点

- [断点] 下一步：devlog 全量归并收口（552 行提炼入 memory「实施史与关键定音」，total-merged 1，MOUNT 收敛 1 行，todos 口径清理 23 条）；余项=P4 工具调用质量实验 / P5 摘要器接线 / 上游 issue 提交拍板 / ngl=-1 commit 待用户——均为用户侧或另行立项，域内无机械债
