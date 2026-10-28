---
status: active
updated: 2026-10-23
---

> **名词映射（2026-10-16）**：本文件中的「服务大厅」= 现**设置页**（`lib/ui/settings_page.dart`）——聊天页 ⚙ 设置弹层已并入服务大厅并统一改名「设置」。历史决策/施工原文**保留不替换**，代码与现行文档以新名为准（合并记录见 [page-revamp.md](page-revamp.md)）。

# GoodHub 需求清单（Host + Gateway 双角色）

> 2026-10-10 定稿（与 architecture.md 同步七轮评审收敛）。需求编号供拆任务引用；P0 集合已确认（§5）。
> **2026-10-15 对账回填**：Server 角色已于 2026-10-12 解冻（TC5~TC8），F1 Server 侧项由「挂起」改为按实际实现状态标注（已落地 / 部分落地 / 未落地 + 延后理由）；未落地项均写明触发条件，避免下次对账复现「文档说有、代码没接」。

## 1. 用户故事（核心场景）

- **U1 对话即调度**：用户在聊天框下达自然语言任务，Agent 自主编排已挂载 App 的工具完成，全程状态可见、可中止。
- **U2 跨 App 流转**：「把 goodshare 这篇笔记的行动项写进 todo」——跨服务管道一次完成。
- **U3 断网可用**：无网时端侧模型接管基础意图理解与单轮任务，本地回环 App 调度不受影响。
- **U4 记忆随身**：Agent 记住我的偏好（memory.md），错了会吸取教训（lessons.md），我随时可查看/编辑/粉碎。
- **U5 技能成长**：复杂操作可沉淀为 Skill，下次自动复用；官方 Skill 更新我可选择性合并，不冲掉我的修改。

## 2. 功能需求（按六层架构编号，F<层>.<序>）

### F1 MCP 双工总线

> ~~**2026-10-10 裁决（用户）**：Server 角色相关需求（F1.5/F1.6/F1.8/F1.11/F1.12/F1.16/F1.17/F1.19 中 Server 侧项）**暂缓挂起**——无真实接入场景、依赖与结构边界不清晰；未来反向交互走「桌面平台先记录待完成 → 宿主批量处理」（FC6）。~~ **该裁决已于 2026-10-12 翻转（TC5~TC8），仅作历史留痕。**
>
> **2026-10-12 解冻（现行口径）**：Server/Gateway 角色已立项并落地（`:8766/mcp` 聚合网关，服务对象 = 桌面 AI 平台 MCP 客户端）。下表 Server 侧项按**实际实现状态**重标为「已落地 / 部分落地 / 未落地」，未落地项均标注延后理由（2026-10-15 对账轮回填，逐条取证见 `context/epics/system-assessment/memory.md`）。

