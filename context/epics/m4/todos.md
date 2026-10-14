---
memo: todos
format: v2
---

# m4 待办（T5+T6 真机联调第三批 · 定序 2026-10-14）

> 定序逻辑：先去风险地基（零外部依赖）→ 再产品主链（需 BYOK key）→ 再观测面（需 HTTP 端点）→ 最后多服务/挂起。§5 门禁已过（D.1 指纹 SAME + D.2 bind 全链通），#9 可关、#10 解锁。

- [x] (联调) [P1] T6-4 单服务经 ToolRouter 全链不回归 + get_connected_apps/activate_server_tools 可见——goodshare 已同签名在位，零外部依赖；集成测试坐证 ToolRouter 前缀路由 + JIT 元工具 + 聊天页手动冒烟 (src: agent, 建议序 #1) ✓ 2026-10-14 真机通过（integration_test/goodshare_toolrouter_e2e_test.dart 6 断言全绿）；聊天页手动冒烟仍待用户旁路取证
- [x] (联调) [P1] BYOK 云端全通（T5 收官头条）：真机配云端 profile → 云端推理 → 工具调用，替代 M2 预置 profile 路径——需用户 BYOK 云 key (src: agent, 建议序 #2) ✓ 2026-10-14 goodhub OpenAiChatClient 直连 StepFun 双探针全过（chat stop + tool_calls toolCalls）；profile 入 app + 聊天页云端→工具调用全链冒烟待用户
- [x] (联调) [P2] 节点卡真机探活/挂载开关（T5-Server）：服务大厅节点卡对 HTTP 端点计时握手 + 工具计数 + 鉴权态 + 开关落盘——需一个 HTTP ServerEndpoint（goodshare:8765 或 dummy） (src: agent, 建议序 #3) ✓ 2026-10-14 数据面真端验证（ServerProber 直连 goodshare HTTP：带 key 38 工具 400ms 在线 / 无 key 401 待授权 Rose）；UI 渲染+挂载开关已单测，设备端 UI 冒烟待用户
- [x] (联调) [P3] CoW 多 server 撞名跳过/通告：逐 server 同步 + cow/<name> 撞名跳过 + 通告——需第二真实服务（重名 prompt） (src: agent, 建议序 #4) ✓ 2026-10-14 仅用 goodshare 双 serverId 坐证（goodshare Tier1 prompts×3，server2 同名全跳过）；发现撞名为静默跳过无用户面通告（vs 设计「跳过+通告」），待拍板是否补
- [ ] (联调) [P4] reverseDemo 挂起项：反向 Server 角色暂缓（FC6），出现桌面平台真实需求再重启 (src: agent, 建议序 #5)
- [ ] (功能) [P3] 本地插件 per-plugin 挂载开关：对齐远端节点 M4-T5 `enabled` 口径——`LocalPluginInfo` 增开关位 → 聊天页 ⚙ 面板开关（同签名也可摘）→ 装配/网关两处闸门加 `enabled` 过滤 → 摘除后向 PC 下行 `tools/list_changed`（§6 机制复用）；规范预留条款见 docs/design/local-plugin-access-trust.md §1.7 (src: agent, 建议序 #6)
