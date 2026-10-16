---
confirm: pending
format: v1
---

（当前无待决项。M4 T3 立项轮 D9~D11 于 2026-10-11 确认（D9=聊天页接管首页 / D10=历史落盘可恢复——T3 内存态 + 持久化拆 T3b / D11=同页多轮上下文共享默认拍板），已回填 docs/product/chat-interaction.md 与 docs/design/m4.md。历史批次：M4 D8 T2 注入策略前置轮（三层归属）；D4~D7 方案评审轮（lib/sandbox/ / 同锚点 / 保底留最新 / JSONL）；D1~D3 立项轮（五项全做 / 记忆沙盒先行 / §16 维持推迟）。C1-C7、D1-D5、M2.5 D1/D2 均于 2026-10-11 确认（ADR-007）。台账保留复用。）
- [x] [2026-10-12] W1 本周主线是否按 D14 先做 T6 剩余（接线→JIT→服务管理UI→CoW→验证），T5 排周尾？→ **已由 SA-Q2 裁定（2026-10-15）：主线改文档/规范收口（B1+B2+B3 快赢），T6 剩余不占主线**
- [x] [2026-10-12] W2 T4 连接韧性是否本周并行开（与 T6 穿插），还是 T6 收官后再启？→ **已由 SA-Q2 裁定（2026-10-15）：T4 暂缓，文档收口完成后立即启动**（状态注记已落 `docs/design/m4.md` §5）

## self-update（打包推 R2 + 应用内自动更新，模仿 goodshare）
- [x] [2026-10-14] SU1 挂载：新建 epic `self-update` 还是挂 misc？→ 已确认：新建 epic self-update（2026-10-14 已 mount-init）
- [x] [2026-10-14] SU2 新依赖引入：crypto + package_info_plus + open_filex（goodshare 同款三件）？→ 已确认：同意
- [x] [2026-10-14] SU3 范围：仅整包自更新还是含 config 热更？→ 已确认：仅整包自更新（清单 versionCode/versionName/apkUrl/sha256/changelog；config 热更后续按需加）

## thirdconnect（同机 MCP 传输选型）
- [x] [2026-10-12] TC1 同机传输主战场是否就是「同机 Android App 互通」（GoodHub↔好共享/第三方插件 App）？还是也含远端部署/标准 HTTP MCP server？（不定则 Binder 是否现在建无法定）→ 已确认：先做安卓底层方案，现有 HTTP 保持不变；长期各平台底层方案 + HTTP 优化
- [x] [2026-10-12] TC2 同机传输选型：Binder(AIDL) 为主 / UDS(LocalSocket) 为主 / 两者都做？→ 已确认：选 Binder(AIDL) 为主，UDS 留作后续降级兜底
- [x] [2026-10-12] TC3 是否接受「HTTP 保留为通用默认传输 + Binder/UDS 作同机快路径」的分层定位（而非替换通用宿主契约）？→ 已确认：接受分层，HTTP 保留为通用默认、不替换
- [x] [2026-10-12] TC4 第三方生态开放度：signature 私有生态（零弹窗）/ 开放第三方信任卡片 / 两者兼容？→ 已确认：两者兼容（signature 私有默认 + 开发者模式开放第三方信任卡片）
（thirdconnect TC1~TC4 已全确认，决策已落 context/epics/thirdconnect/memory.md，2026-10-12）

## chatmessage（In-band 记忆提取）
- [x] [2026-10-15] CM1 workspace_states（G3）物理实现偏离 SSOT §9.5：SQLite DDL → 文件型 KV（每会话一 JSON + SequentialFileWriter 原子重写，upsert/remove 同语义，零新依赖；全仓无 sqlite 依赖、MemoryStore 同栈）→ **已按默认建议确认接受（2026-10-15）：SSOT §9.5 已回填实现修正附注；键序范围查询诉求出现时再评估迁 sqlite3（API 不变）**