| 编号 | 需求 | 优先级 |
|---|---|---|
| F1.1 | 多 MCP Server 挂载（Streamable HTTP，JSON-RPC 2.0），局域网/回环 | P0 |
| F1.2 | ToolRouter 命名空间前缀隔离（`goodshare__tool`） | P0 |
| F1.3 | JIT 两级工具发现 + 静态首级摘要（每 Server 一行常驻系统提示词，Turn 1 直达激活）：元工具常驻 + `activate_server_tools` 按需注入 | P0 |
| F1.4 | 心跳探活、在线/离线状态展示、断线重连 | P1 |
| F1.5 | MCP Server 角色：`:8766/mcp` 监听 + 聚合工具面（特权工具按 L1/L2 裁决逐步开放） | P1（**已落地** 2026-10-13，G1~G5；见 architecture.md 分期表 M1.5 行；**2026-10-23 增补**：宿主能力经 `host` 虚拟服务按 Allowlist 渐进开放，见 F1.20） |
| F1.6 | 进程内零拷贝直调（handler 与 HTTP 路径共用） | P1（**未落地**：网关经 `face.client` 复用同一 McpClient 链路，未做进程内直调短路；延后至本地插件高频调用出现实测瓶颈） |
| F1.7 | 聚合网关 `$ref` 暂存池（形态 A） | P2 |
| F1.8 | Integration Hub 接线看板 + 跨 App 审计标记 | P2（**未落地**：ops.log 已有 `server=gateway` 入站审计，看板 UI 未做；延后至多插件接入） |
| F1.9 | 声明式能力导出：海关过滤只收 `_meta.goodhub.visibility == "shared"` 工具（**缺失即 private**，default-deny；与标准 `readOnlyHint` / `destructiveHint` hints 正交）；对外 Server 目录 = 过滤后清单；标记纯声明、非访问控制（SDK 不剔条目、不拦调用）；共享池随 tools/list 变更全量刷新（见 architecture.md §8） | P0（**2026-10-21 已接线（对外暴露面）**：网关 PC 投影 `mcp_gateway_handler.toolsList` 只回 shared；**本机链路（宿主聊天装配面 `coordinator/tool_router.dart`）不过滤**——private 照常发现与调用，过滤会让未打标服务端（如 goodshare）工具面归零。旧 `annotations` 私有字面量口径 **已作废** <!-- drift:keep：旧口径特指禁令叙述 -->。规则独立实现仍在 `lib/mcp/tool_router.dart`（SA-Q6 保留待收编，见架构债 #9） |
| F1.10 | 环路防护：全链路 Trace-ID + hop_count（请求头，硬限 ≤2）+ 总线层环检测 | P0（**已落地** 2026-10-15，SA-Q5 双保险：`lib/gateway/gateway_loop_guard.dart`——入站 Trace-ID 在途集合（引用计数）+ `hop_count` 上限 2 熔断 + TTL 300s 惰性驱逐，阻断回 JSON-RPC `-32000`；「总线层环检测」= SessionManager 仲裁部分经 SA-Q1 裁决**显式关闭**，触发条件见 architecture.md §15） |
| F1.11 | 移动端保活：Server 活跃期前台服务；Client 心跳双向覆盖；唤醒 Intent 约定随接缝契约回写 | P1（**部分落地**：网关前台服务 + WifiLock/WakeLock 已落（G4）；Client 心跳双向覆盖与唤醒 Intent 未落——归 F1.4 / M4-T4，2026-10-15 裁定暂缓至文档收口后） |
| F1.12 | 传输层生命周期：`:8766` 固定端口（被占报错拒绝启动，禁止静默漂移）；ContentProvider 跨 App 端口发现（契约扩展）；网络切换重连（积压队列丢弃回告，不重放）；密钥 Keystore 加密存储 | P0（**部分落地**：`:8766` 固定端口已落；密钥安全存储已落（`SecureKeyValue`）；**ContentProvider 跨 App 端口发现未落**（改由网关面板展示 Wi-Fi IP 供 PC 配置）；**网络切换重连未落**——归 M4-T4，2026-10-15 裁定暂缓至文档收口后） |
| F1.13 | Abort 级联：`notifications/cancelled` 下发 + 卡片 `Cancelled` 终态 + 写操作半程明示；L2 拦截即结算当前流（`finish_reason: tool_calls`），确认后新 Turn 续推——用户交互不占用连接生命周期 | P0 |
| F1.14 | MCP Resources + Subscriptions：只读数据走 Resource URI（`resources/list`、`read`）上下文注入；`resources/subscribe` 感知服务端数据变更（**依赖 goodshare 契约扩展**） | P1 |
| F1.15 | `$/progress` 进度通告：progressToken 下发 + 卡片 `Running(progress/total)` 态 + 无更新超阈值提示疑似卡死 | P1 |
| F1.16 | Sampling 反向推理：`sampling/createMessage` + Server 级配额上限（M2+，依赖端侧引擎稳定） | P2（**部分落地**：Client 侧 sampling 反向闭环已落（M3-T1）并接入网关反向在途表；**Server 级配额上限未落**——延后至外部客户端高频调用场景出现） |
| F1.17 | 同机接入准入：回环与局域网**均强制** Bearer Token；Binder UID + 签名 SHA-256 白名单 → TTL Session Token，未授权 403（五轮评审，P0） | P0（**部分落地**：Bearer Token 强制校验已落（G3，未授权 401）；Binder UID + 签名 SHA-256 白名单已落（§1.2.6 信任卡片 + 同签名零弹窗）；**TTL Session Token 未落**——现为长期配对 Token，延后至多 PC 共用 / 需要会话级吊销的场景。**2026-10-23 增补**：默认**自动生成**配对 Token（起服必带 Bearer）；「免鉴权」降级为**显式**逃生口（关闭自动生成 + 留空，仅建议 ADB 转发），意图落盘防下次开启被静默补 Token 推翻——安全默认由「留空 = 不鉴权」改为「留空 = 自动生成」） |
| F1.18 | 能力协商与降级垫片：initialize capabilities 协商；Tier 2（Vanilla MCP）自动 Polyfill——无 resources/progress/prompts/订阅各自默认降级，不抛异常 | P0 |
| F1.19 | SessionManager：会话粒度隔离（缓存区/激活工具表/滑动窗口/暂存池归属）；前台优先 + 后台有界队列（深度 4 可配）超限 429 | P0（后台队列仲裁挂起，随 Server 角色；会话隔离在 Client 侧生效） |
| F1.20 | 宿主能力经网关导出（`host` 虚拟服务 / `host__` 命名空间）+ **策略投影**（单轴 `policy`：`single` / `private` / `full` / `pruned`，旧 `strategy=`/`scope=` 作兼容别名）+ 连接级控制面（列举已挂载服务 / 切换投影）：显式 Allowlist 登记（未登记者不导出）、`host` 保留字门禁、标注 `readOnlyHint`/`destructiveHint` 强制声明 | P1（**2026-10-23 已落地（待真机验收）**：设计 SSOT `docs/design/host-tools-gateway-export.md`；首项登记 `get_host_status`（零隐私只读），记忆读写等隐私能力**默认不登记**——是否向外部 AI 暴露宿主长期记忆属产品定位问题，须单独立项） |

