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

## misc（存量债专项收口 · 2026-10-19 新增）

- [x] [2026-10-19] **QC5 是否授权 misc 窗口代归并剩余 epic 的 devlog**→ **已裁决 a 并已执行（2026-10-19 用户勾选）：5 个 epic 共 83 条 devlog 全部归并（thirdconnect 20 / system-assessment 20 / chatmessage 18 / page-revamp 14 / m4 11），MERGE 与 SSOT 告警全部清零；全仓 0 违规 4 告警（MOUNT 3 提示级 + GROOM 1）**（QC3-a 上下文已变：全部 error 已清、仅剩归并类告警；且当前无并行窗口——CURRENT=misc、其余 epic 无活动写入，QC3-a 立法前提「多窗口活跃防脑裂」不成立）：a) **授权代归并（agent 默认）**——逐 epic 执行「提炼 memory + 清空 devlog 追加区 + 头部同步 + SSOT 归纳」，一次清掉 MERGE 6（chatmessage 18 / m4 11 / page-revamp 14 / system-assessment 20 / thirdconnect 20；lessons 已清）+ SSOT 1（page-revamp）；每步可 git 回滚 b) 维持 QC3-a 严守，剩余归各 epic 下次 ::bind 触发（已登记触发待办）c) 折中：只归并条数最多的 system-assessment 20 / thirdconnect 20，其余严守
- [x] [2026-10-19] **QC6 GROOM 洗盘口径**→ **已裁决 a 并已执行（2026-10-19 用户勾选）：4 条「真机冒烟/设备端 UI 冒烟待用户」（P0-B / T5 拦截卡三态 / archive-memory-claim / reverseDemo）合并为 1 条「真机验收总账（待用户执行）」并 rm 原 4 条，GROOM 45→42；核查无 [long]/[once] 过期项可重评（全部为 10 月内登记）；8 条触发型待办按 QC6-a 保留（各 epic 合法路由，非积压）**（原待办总量 45 > 30）：a) **合并同类 + 逐条重评过期项（agent 默认）**——4 条「真机冒烟/设备端 UI 冒烟待用户」并为 1 条；[long] 超 90 天未重评的逐条裁定（保留/转动作/关闭）b) 暂不洗盘，维持 45（lint 持续告警）c) 只合并不关闭
- [x] [2026-10-19] **QC7 MOUNT 3 条无挂载行**→ **已裁决 a 维持提示级（2026-10-19 用户勾选）：不为达标造挂载文档（属反向造假）；3 条提示级告警按 lint 自述「存量缺挂载不强制补」长期接受；ai-app-split 的跨仓 SSOT 事实已在 memory 正文声明**（instant-sampling / task-consume-loop / ai-app-split）：三者均无本仓 design 文档可挂（ai-app-split 契约 SSOT 在 goodshare 仓、跨仓只读），而 lint 口径要求挂载路径在本仓存在。a) **维持提示级不动（agent 默认）**——lint 自述「存量缺挂载不强制补」，为达标而造挂载文档属反向造假 b) 为三者补建 docs/design 底子文档再挂载 c) 改 lint 口径允许「无独立设计稿」显式声明式挂载（ai-app-split 已在 memory 正文如此声明）

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
- [x] [2026-10-15] SA-Q6 `lib/mcp/tool_router.dart`（**F1.9 海关过滤的唯一实现**，仅测试引用）最终处置：a) **保留待接线**（agent 默认：文件头已标注未接线原因与三项启用前置条件——删它等于删 P0 需求实现）b) 归档到 `archive/`（与 turn_wall 同口径，代价=丢失实现）c) 立即接线（**不可行**：现网服务端普遍不下发 annotations，启用即把所有工具过滤掉、生产功能归零）。**不定则该文件状态悬置**；推荐 a + 生态打标后按文件头条件接线 → **已拍板（2026-10-15，用户采纳 agent 默认 a）**：保留待接线，待 SDK 发 annotations（thirdconnect 验收后续项①）后按文件头三项前置条件接线；合并进 `coordinator/tool_router.dart` 记为 #9 补强 → **已接线（2026-10-21，插件 SDK 0.2.0）**：标记口径由 `annotations["x-mcp-export-to-shared"]` 更正为 **`_meta.goodhub.visibility`**（缺失即 private）；过滤**只落地在对外暴露面**（`mcp_gateway_handler.toolsList` 只回 shared），**本机链路不过滤**（private 照常发现与调用——未打标服务端工具面归零风险仍在，故不启用）。`lib/mcp/tool_router.dart` 口径同步更正、仍按 a 保留（收编 #9 未做）
- [x] [2026-10-15] SA-Q5 环路防护双保险 → **已确认采纳（用户裁决）并落地**：主防线 = 入站 Trace-ID 在途集合（`hop_count>0` 闸门 + 引用计数），兜底 = `hop_count` 上限 2 熔断；另按工程补丁追加 `try/finally` 必释 + TTL 300s 惰性驱逐 + `_meta` 与 name/arguments 平级注入。落点 `lib/gateway/gateway_loop_guard.dart` + 单测 9 例 (src: 用户裁决 + agent 取证修正)

