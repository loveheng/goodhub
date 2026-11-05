---
dev-loop: devlog
format: v1
epic: task-capability
total-merged: 4
last-merge: 2026-11-04
---
- [2026-11-05] [变更]: 真机轮两条待实证收口——①前缀复用收益定谳[Fact]无收益：GenieSession 每请求 w.reset() 单发隔离下同 prompt 重发 TTFT 4661→4971ms 持平（bench 变体 short~256ctx vs short-repeat），GenieX 管线每请求全量重 prefill 无跨请求前缀缓存命中——Runner 侧不承载，S18b PrefixReuseHint 对 Genie 管线维持静默忽略不承诺命中（K12），与 11-03 LiteRT-LM 栈 cache probe（TTFT 随输入线性）及 11-04 Qwen 轮旁证（short 4372/repeat 5887ms）三方一致；②超窗 SDK 行为系 2026-11-04 Qwen 轮已实证（[Fact] 硬失败），本轮仅台账核销——memory.md [待实证] 行改写收口 + on_device_capability.dart 契约注释 [Fact] 化（PrefixReuseHint/PrefixReuseHandle 两处）
- [2026-11-05] [验证]: flutter analyze → No issues found（注释纯 doc 变更）；真机数据：bench logcat 三例 TTFT short 4661ms / long 23251ms / repeat 4971ms（Ace 6，Qwen3.5-2B llama_cpp 栈）
