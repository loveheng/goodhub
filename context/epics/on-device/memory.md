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
- [横切·task-capability W3 升格（2026-11-04）] 端侧算力供给面服务形态 = `OnDeviceCapabilityService` 统一入口（`complete` 唯一推理入口无状态/幂等 + `completeStream` 流式取消随退订下沉 + `availability()`/`loadExplicit()` 可用性查询与幂等显式装载 + `PrimitiveSuspension` 挂起态契约）；约束解码规格经 `GenerationConfig.responseFormat` 双端承载（键面 = `SessionTicketWire.kt`，跨仓立法源 goodshare `ai-app-split.md` §3.11 已修订）；语义注入走 `supply/` Skill 命名空间（宿主内置，端侧资产零模板）——SSOT = `on-device-task-capability.md` §4.1/§5.1，本条为挂载锚（防双源，只指不抄）
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

- **已锁定机制**：超大 Tool Result 硬截断（D-I）、Loop Storm 环路防护（`hop_count≤2`）、N7 正则四类 + 无人值守 fail-closed、**NPU 兜底（2026-10-31）：`GenieSession.doLoad` 以 QAIRT+NPU 为主路，仅 QAIRT build 失败（NPU 驱动/HTP 不可用）回落 `llama_cpp+CPU` 完成本会话（同 GGUF 资产 + tokenizer，AAR 已捆绑两插件）；热/OOM 不触发兜底仍收口云端（遵「禁 CPU 分流」）；Dart 路由层/AIDL 不变（运行时无关），D1a 设备分档不变，仅推翻 D1「无 CPU 兜底」条款且限定高端 NPU 设备（`decisions.md` ADR）**。
- **已锁定机制（续·2026-11-01 拍板）**：**端侧回退链物理重构 = NPU(QAIRT) → GPU(llama_cpp+GPU) → 云端 [DEGRADE]**，CPU 彻底出局（含代码路径物理删除，待 GPU Spike 全绿后执行）；**推翻 v3.2「NPU build 失败回落 CPU」条款**（`decisions.md` ADR 对应条据此修订）。破窗效应依据：留 CPU 分支会在偶发超时/内存受压时启发式滑落 CPU，复现发热与前台假死；云端安全网（HybridCloudEngine 第一等公民）足以兜底，且可借 [DEGRADE] 打点倒逼 GPU 档闭环。
- **已锁定机制（续·2026-11-01 拍板）**：**准入探针与坏后端记忆合并为单一 `DispatchProfile`** —— 按 `modelId # Build.FINGERPRINT` 为键的 `{backend: {verdict: HEALTHY|EXCLUDED, reason, ttftMs, memBytes, probedAt}}`，两个写入方（导入后准入探针 + 运行时崩溃/零产出）共享、一个消费方（Dart 路由查表分流，不再拉 `:engine` 踩已知坑）；画像存 `.admission.json`（与 `.asset-meta.json` 同目录），复用 `asset_manager` 的 `recoverIfDriverChanged` 驱动指纹失效 → 脏删重探。设计稿 = `docs/design/on-device-admission-probe.md`。
- **现在不做（2026-11-03 盘点裁决，均带触发器）**：模型管理链复活（A1，触发=需免 SAF 的在线 OTA 分发）、iOS 端侧引擎适配（A3，硬前置缺位纯留位）、端侧模型 OOM 独立进程化 G6（A2，触发=真机网关连带死亡）、端侧摘要器 `$ref` 注水实证（B1，随下次真机轮顺带）、端侧 PII 模型层（C1，触发=真实受损案例）、多模态 PII（C2，触发=M3+ 多模态接入）。阶梯截断 / 移动端生命周期钩子已于 11-03 落地，不再列。

## 断点

- [断点] 下一步：① **观测债三件 + 采样 A/B 全收（2026-11-05 真机轮）**——drift 修复（reconcileLoadStateFromTicket）、归因过滤白名单扩充（session_loading 类不记 crash）、loadTimeoutSec 实现（§7 裁决 5，Qwen 声明 180 重导入落盘）、采样 A/B（A/C 干净零复读 → recommendedSampling 维持不写禁猜值；B 组长输入被 libggml-cpu 0.10.0 SIGSEGV 阻塞不可评）、tombstone 归因（libggml-cpu `ggml_cpu_extra_compute_forward` 两次复现，重评触发器 = geniex 升版 >0.10.0）。② 剩余待办：geniex 升版后重跑（hexagon NPU + libggml-cpu 崩溃 + B 组长输入复评三件合并触发）、session-mirror drift 已修待下次 bench 轮验证。③ debug-bridge 工具批两批全落地——批一（tap_bounds+前台守卫/wait_log/ui-tree NaN 容错/--file+stdin/device-log）；批二系统 UI 绕行（foreground 报前台包名+是否 GoodHub / system-ui 解析系统 UI 可点节点 / system-tap 系统级 tap）——**下次真机调试优先桥面语义端点，截图仅最后手段**：GoodHub 内 UI 用 tap_bounds（粘贴 ui-tree bounds），系统 UI（SAF/权限弹窗）先 foreground 判断再 system-ui 定位 + system-tap 驱动，等结果用 wait_log 非睡眠。已知限制：SAF 文件行仅 dump 出 click=false TextView，精确点选受系统 UI 交互限制（可后续增强 system-ui 输出 clickable 容器）。设备现态：干净包含全部修复 + Qwen 已重导入（meta 含 loadTimeoutSec=180）+ GenieX 增配 v0.10.0 已装