## archive-memory-claim（SamplingQuota 落盘 · 2026-10-16 新增）

- [x] [2026-10-16] **AM1 SamplingQuota 持久化的防篡改口径**（设计稿 §3 步 1 预留「时间戳 + 防篡改口径另记 ADR」）：a) **HMAC-SHA256 签名**（密钥入 SecureKeyValue，agent 默认——篡改可检出，重装即重置可接受）b) 明文时间戳不防篡改（诚实记录，实现最薄）c) 本轮不做落盘（维持「重启清零」，(风险) 待办继续挂）→ **已确认 a（2026-10-16 用户勾选）**：已实现——`conversation_archive.dart` saveQuota/loadQuota + HMAC 定长比较，篡改/换密钥检出按重置；命中记录恢复、配额参数为应用级常量不随落盘

## thirdconnect（网关角色，新增）
- [x] [2026-10-12] TC5 GoodHub 是否新增「MCP 网关 Server」角色（对 PC 暴露聚合 HTTP/SSE :8766，内部经 Binder 调度本地 App）？→ 已确认：是（GoodHub 升为 Host+Gateway 双角色，复用 json_rpc/tool_router，新增 inbound 传输）
- [x] [2026-10-12] TC6 本地 App 是否一律 Binder-only 插件（不再各自暴露 HTTP MCP 服务，仅 GoodHub 对外暴露）？→ 已确认：A（一律 Binder-only；release 绝对零端口监听，开发期走 ADB 转发/单测，不留运行时网络旁路）
- [x] [2026-10-12] TC7 网关对外路径用 `/mcp`（Streamable HTTP，对齐 thirdconnect.md 契约 2025-06-18）还是 `/sse`（legacy SSE）？→ 已确认：A（统一 `/mcp` Streamable HTTP，协议 2025-06-18，入站出站同契约）
- [x] [2026-10-12] TC8 网关聚合范围：仅聚合本地 Binder 服务 / 还是也代理 GoodHub 已配置的远端 HTTP MCP server？→ 已确认：A（本地 Binder + 远端 HTTP 全量聚合，PC 绝对单入口）
（thirdconnect TC5~TC8 网关专项已全确认，决策已落 context/epics/thirdconnect/memory.md，2026-10-12）

## M4-T4（连接韧性，2026-10-15 重启 · 已裁决）

> T4-1 退避底座已落地（`lib/core/network/backoff.dart` + 单测 8 例，analyze 0 issue）。**2026-10-15 用户裁决：按推荐推进**；并采纳两项落地约束（见 D16/D17 注记）。**T4 全量落地（T4-1~T4-5，代码+接线+测试 529 绿，见 m4.md §5）**，待真机验收 + D20 goodshare 契约回写。

- [x] [2026-10-15] **D15 施工顺序与依赖切分**：已确认 a) **T4-2 心跳 + T4-3 重连 → T4-4 积压回告 → T4-5 订阅消费**（前三项纯客户端、不依赖 goodshare；订阅依赖对方真发 `notifications/resources/updated`）
- [x] [2026-10-15] **D16 心跳参数与离线判定**：已确认 a) **间隔 15s / 单次超时 5s / 连续 2 次失败判 offline（≈30s）**，探活 MCP 标准 `ping`。**追加约束（用户）**：15s ping **仅限远端 HTTP 连接**；本地 Binder 插件依赖 Android `DeathRecipient` 事件感知，**严禁对本地插件跑轮询心跳**（否则频繁唤醒休眠子 App 进程 → 电量刺客）。落点 `lib/mcp/connection_health.dart` 以 `pollable`（transport is HttpTransport）门控
- [x] [2026-10-15] **D17 重连后的会话语义**：已确认 a) 重连成功 = 重 negotiate + 重建 face + 重 listTools，**保留 JIT 激活集与 Skill 覆写**。**追加约束（用户）**：重连拉取的 listTools 须与原 JIT 激活集做**交集过滤（Diff Clean）**，被废弃/下线的已激活工具自动剔除并记日志（否则重启升级后 LLM 调用悬空工具）。属 T4-3 落点
- [x] [2026-10-15] **D18 断连时在途请求与回告形态**：已确认 a) 在途 tools/call 取消（终态 `Cancelled`）+ TrackNote 回告「连接中断，在途 N 个已取消，不重放」；属 T4-3/T4-4
- [x] [2026-10-15] **D19 订阅失效感知的呈现**：已确认 a) 不自动重读，仅 TrackNote 提示「数据已变更，如需最新请重新读取」；属 T4-5
- [x] [2026-10-15] **D20 goodshare 契约回写（跨仓只读约束）**：已确认 a) 本仓只登记待同步项，由用户执行；待 T4-3/T4-5 落地时补登记

