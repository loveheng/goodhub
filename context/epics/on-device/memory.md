---
dev-loop: memory
format: v1
epic: on-device
total-merged: 0
last-merge: none
---

# on-device（端侧能力 · 现状盘点与缺口治理）

> 初始化状态文档（2026-10-28 立项）。本 epic 盘点 goodhub「端侧（设备侧 / App 本体）」能力现状与缺口，作为后续端侧能力补齐的断点基线。

- [挂载] docs/design/context-stepped-pruning.md（阶梯截断 / 端侧摘要归档，draft）
- [挂载] docs/design/resource-center.md（一期不做二进制多模态——端侧 LiteRT-LM 不支持）
- [挂载] docs/design/thirdconnect.md（G6 独立进程防端侧 OOM；§9.5 Loop Storm）
- [挂载] docs/design/host-gateway-accessibility-memory.md（§10.1 移动端韧性 / §10.4 硬截断 / §3.5 端侧摘要器）
- [挂载] docs/project/index.md（端侧模型管理链已归档 / 端侧 LLM 设计跨仓只读）
- [挂载] docs/design/on-device-capability.md（端侧能力公共服务设计，draft，本 epic 主设计稿：芯片分发/双后端/分期）
- [挂载] docs/design/on-device-npu-deployment.md（端侧 NPU 最大化部署系统方案，draft，本 epic 引擎深度设计：协同分工/量化适配/内存带宽/热调度/端到端评估）
- [挂载] docs/product/architecture.md（端侧引擎职责 / 内存冷启动 / 双端策略 / N7 PII 围栏）
- [挂载] docs/product/future-considerations.md（FC2 端侧 PII 检测模型）

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
| 端侧引擎内存与冷启动 | Q8 1.5B 文件 1.49GB，全量加载增量 ~1.9GB、进程峰值 PSS 2.70GB（CPH2767 实测） | **加载模型改为按需懒加载（2026-10-29）**——启动不预载/不占权重内存、:engine 不预启，首次命中端侧路径才显式 enable()（bind→就绪→资产→loadModel→数据面 worker，loadState 可见）；冷加载真空期反馈=「⏳ 端侧模型加载中…」；退后台/Doze 仍 release()/disable() 释放权重 | architecture §78 | 已落地（懒加载兜底 + 显式加载态，q-1 加载失败显式报错不切云） |
| 端侧模型 OOM 拖垮 PC 网关 | 单进程硬约束仍生效，`:gateway` 未拆独立守护进程 | 拆 UI 与网关为独立进程防端侧模型 OOM 拖垮 PC 远程网关 | thirdconnect §9.5 / §10.5（G6） | **未落地（G6 未排期）** |
| 端侧 LLM 设计 SSOT | 跨仓只读 = goodshare 仓 `docs/design/on-device-llm.md` | 本仓不持有端侧 LLM 设计立法 | index 文档落点 | 跨仓只读 |

### B. 端侧摘要与上下文治理

| 项 | 现状 | 缺口 / 描述 | 落点 | 触发 / 状态 |
|---|---|---|---|---|
| 端侧摘要器实证 | `OnDeviceResultSummarizer` 已证「异步小模型管线可行」(`context_governor.dart:75-98`) | `$ref` 句柄注水真机路径**待端侧摘要器实证** | m3 §头注 / host-gateway §3.5 | 实证待补 |
| 超大 Tool Result 确定性地板 | 仅模型摘要路径，存在 `summarizer==null` 与摘要失败两条原文直出旁路 | 缺端侧引擎或摘要失败时零上限直入上下文，击穿单轮窗口 | host-gateway §10.4 | **已锁定** D-I 硬截断 `kToolResultHardCap=2000t≈8KB`（Head50+Tail20） |
| 阶梯截断 + 端侧摘要归档 | 朴素逐轮滑动窗口「每轮 100% Cache Miss」+「出窗即失忆」 | 高低水位双缓冲(6~12) + 被裁轮次经端侧摘要器归档回注 | context-stepped-pruning.md | **draft 未落地**；§5 含「端侧引擎不可用时云端摘要降级（默认不做）」 |

### C. 端侧 PII 遮蔽

