---
memo: todos
format: v2
epic: m4
---

# m4 · 域内待办
- [ ] [2026-10-19] (优化) (重:重) 存量债归本窗口处理（触发=本 epic 下次 ::bind / 恢复窗口时）：devlog 11 条待归并提炼进 memory.md 并清空追加区；待办行旧版 (联调)/[Pn] 前缀缺 (功能|修复|优化|文档|环境|测试|风险) 类型标签，逐行补标签保语义 (src: ai, 存量债专项 QC3-a)

## m4 待办（T5+T6 真机联调第三批 · 定序 2026-10-14）

> 定序逻辑：先去风险地基（零外部依赖）→ 再产品主链（需 BYOK key）→ 再观测面（需 HTTP 端点）→ 最后多服务/挂起。§5 门禁已过（D.1 指纹 SAME + D.2 bind 全链通），#9 可关、#10 解锁。


- [ ] (功能) (暂缓) reverseDemo 挂起项：反向 Server 角色暂缓（FC6），出现桌面平台真实需求再重启 (src: ai, 建议序 #5)
- [ ] (功能) [P3] 本地插件 per-plugin 挂载开关：对齐远端节点 M4-T5 `enabled` 口径——`LocalPluginInfo` 增开关位 → 聊天页 ⚙ 面板开关（同签名也可摘）→ 装配/网关两处闸门加 `enabled` 过滤 → 摘除后向 PC 下行 `tools/list_changed`（§6 机制复用）；规范预留条款见 docs/design/local-plugin-access-trust.md §1.7 (src: agent, 建议序 #6)
