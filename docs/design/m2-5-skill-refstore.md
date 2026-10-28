---
status: active
updated: 2026-10-11
---

> **名词映射（2026-10-16）**：本文件中的「服务大厅」= 现**设置页**（`lib/ui/settings_page.dart`）——聊天页 ⚙ 设置弹层已并入服务大厅并统一改名「设置」。历史决策/施工原文**保留不替换**，代码与现行文档以新名为准（合并记录见 [page-revamp.md](page-revamp.md)）。
# M2.5 施工设计：三级 Skill · $ref 暂存池 · MCP 原语补齐

> 里程碑范围锚点：[architecture.md §6 分期路线](../product/architecture.md)。本文件是 M2.5 的内容 SSOT（范围/施工分解/定稿即写即落），memory 只记状态与指针。前置决策 D1/D2 已拍板（2026-10-11，ADR-007），状态 `active`。

## 1. 范围（依 architecture 定稿，六项 + 一项接线）

1. **三级 Skill 系统**：Global（常驻 <300 Tokens）/ App-Scoped（绑 Server 动态注入）/ On-Demand（`activate_skill` 按需激活）。`create_skill` 本期剥离（M3+ 带内容审计门禁复评）；Skill 来源 = 官方预置 + goodshare CoW 同步 + 用户 UI 手动编辑。
2. **出厂继承 CoW + 版本告警**：MCP `prompts/list` / `prompts/get` 拉取 goodshare 模板 → 本地沙盒覆写最高优先级 + 一键重置；`min_hub_version` 兼容声明 + 基础模板大版本跃迁强制告警（提示差异 + 用户选择重置/保留）；否决三路合并引擎。
3. **$ref 暂存池（形态 A，Ref Store 规格 §9）**：内存 `Map<String, RefMetadata>` + >1MB Payload 落 `cacheDir/ref_xxx.tmp`；会话绑定 + 全局兜底 TTL 30min + 启动幂等清池；`$ref:<server>:<id>` 句柄携带来源 Server 绑定；**注水拦截点 = ToolRouter 路由分发前**——跨源挂起下发弹 L2 联合授权卡（展示注水后数据摘要：标题+前 N 行，禁盲签）；语义写死：目标 Server 永只见真实数据、永不见 `$ref` 字符串。
4. **Resources URI 合流（§12）**：只读数据注入走 `resources/list` + `resources/read`；`$ref` 收缩定位为「跨 App 写管道参数传引用」，两者正交；`$ref` 元数据可指向 Resource URI 合流命名。订阅（`resources/subscribe`）归 M3。
5. **Progress 通告（§12）**：客户端下发 `progressToken`，Server 经 `notifications/progress`（progress/total）回传；操作轨卡片状态机补 `Running(progress)` 态；无更新超阈值提示疑似卡死。
6. **Tier 2 降级垫片（§14）**：能力协商走标准 `initialize` capabilities；无 prompts → 无 Skill 注入；无 resources → 只读工具照常暴露；无 progress → 纯 Loading 态；**降级是默认行为，不抛异常**。Tier 2 静态摘要 = 首次挂载读 `tools/list` 前 3 个工具 name+description 拼接，须标注「自动生成」。
7. **MeshWireController 接线管道**：goodshare `_meta.goodhub.visibility` 声明产出 → 宿主 `$ref` 注水管道接线（依赖第 3 项）。

## 2. 现状取证（2026-10-11）

| 项 | 现状 | M2.5 缺口 |
|---|---|---|
| goodshare server（goodshare 仓 `lib/mcp/mcp_server.dart`） | Streamable HTTP POST-only 单响应，无 SSE 推送通道（GET/DELETE 405）；`initialize` 仅声明 `tools`；`resources/list` / `prompts/list` 已留空桩返回空数组 | `prompts/get`、`resources/read`、progress 通知通道、capabilities 声明扩展 |
| goodhub client（`lib/mcp/mcp_client.dart`） | 无状态逐请求 POST；`_decodePayload` 已兼容 SSE 帧响应；无 `initialize` 握手与能力协商 | capabilities 协商 + 协商结果缓存、prompts/resources 方法封装、$ref 暂存池、Skill 注入 |
| 接缝契约（goodshare 仓 `docs/design/ai-app-split.md`） | 零覆盖 prompts / resources / progress / Tier 分类 | 契约扩展回写（M2.5 前置，改接缝须同轮修该文档） |

