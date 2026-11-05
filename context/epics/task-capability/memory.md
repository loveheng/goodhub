---
dev-loop: memory
format: v1
epic: task-capability
total-merged: 4
last-merge: 2026-11-04
state: maintenance
---

# task-capability（端侧算力供给与跨 App 任务协作）

> 立项 2026-11-03，六轨收口 2026-11-04。全部约束 / 裁决 / 决策过程 SSOT = 挂载设计稿（决策日志 8 条含 D1~D4 终态裁决 + 实施期裁决五条）；完成项全文 = `context/done.md` 域段；过程流水归 Git log。

- [挂载] docs/design/on-device-task-capability.md（主设计稿：四层分层 / 判定链 / 供给面契约 / 开放边界 / 裁决记录 D1~D4 + E1~E8 + P1~P4 / 决策日志）
- [收口] W1~W5 六轨全落：判定链 S12~S15（声明 > 偏好 > 画像 > 冷却态，两类落空分端口径）｜供给面 S16~S20（complete 唯一入口 / 语义外注 supply/ 命名空间 / 约束解码双端下发 / availability+loadExplicit / completeStream 流式原语+挂起态）｜W4-A 形态 A（TaskSource 抽象 + 跨仓 Release 原语）｜W5 开放导出七件（HostOnDeviceToolExecutor / SupplyQuota K22 / 投影四档 / 访问控制五级 / PC 网关 + Binder 反向转发 / 死亡联动 CallerDeathInterrupt）｜S07/S07b 调用方身份（内核 UID 单源，真机实证 uid=10453 → com.zzh.goodshare + 签名）｜S18b 前缀复用契约留位（可选接口，不承诺命中率）。
- [红线] 供给面唯一入口 complete（S16，禁绕过直连 supply face）｜身份载荷不承载 + 解析失败按拒绝 -32001（S07b）｜跨 App 导出首期只暴露聚合完成面（K24）｜配额超限快速失败不切云（K21/K9 治理违规 ≠ 资源故障）｜协作式打断非抢占（K11，禁重启引擎腾算力）｜原语不触发装载（懒加载边界）。
- [待实证→已收口] 两条均实证闭合（2026-11-05 真机轮，Ace 6 / Qwen3.5-2B llama_cpp 栈，bench 变体）：① **前缀复用无收益 → Runner 侧不承载**——GenieSession 每请求 `w.reset()` 单发隔离下同 prompt 重发 TTFT 4661→4971ms（持平，无命中），GenieX llama_cpp 管线每请求全量重 prefill；S18b `PrefixReuseHint` 对 Genie 管线维持静默忽略不承诺命中（K12），单发隔离语义（§2.4）不受冲击，重评触发与 context-stepped-pruning §2.5 ADR 同源（SDK 暴露会话级复用接口）；② **超窗 SDK 行为**已于 2026-11-04 Qwen 轮实证（hybrid_cloud_engine.dart:717 [Fact]：超窗 = SDK 抛「Input prompt too long」硬失败非截断非崩溃），台账转 misc 已销。
- [遗留] W4-B 形态 B 封存待 D1 解封（三条件任一）｜打断表述订正（on-device 两稿，须排期对齐同轮改）｜推后项 P1~P4 随隐私线/模型质量实证｜on-device 同文件交集须排期对齐再并行。

## 断点
- [断点] 已完结：2026-11-05 真机轮收口最后两条待实证（前缀复用无收益定谳 + 超窗硬失败核销），任务性工作完结