## system-assessment（对账轮后续 · 阻塞项，2026-10-15 新增）

- [x] [2026-10-15] SA-Q1 A2 三项 P0 原语是否随网关解冻 → **已确认：b 只做 Trace-ID + hop_count（最小止血）**；SessionManager 会话隔离与有界队列 4/429 判定为早产，不在本轮做（需在 B2 显式关闭并写触发条件，否则下次对账复现）
- [x] [2026-10-15] SA-Q2 本周主线排序 → **已确认：先收口文档与规范（B1 + B2 + B3 低风险快赢），M4-T4 连接韧性暂缓至收口完成后**（W1/W2 同题一并裁定）
- [x] [2026-10-15] SA-Q3 端侧模型管理链处置 → **已确认：归档，现阶段绝不补接线**；落点 `archive/local_model/`（仓库内目录 + `analysis_options.yaml` exclude，非分支——分支会腐烂，目录可 git 追溯并写复活条件）。**归档粒度修正**：`lib/llm/llm_model.dart` 被生产 `lib/llm/llm.dart:5` 引用，必须保留；只挪 `llm_model_manager.dart` / `llm_download_isolate.dart` / `remote_config_store.dart` 三件
- [x] [2026-10-15] SA-Q4（非阻塞）TC13 双进程 `:gateway` → **已按「维持单进程 + 标注未落地」处置（B2，2026-10-15）**：architecture §11 与待拍板清单、`goodhub-index` 均已标注未落地与触发条件；日后真拆进程须同步修订 §11 单进程硬约束 (src: agent 默认采纳，可推翻)
- [x] [2026-10-15] SA-Q6 `lib/mcp/tool_router.dart`（**F1.9 海关过滤的唯一实现**，仅测试引用）最终处置：a) **保留待接线**（agent 默认：文件头已标注未接线原因与三项启用前置条件——删它等于删 P0 需求实现）b) 归档到 `archive/`（与 turn_wall 同口径，代价=丢失实现）c) 立即接线（**不可行**：现网服务端普遍不下发 annotations，启用即把所有工具过滤掉、生产功能归零）。**不定则该文件状态悬置**；推荐 a + 生态打标后按文件头条件接线 → **已拍板（2026-10-15，用户采纳 agent 默认 a）**：保留待接线，待 SDK 发 annotations（thirdconnect 验收后续项①）后按文件头三项前置条件接线；合并进 `coordinator/tool_router.dart` 记为 #9 补强
- [x] [2026-10-15] SA-Q5 环路防护双保险 → **已确认采纳（用户裁决）并落地**：主防线 = 入站 Trace-ID 在途集合（`hop_count>0` 闸门 + 引用计数），兜底 = `hop_count` 上限 2 熔断；另按工程补丁追加 `try/finally` 必释 + TTL 300s 惰性驱逐 + `_meta` 与 name/arguments 平级注入。落点 `lib/gateway/gateway_loop_guard.dart` + 单测 9 例 (src: 用户裁决 + agent 取证修正)