**关键约束（已解，2026-10-11 D2 拍板）**：goodshare server「v1 不做服务端主动推送」与 `notifications/progress` 的矛盾——定案走 **POST 响应 SSE 帧流**（详见 §4 D2）。

## 3. 施工分解（T1~T7，依赖排序）

| 任务 | 内容 | 仓 | 依赖 |
|---|---|---|---|
| T1 接缝契约扩展 + goodshare 能力实现 | ai-app-split.md 回写 prompts/resources/progress 能力 + Tier 1/2 capabilities 分类清单；goodshare server 落地：`prompts/get` + `resources/read` 真实现（空桩转正）+ capabilities 声明扩展 + tools/call 响应 SSE 帧流改造（progress 夹带帧间） | 双仓 | D1/D2 已拍板，可开工 |
| T2 Tier 能力协商 + 垫片 | initialize 握手 + capabilities 解析 + Polyfill 行为（含 Tier 2 静态摘要）+ 协商结果缓存 | goodhub | T1 定稿分类清单 |
| T3 $ref 暂存池内核 | RefStore（Map + 大 Payload 临时文件 + TTL GC + 启动清池）+ `$ref` 句柄生成/解析 | goodhub | 无（可先行） |
| T4 注水拦截 + 跨源联合授权 | ToolRouter 分发前拦截 → L2 联合授权卡（注水后摘要）→ 网关内存注水替换 | goodhub | T3 |
| T5 三级 Skill 系统 | Skill 注册表 + 分层加载（Global 常驻 / App-Scoped 绑 Server / On-Demand activate_skill）+ Token 预算 + 官方预置最小集 | goodhub | 无（可并行） |

> **T5 实现注记（2026-10-11 ✓）**：`SkillRegistry`——注册硬闸（Global 300T 字符级预算 fail-fast 禁静默裁剪、name 唯一，CoW 覆写走 T6 显式通道）、会话粒度激活集（§15）、`composeSystemPrompt` 纯函数组装（base 前导保留——滑动窗口裁剪保护位；Global 常驻 + App-Scoped 绑已连 Server + On-Demand 已激活 + 尾部「可激活」清单）；`SkillActivationExecutor` 元工具拦截（activate_skill 本地激活不外发 server、未知 isError C-2 同轨、schema readOnlyHint=true → L1 静默）；builtinSkills 官方预置四条（ref-pipeline / task-discipline 全局 + goodshare-data 绑 server + deep-organize 按需）。debug 页装配：AgentLoop → SkillActivation → Hydration → Gateway → Face。
| T6 CoW 继承 + 版本告警 | prompts 拉取 → 本地覆写优先级 + 一键重置 + `min_hub_version` 告警 | 双仓 | T1（goodshare prompts 实现已纳入本里程碑，D1） |

> **T6 实现注记（2026-10-11 ✓，M2.5 收官）**：goodshare 侧补 `prompts/get` **arguments 字段缺省 → 未渲染原文**（CoW 拉原文通道，契约 §3.7 补行）；goodhub `cow_sync.dart`——prompts 模板 → appScoped Skill（`cow/<name>` 注册，对齐「Skill 来源 = CoW 同步」），`CowOverridesStore` JSON 持久化（覆写副本 + known_versions 基线，读方法惰性装载），`compareVersions`/`isMajorJump`（仅 major 跃迁告警，minor/patch 静默），`min_hub_version` 兼容闸（宿主低于声明 → 跳过），major 告警 delegate 三分支（重置回 server 版 / 保留本地 + 基线刷新防重复告警 / 缺省保守保留）；debug 页接线（同步进轨迹 + 告警 AlertDialog）。覆写/重置的编辑 UI 归 M3 服务大厅。
| T7 Resources + Progress 接线 | resources/read 只读注入 + $ref 元数据合流命名 + progress 通道（SSE 帧流）+ 卡片 `Running(progress)` 态 | 双仓 | T1 + T3 + D2 已定 |

> **T7 实现注记（2026-10-11 ✓）**：client `callWithProgress`——progressToken 自动注入 + SSE **流式分帧**解析（C-1 收侧兑现：progress 帧即达即回调，不再全量缓冲）+ 单 JSON 回退（Tier 2 兼容）；`McpToolFace.onProgress` 通道（null 不注入 token，opt-in 语义）+ debug 页药丸最小呈现；`listResources`/`readResource` 封装 + `RefEntry.resourceUri` 合流命名（§12）。**归 M3**：AgentLoop 事件流扩展（LoopToolProgress）与操作轨卡片状态机全量（Running(progress) 态/疑似卡死阈值）。