## resource-center（资源中心一期 · 2026-10-18 新增，设计稿 §6）

- [x] [2026-10-18] **RC1 单文件大小上限**：a) 10MB（agent 默认：文本场景宽裕，读工具整读可兜）b) 5MB（偏保守，端侧窗口压力更小）c) 20MB（更长日志/数据集）→ **已确认 a（2026-10-18 用户勾选）**
- [x] [2026-10-18] **RC2 资源中心管理页入口落位**：a) 侧边栏「设置」区直达（对齐任务对账页先例，agent 默认）b) 独立一级入口（资源是高频资产）→ **已确认 a（2026-10-18 用户勾选）**
- [x] [2026-10-18] **RC3 read_local_resource 是否一期就做分段读**：a) M1 整读 + 大小上限兜底，分段读登记二期候选（agent 默认）b) M1 即做 offset/limit 分段（大文件逐步喂端侧模型）→ **已确认 a（2026-10-18 用户勾选）**
- [x] [2026-10-18] **RC4 读窗口防爆（RC3 经外评审后修订）**：a) 64KB 单次返回窗口，超限截断 + TrackNote 明示（agent 默认：整读挡不住 10MB ≈ 250 万 token 击穿模型窗口）b) 超阈值直接拒读提示拆分 → **已确认 a（2026-10-18 用户勾选）**；落点 = T3 工具执行器（kernel readContent 保持全文读取，窗口截断属工具面）
- [x] [2026-10-18] **RC5 存储配额**：a) 管理页仅展示已占用空间，不设上限（agent 默认）b) 展示 + 200MB 软上限 c) 暂不处理 → **已确认 a（2026-10-18 用户勾选）**
- [x] [2026-10-18] **RC6 内容查看定位（外评审四轮提出；注意：评审称「前序已拍板永久不做内建查看」失实——本项系新拍板非补登）**：a) 纯外部唤起——不做内建预览器，管理页「打开」一律复制 `cacheDir/external` 唤起系统默认应用（agent 默认，纯客户端定位最薄）b) 内建轻量预览（前几 KB 只读）c) 一期不做任何查看入口 → **已确认 a（2026-10-18 用户勾选）**

## mcp-tools-catalog（资源中心 Tab · 服务工具目录，2026-10-21 新增）

> 需求：资源中心新增 Tab，按服务分组展示已连接 MCP 服务的工具（含 shared/private 可见性，公共在前、私有在后）。
> **判定（2026-10-21 校准，推翻首版 S2）**：分两档——
> - 档1 仅「已注册服务清单」：数据源 = 本地 Binder 插件 `localPluginDiscovery.scan` + 远端 HTTP 端点 `ServerEndpointStore`，**静态注册态、不依赖连接**，UI 段同 `local_plugins_section` 注入位范式即可 → **S1 局部修补**（~150 行、无冷启动）；注意此时**不含工具明细与可见性**（二者在 `tools/list` 下发，不在注册表）。
> - 档2 含「工具 + 可见性」：进 Tab 时 per-service `listTools`（复用 `mountEndpoint` 注入，本地插件首次有 bind 唤醒延迟）= **注入式按需段（S1/S3）**，**非必须常驻全局状态**——首版误判 S2 过严（静止态无 *常驻* faces ≠ 必须造全局状态，按需拉取 + 进程内缓存即不命中 #1/#3/#4）。
> - **融合方案（agent 默认推荐）**：主列表 = 档1 已注册服务（S1 现成）；服务**展开/点开**时按需拉工具 + 可见性 pill（轻量拉取层）。两句话各对一档，最贴合需求原意。
> 仅当用户要求「跨会话常驻、进页零重连」才升级 S2（结构性引入常驻目录服务）。