| 项 | 现状 | 缺口 / 描述 | 落点 | 触发 / 状态 |
|---|---|---|---|---|
| 端侧遮蔽模型质量 | 正则四类（手机/邮箱/身份证/银行卡）已落地；地址、人名等非结构化 PII 归端侧模型层 | 「端侧遮蔽模型质量未实证（M2 实测）」；遮蔽失败宁可拦截请确认，禁静默放行 | architecture §219 N7 | T7+ 端侧模型层 |
| 多模态 PII 边界失效 | 正则仅覆盖 UTF-8 文本 | MCP 二进制 Resource(image/png、PDF、音频) 围栏对非文本失效 | FC2 | 已留锚：非文本 MIME 默认禁直塞云端、需 L2 放行；**触发=M3+ 多模态接入 → 评估端侧图像 PII 检测模型** |

### D. 移动端生命周期与 Agent 韧性

| 项 | 现状 | 缺口 / 描述 | 落点 | 触发 / 状态 |
|---|---|---|---|---|
| 移动端生命周期与重连 | 全仓**无任何 `AppLifecycleState` / `WidgetsBindingObserver` 钩子**；网关无 ping-on-resume / 半开 SSE 探测 / unreachable 降级 | 应：后台优雅暂停心跳、恢复前台 ping、不可达降级为仅 Public 工具 | host-gateway §10.1 | 缺口（优先补） |
| 端侧 Agent 失控环路（Loop Storm） | Trace-ID + Hop-Count 跨协议强制透传已落地（`gateway_loop_guard.dart` `hop_count≤2` 熔断） | 风险：PC→网关→本地 App→自动化脚本→又调 `:8766`，或端侧 Agent 失控无限递归 | thirdconnect §9.5 | **已防护**（机制存活，非缺口） |

## 已锁定 vs 未落地（速判）

- **已锁定机制**：超大 Tool Result 硬截断（D-I）、Loop Storm 环路防护（`hop_count≤2`）、N7 正则四类 + 无人值守 fail-closed、**NPU 兜底（2026-10-31）：`GenieSession.doLoad` 以 QAIRT+NPU 为主路，仅 QAIRT build 失败（NPU 驱动/HTP 不可用）回落 `llama_cpp+CPU` 完成本会话（同 GGUF 资产 + tokenizer，AAR 已捆绑两插件）；热/OOM 不触发兜底仍收口云端（遵「禁 CPU 分流」）；Dart 路由层/AIDL 不变（运行时无关），D1a 设备分档不变，仅推翻 D1「无 CPU 兜底」条款且限定高端 NPU 设备（`decisions.md` ADR）**。
- **已锁定机制（续·2026-11-01 拍板）**：**端侧回退链物理重构 = NPU(QAIRT) → GPU(llama_cpp+GPU) → 云端 [DEGRADE]**，CPU 彻底出局（含代码路径物理删除，待 GPU Spike 全绿后执行）；**推翻 v3.2「NPU build 失败回落 CPU」条款**（`decisions.md` ADR 对应条据此修订）。破窗效应依据：留 CPU 分支会在偶发超时/内存受压时启发式滑落 CPU，复现发热与前台假死；云端安全网（HybridCloudEngine 第一等公民）足以兜底，且可借 [DEGRADE] 打点倒逼 GPU 档闭环。
- **已锁定机制（续·2026-11-01 拍板）**：**准入探针与坏后端记忆合并为单一 `DispatchProfile`** —— 按 `modelId # Build.FINGERPRINT` 为键的 `{backend: {verdict: HEALTHY|EXCLUDED, reason, ttftMs, memBytes, probedAt}}`，两个写入方（导入后准入探针 + 运行时崩溃/零产出）共享、一个消费方（Dart 路由查表分流，不再拉 `:engine` 踩已知坑）；画像存 `.admission.json`（与 `.asset-meta.json` 同目录），复用 `asset_manager` 的 `recoverIfDriverChanged` 驱动指纹失效 → 脏删重探。设计稿 = `docs/design/on-device-admission-probe.md`。
- **仍为空缺 / draft / 未排期**：端侧模型管理链（已归档未复活）、iOS 端侧引擎适配、端侧模型 OOM 独立进程化（G6）、端侧摘要器 `$ref` 注水实证、端侧 PII 模型层、移动端生命周期钩子、阶梯截断端侧摘要归档（draft）。

## 断点

- [断点] 下一步：端侧默认⓪真裸已侧载（云端默认①不变）；下一步：真机日常对话复验（默认⓪下正常对话+多轮指代确认上下文丢失的体感可接受）；可选后续=⓪+精简短 system 变体（保行为约束，短指令是否触发未验证）
