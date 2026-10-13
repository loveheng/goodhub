---
confirm: pending
format: v1
---

（当前无待决项。M4 T3 立项轮 D9~D11 于 2026-10-11 确认（D9=聊天页接管首页 / D10=历史落盘可恢复——T3 内存态 + 持久化拆 T3b / D11=同页多轮上下文共享默认拍板），已回填 docs/product/chat-interaction.md 与 docs/design/m4.md。历史批次：M4 D8 T2 注入策略前置轮（三层归属）；D4~D7 方案评审轮（lib/sandbox/ / 同锚点 / 保底留最新 / JSONL）；D1~D3 立项轮（五项全做 / 记忆沙盒先行 / §16 维持推迟）。C1-C7、D1-D5、M2.5 D1/D2 均于 2026-10-11 确认（ADR-007）。台账保留复用。）
- [ ] [2026-10-12] W1 本周主线是否按 D14 先做 T6 剩余（接线→JIT→服务管理UI→CoW→验证），T5 排周尾？（不定则周计划无法定稿）
- [ ] [2026-10-12] W2 T4 连接韧性是否本周并行开（与 T6 穿插），还是 T6 收官后再启？（不定则并行线不排）

## thirdconnect（同机 MCP 传输选型）
- [x] [2026-10-12] TC1 同机传输主战场是否就是「同机 Android App 互通」（GoodHub↔好共享/第三方插件 App）？还是也含远端部署/标准 HTTP MCP server？（不定则 Binder 是否现在建无法定）→ 已确认：先做安卓底层方案，现有 HTTP 保持不变；长期各平台底层方案 + HTTP 优化
- [x] [2026-10-12] TC2 同机传输选型：Binder(AIDL) 为主 / UDS(LocalSocket) 为主 / 两者都做？→ 已确认：选 Binder(AIDL) 为主，UDS 留作后续降级兜底
- [x] [2026-10-12] TC3 是否接受「HTTP 保留为通用默认传输 + Binder/UDS 作同机快路径」的分层定位（而非替换通用宿主契约）？→ 已确认：接受分层，HTTP 保留为通用默认、不替换
- [x] [2026-10-12] TC4 第三方生态开放度：signature 私有生态（零弹窗）/ 开放第三方信任卡片 / 两者兼容？→ 已确认：两者兼容（signature 私有默认 + 开发者模式开放第三方信任卡片）
（thirdconnect TC1~TC4 已全确认，决策已落 context/epics/thirdconnect/memory.md，2026-10-12）

## thirdconnect（网关角色，新增）
- [x] [2026-10-12] TC5 GoodHub 是否新增「MCP 网关 Server」角色（对 PC 暴露聚合 HTTP/SSE :8766，内部经 Binder 调度本地 App）？→ 已确认：是（GoodHub 升为 Host+Gateway 双角色，复用 json_rpc/tool_router，新增 inbound 传输）
- [x] [2026-10-12] TC6 本地 App 是否一律 Binder-only 插件（不再各自暴露 HTTP MCP 服务，仅 GoodHub 对外暴露）？→ 已确认：A（一律 Binder-only；release 绝对零端口监听，开发期走 ADB 转发/单测，不留运行时网络旁路）
- [x] [2026-10-12] TC7 网关对外路径用 `/mcp`（Streamable HTTP，对齐 thirdconnect.md 契约 2025-06-18）还是 `/sse`（legacy SSE）？→ 已确认：A（统一 `/mcp` Streamable HTTP，协议 2025-06-18，入站出站同契约）
- [x] [2026-10-12] TC8 网关聚合范围：仅聚合本地 Binder 服务 / 还是也代理 GoodHub 已配置的远端 HTTP MCP server？→ 已确认：A（本地 Binder + 远端 HTTP 全量聚合，PC 绝对单入口）
（thirdconnect TC5~TC8 网关专项已全确认，决策已落 context/epics/thirdconnect/memory.md，2026-10-12）