依赖链：T1 → T2/T6/T7；T3 → T4/T7；T5 独立。T2/T3/T7 的工程补齐要求见 §5。

## 4. 前置决策（2026-10-11 拍板，ADR-007）

- **D1 goodshare 侧实现归属 → 同程做**：契约扩展 + prompts/resources 在 goodshare server 本里程碑落地（`prompts/get` / `resources/read` 空桩转真实现），CoW 有真数据源，联调不等第二个排期。
- **D2 Progress 传输方案 → a) POST 响应 SSE 帧流**：MCP Streamable HTTP 标准允许 POST 响应回 SSE 帧，progress 通知夹带帧间、终帧仍含 result；goodhub `_decodePayload` 已兼容 SSE 帧，改动收敛 goodshare 侧响应写法。轮询（违背通告语义）与垫片后移（误 Abort 问题延续）否决。风险与回退见 ADR-007 收敛条件。

## 5. 工程补齐（2026-10-11 内部评审，四条）

- **C-1 SSE 帧流工程补齐（采纳，归因修正）**：本项目 App-to-App 直连（goodhub → goodshare `HttpServer.bind:8765`），无 Nginx/网关环节，`X-Accel-Buffering` 不适用——**缓冲黑洞在本仓两侧实现自身**：goodhub client `http.post` + `resp.body` 全量缓冲响应体（`_decodePayload` 是事后解析）；goodshare server dispatch 完成后才一次性写响应。真流式改造点 = client 侧 `StreamedResponse` 分帧解析 + server 侧边执行边发帧（T1/T7 核心改造）。补齐三件：① 响应头 `Content-Type: text/event-stream; charset=utf-8` + `Cache-Control: no-cache` + `Connection: keep-alive`；② **心跳保活帧**——>5s 无业务帧发 `: keep-alive` comment 帧（Dart http 无 read timeout，真风险是移动网络空闲 TCP 老化：Wi-Fi 休眠/NAT 表过期）；③ 心跳与 §12「无更新超阈值判疑似卡死」**正交**：心跳不重置卡死计时，只有 progress 业务帧重置。契约注明：若未来出现代理环节，须配禁缓冲头。
- **C-2 $ref 竞态与查无语义（已定 2026-10-11，AI 代决推荐项 a，可推翻）**：并行 Tool Call 竞态的前提在宿主不存在——`agent_loop.dart` 工具环 `for` + `await` 串行顺序执行（ADR-004 否决并发执行），消费者天然在生产者落池后进注水，拓扑阻塞检测无对象可解。真风险是模型**同轮引用尚未产生的 `$ref` id**（幻觉 id，串行同样命中）。**定案 = a) 查无此 ref 立即 isError 回填**（「引用不存在或已过期」→ 模型下轮自纠，与 `_executeWithBreaker` 协议异常收敛 isError 同轨，零新机制）；否决 b) 挂起等待生产者（对幻觉 id 等于等一个永不出现的 id，需另设超时，死锁面 + 新机制，串行调度下无竞态收益）。
- **C-3 临时文件泄漏（原设计已覆盖 + 一点补强）**：§9 已定「会话崩溃后下次启动全量清池」——进程被杀（OOM/系统清理）后 $ref 池会话绑定即焚、tmp 文件无主，启动**全量清空**比 mtime 阈值甄别更彻底且更简单（mtime 2h 窗口反而留残）。补强一条：**运行期 TTL GC 必须联动删除 tmp 文件**（元数据过期 = 内存删 + 文件同删）——Android 后台常驻进程长期不冷启动时，仅靠启动清扫不够。落 T3 验收。
- **C-4 Tier 2 静态摘要封顶（采纳）**：摘要总长硬封顶 **500 字符**（约 150 Tokens），超出机械截断 + `…`，防不受控 Server 污染常驻 Prompt 预算；工具切片用 `take(3)`（Server 工具数 < 3 时不越界）；「自动生成」标注不变。落 T2。

## 6. 验收口径

- `flutter analyze` 0 issue + 单测全绿：RefStore（TTL/GC/启动清池/大 Payload 落盘）、能力协商降级矩阵（Tier 1/2 × prompts/resources/progress 有无）、Skill 分层加载、注水拦截挂起语义。
- Tier 2 模拟 Server（仅 tools/list+call）全链路不抛异常、Skill 不注入、静态摘要标注「自动生成」。
- 跨源 `$ref` 注水：未确认时请求挂起不下发；确认后目标 Server 收真实数据（日志断言 `$ref` 字符串零外泄）。