### F2 混合推理编排

| 编号 | 需求 | 优先级 |
|---|---|---|
| F2.1 | 云端 BYOK 多厂商聚合（OpenAI/Anthropic/DeepSeek/Qwen，自定义 BaseURL/Key） | P0 |
| F2.2 | SSE 流式解析：正文 Token 与 tool_calls 分离 | P0 |
| F2.3 | 端侧 LiteRT-LM 引擎（1.5B~3B 量化，模型包按需下载） | P1 |
| F2.4 | 云→端自适应降级：断网即切（模型就绪）/连接 >5s/首 Token >30s/连续 2 次 5xx/429（初值，M2 调参可配；首 Token 2026-10-21 由 8s 调至 30s——无 SSE 心跳的推理型提供商思考期 8s 误杀率高）；端侧仅跑单任务提取/分类 + 约束解码（LiteRT grammar 支持待实证） | P1 |
| F2.5 | 两步失败熔断 + 排查卡片（重试/跳过/人工接管）+ 步数墙 max_turns=10（管空转，与熔断互补）；用户拒绝不计熔断 | P0 |
| F2.6 | L1/L2 权限网关（只读静默 / 写操作确认卡片）；L2 拒绝支持附理由（Rejected(reason) 回传模型原地修正，拒绝≠中止） | P0 |
| F2.7 | Agent Loop 上下文治理：滑动窗口（最近 6 轮原始对可配）+ >1000T 工具结果端侧摘要化 + 原文退化引用 | P1 |
| F2.8 | 设备分级与环境门禁：端侧加载硬门槛（RAM ≥6GB 且可用 ≥2.5GB 初值，M2 调参）+ 推速探测（无 NPU 时首 Token >15s 判不可用）+ 电量 <15%/省电模式抑制 + 温控冷却退出 | P1 |

### F3 Skill 系统

| 编号 | 需求 | 优先级 |
|---|---|---|
| F3.1 | 三级加载：Global（<300 Tokens）/ App-Scoped / On-Demand | P1 |
| F3.2 | goodshare 模板继承（prompts/list、get）+ 本地 CoW 覆写 + 重置 + `min_hub_version` 兼容声明与大版本跃迁告警（**依赖接缝扩展**） | P2 |
| F3.3 | Skill Hub UI（启停/编辑/Token 测算） | P2 |
| F3.4 | `create_skill` 自生成沉淀（⚠️ 三轮评审：M1~M2.5 剥离，M3+ 带内容审计门禁复评；此前仅官方预置 + CoW 同步 + 手动编辑） | P3 |