- [ ] [2026-10-21] **MC1 落点（IA 归位）**：a) 按用户要求放资源中心第二 Tab（融合方案）b) 独立页「工具目录」（侧边栏工具带入口）c) 设置页新段（与本地插件段/节点段同域，`ui/sections→mcp` 白名单已开，成本最低）
- [ ] [2026-10-21] **MC2 排序口径（「公共在前、私有在后」落点）**：a) **两层都排**——服务组按「含 shared 工具数」降序、组内工具 shared 优先（agent 默认，仅档2/展开态生效）b) 只排工具（服务顺序按来源：本地 Binder 插件 → 远端 HTTP 端点，或按名升序）c) 只排服务（按 `privateServerIds` 会话私有域——静止页不持会话态，需另定来源）
- [ ] [2026-10-21] **MC3 可见性呈现态数（档2/展开态）**：a) **三态 pill**——共享 / 私有 / 未声明（agent 默认：`parseToolVisibility` 对缺失/形状异常/未知取值一律兜底 private，SDK <0.2.0 存量插件会**全量显示私有**，二态会让用户误判插件坏了；需 DTO 保留「是否显式声明」）b) 二态（shared/private），与 `ToolVisibility` 枚举严格对齐
- [ ] [2026-10-21] **MC4 服务分组维度**：a) 按来源分两组（本地 Binder 插件 / 远端 HTTP 端点），组内再排（agent 默认）b) 扁平按名排（不分组）c) 按「含 shared 工具数」分组

## misc（全局存量债分批清理 · 2026-10-19 新增）

- [x] [2026-10-19] **QC1 先校准度量还是直接开工清理**（前提项）→ **已裁决 a 并已执行（2026-10-19 用户勾选）：修 context-lint 挂载行解析，MOUNT 假阳性 4 归 0、全仓告警 24→20；mcp-orchestration 多锚点属 dev-loop §3 规则放宽，不擅动、已转待办**：取证发现 MOUNT 4 条「挂载失效」全为假阳性——`docs/design/m2-5-skill-refstore.md` / `m3-ui-subs-sampling.md` / `m4.md` 三份均在位且路径正确，假阳性根因 = `context-lint.sh:160` 把挂载行**整行**（含「（内容 SSOT：…）」中文说明；system-assessment 那行更是纯叙述句）当路径做 `-f` 判定。a) **先修 context-lint 解析（路径在全角「（」或空白处截断；无独立设计稿的挂载行须显式声明），再谈分批清理**（agent 默认：未经校准的台账不能当分批依据，否则会制造 4 处无意义修复并在触碰时引入真漂移）b) 改各 epic 挂载行瘦身成裸路径、说明移别处（工具不动，代价=丢铭牌信息且须改 4+ 文件）
- [x] [2026-10-19] **QC2 走结构性修复通道还是本轮手工吃一遍**→ **已裁决 a 并已执行（2026-10-19 用户勾选）：新工具 ctx-fix 入全局池（默认干跑/--apply/备份/幂等/金丝雀），全量执行 reclaim 30 + hdr 10 + checkpoint 6，另修 devlog bp 章节缺失 bug；三类告警归零，全仓 29 违规 24 告警 → 7 违规 16 告警**：工具池现状 = 只有检测器（ctx-audit / context-lint 均无 --fix；mount-init 只能新建骨架、不能重建既有骨架；仅 breakpoint fix 与 todos done|rm 两个零碎通道）。a) **新增 `ctx-fix` 机械件**（确定性重写 HDR / CHECKPOINT / RECLAIM / TODOS-头部 四类，约 20 项一次清空；复发类边际成本趋零）b) 本轮手工 Edit 逐项清这一批（S3 临时补丁路径，须留 PATCH 标记 + (风险)[long] 待办，且下一批照样会长）。注意：工具落 `~/.agents/toolbox` 属用户侧全局资产，写入须显式授权
- [x] [2026-10-19] **QC3 清理边界**：是否严守 dev-loop §3「严禁跨窗口代归并（防脑裂）」→ **已裁决 a 严守（2026-10-19 用户勾选）：misc 自身 27 条 devlog + 5 条 SSOT 已归并入 memory.md（total-merged 2→3，断点保留）；chatmessage / m4 / page-revamp / system-assessment / thirdconnect / ai-app-split / mcp-orchestration 七域语义债已登记为触发型待办，绑定各自下次 ::bind / 恢复窗口；lessons 13 条归并 + GROOM 洗盘归 misc 窗口**——MERGE / SSOT / VERIFY / SKELETON 属语义类，须在 chatmessage / m4 / misc / page-revamp / system-assessment / thirdconnect 各自窗口处理，misc 窗口只做机械类。a) **严守（agent 默认）** b) 本次开口授权 misc 代归并（效率换脑裂风险）
- [x] [2026-10-19] **QC4 台账去重**→ **已裁决 a 并已执行（2026-10-19 用户勾选）：3 条旧快照（10-16 ×2 / 10-17）移入 done.md，保留的 10-19 条改写为「全局存量债专项总账」（实数演进 + 剩余分布 + 七域触发待办路由 + 状态 SSOT 指针）**：`context/todos.md` 现存 4 条同类「ctx-audit 存量债」登记（10-16 ×2 / 10-17 / 10-19），每次 ::done 审计净增一条、从未清算，本身即 GROOM 告警的主因。a) **合并为 1 条、其余去重移 done.md（agent 默认）** b) 维持现状仅追加
