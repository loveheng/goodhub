---
memo: todos
format: v3
epic: host-tools-gateway-export
---

# host-tools-gateway-export · 域内待办
- [ ] [2026-10-23] (测试) (重:中) **真机端到端验收（仅剩项，代码侧已闭环）**：single&server=host 仅见无前缀 host 工具并实调；full 见带前缀联邦面；AtomCode full 模式发现 host__ 工具回归。通过后设计稿 status draft→active、epic 归档。其余单测项：单测（Allowlist 未登记不导出 + 非空断言 + 工具名禁 __、四级管道顺序、single 补齐幂等与他服务前缀拒绝、系统工具与投影集外调用拒绝、投影差分抑制、pruned 未打标剔除、会话绑定后 URL 变更不生效、目标未挂载 initialize 报错、空面 DEGRADE 留痕、按 serverId=host 记账）+ 真机（single&server=host 仅见无前缀 host 工具并实调；full 见带前缀联邦面；AtomCode full 模式发现 host__ 工具回归） (src: ai)