### F4 记忆沙盒

| 编号 | 需求 | 优先级 |
|---|---|---|
| F4.1 | 纯文本三件套（memory.md / lessons.md / ops.log）持久化 | P0 |
| F4.2 | Token 预算截断 + 归纳压缩 | P1 |
| F4.3 | 记忆看板（查看/编辑/导出/粉碎） | P1 |
| F4.4 | 记忆类工具暴露时强制 L2（局域网模式） | P0 |
| F4.5 | 暂存池治理：内存 Map + >1MB 落 cacheDir 临时文件（无 SQLite）；Session 即焚 + TTL 30min；注水拦截点=ToolRouter 分发前，跨源过联合确认（卡片展示数据摘要）；启动幂等清池（architecture.md §9） | P1 |
| F4.6 | ops.log 轮转：10MB 上限 + ops.log.1 单代滚动 + 启动清理 | P1 |
| F4.7 | 单进程硬约束：全组件禁 `:remote` 进程；跨 App 沙盒不共享，流转只走 MCP | P0 |

### F5 UI/UX

| 编号 | 需求 | 优先级 |
|---|---|---|
| F5.1 | 双轨消息流：流式 Markdown 阅读轨 + 原生卡片操作轨 | P0 |
| F5.2 | 任务状态展示（Android 悬浮胶囊；iOS 形态延后定）+ 一键中止 | P1 |
| F5.3 | 设置页（App 管理 + 模型配置面板；2026-10-16 由「服务大厅」改名） | P1 |

## 3. 非功能需求

| 编号 | 需求 |
|---|---|
| N1 | 双端可移植纪律：平台能力全走 Dart 抽象接口 + 平台适配器，业务层零平台 import |
| N2 | 常驻上下文开销恒定：挂载 App 数量增长不放大首轮 Token（JIT 保证） |
| N3 | 隐私：记忆/剪贴板数据不出本机（局域网监听须鉴权 + L2） |
| N4 | 稳定性：工具调用全链路审计（ops.log），熔断不死循环 |
| N5 | 安装包体积：端侧模型不入 APK，按需下载 |
| N6 | 端侧引擎预热：前台活跃期预加载驻留，后台释放；冷启动真空期 UI 反馈「离线引擎唤醒中」 |
| N7 | 隐私围栏：特权数据（剪贴板/记忆）进云端 Prompt 前强制 PII 遮蔽（正则+可选端侧模型），返回反向映射；遮蔽失败拦截请确认，严禁静默放行 |
| N8 | 同机零信任：回环端口默认强制鉴权（Android 沙盒不隔离 127.0.0.1）；特权工具三重防线（UID 白名单 → L1/L2 网关 → N7 围栏） |
| N9 | 设备分级：端侧功能按硬件门槛启用/禁用，低端机宁报错不硬扛；温控/电量门禁抑制高负荷推理 |

## 4. 平台策略（拍板建议，待确认）

- **Android 首发，iOS 延后接入（M2.5~M3）**——本机 Linux 无 macOS/Xcode，同步双端不可行（见 architecture.md §双端策略）。
- iOS 接入前置条件：macOS 构建环境 + Apple 开发者账号 + MLX/Core ML 端侧引擎适配。
- 从 M1 起守 N1 双端纪律，避免后期返工。

## 5. 需求侧待拍板项

- [x] 平台策略：Android 首发 + 双端纪律 N1（2026-10-10 评审收敛，Linux 无 macOS 为硬约束）
- [x] JIT 激活动作按 L1（静默 + 药丸）；已激活 Schema 预算默认 1200 Tokens 可配，超限精简模式
- [x] 端侧降级判据定量初值（见 F2.4）
- [x] P0 集合确认（2026-10-15 对账更新：Server 侧已随 TC5~TC8 解冻，F1.12/F1.17 部分落地，F1.5/F1.10 已落地）：F1.1~F1.3 + F1.9/F1.10/F1.13/F1.18/F1.19（Client 侧）+ F1.5/F1.12/F1.17（Server 侧）+ F2.1/F2.2 + F2.5/F2.6 + F4.1/F4.4/F4.7 + F5.1
