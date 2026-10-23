---
dev-loop: decisions
format: v1
epic: global
total-merged: 0
last-merge: none
---

# decisions

## misc

### [2026-10-16] 窗口解耦（内核+多投影）准入判定：S2 结构性引入，Directory 优先于 Runtime (src: ai)

**场景/痛点**：`mcp_servers.json` 被拼了 3 处（`chat_page:303` / `settings_page:268` / `gateway_controller:148`），其中网关那处不带旧 SharedPreferences 迁移参数——同一个「服务目录」三个消费点读到的内容可以不一致；装配逻辑 3 个调用点（chat / gateway / 联调页）各自重写；新增一个会话字段要改 3 处（声明/重置/持久化）。聊天页 `_send`(605-1110) 兼任装配中枢，`_GuardedExecutor`(65-80) 是 coordinator 件却住在 UI 文件。

**可选方案（含否决理由）**：
- A 结构性「四内核 + 窗口即投影」（Directory/Runtime/Session/Memory，窗口只持视图态）——采纳。
- B 局部补丁：只给 `gateway_controller:148` 补迁移参数 + 联调页继续自建装配——**否决**：命中准入否决信号 #2（同一处理需在第 2 个以上调用点重写，此处是 3 处），且已产生实际行为不一致；第 4/5 个消费点仍会重踩「漏带迁移/漏带信任闸门」。
- C 全量重构含 App Shell Router（窗口间零直接调用）——**否决**：Flutter `Navigator.push` 本就是平级关系（无 embed），真问题是可变状态共享而非路由方式；动 `main.dart` + 所有 push 点 + 测试，成本大而收益仅形式。

**最终决定**：判 **S2 结构性引入**，采纳 A，但相对原抽象作三处修正——① 分期顺序由「Runtime→Session→Directory」改为 **Directory→Runtime→Session**（Runtime 装配要读 Directory，属顺序依赖；Directory 是已存在的正确性缺陷，Runtime 是维护成本，正确性优先且 Directory 工作量最小）；② 铁律 2 由「窗口间零直接调用」**降级**为「窗口间不共享可变状态引用，路由维持 `Navigator.push`」；③ 删除「设置升格独立窗口」工作项——2026-10-16 已完工（`page-revamp.md` P1-终态有账），且设置页准确定位为「多内核的设置投影」而非「Directory 的窗口」。**待用户拍板立项**（是否新建 epic 承接 / 是否接受铁律 2 降级 / 联调页是否保留 fake 传输注入位）；方案已落 `docs/design/window-kernel-split.md`（draft）。

**收敛条件**：若本期只做补丁止血（补 gateway 迁移参数），须在**第 4 个 Directory 消费点出现之前**完成 Directory 契约化，并在权宜处留 `// PATCH:` 标记登记到期——无收敛条件的止血即无限期债。

**AI 洞察**：本设计最强的论据不是原抽象写的「Runtime 有第二调用点」，而是 **Directory 三处拼装中一处漏了迁移参数**——已存在的正确性不一致，比"重复代码"更难被后续发现。另：`assembleDefaultHybridEngine`（4 处调用）+ `fenced_cloud_engine.dart:9`「一个实例 = 一次 Run」说明 **Run 级装配的既有表达已存在**，ServiceRuntime 只需补齐 MCP 连接池这半边，不是从零引入新概念——这是"把已有散件立成契约"而非新建，风险被显著低估了。

### [2026-10-16] 全局迁就设计审视：外部评估逐条回仓取证，四类判定 + 拓扑自锁元问题 (src: ai)

**场景/痛点**：用户带入一份外部「迁就设计 vs 理想设计」评估（6 维度 + 4 条深度剖析 + 三触发条件路线图），要求分析。该评估文笔专业但**基座是通用 AI 架构常识推演，非本仓实证**——6 条中 4 条的「为何被排除」或「代价」与仓库记录不符，且**漏掉了本仓真正锁死天花板的元问题**。

**可选方案（含否决理由）**：
- A 全盘采纳评估结论进文档——**否决**：4 条事实性错误（见下）照抄会污染本仓 SSOT，恰是评估自己警告的「把权宜之计误当架构真理」；本仓 SSOT 是落点事实源，禁写入未经取证的归因。
- B 全盘否定——**否决**：其**方法论**（识别权宜 vs 理想二元、为锁定项打「演进触发点」标签）成立，且三个触发条件对本仓是真实增量（D-C / D-E / §9 三项**已锁定但无解冻条件**）。
- C 拆分采纳：只吸收「维度」与「触发条件」，理由与代价一律回仓取证后重写；并把评估漏掉的元问题补入台账——**采纳**。

**最终决定**：判 C。**评估四项错误（已取证推翻）**：① 「无指数退避重连」——`lib/core/network/backoff.dart` 已存在，M4-T4（T4-1~T4-5）2026-10-15 全量落地（D16：远端 HTTP 15s ping / 5s 超时 / 连续 2 次失败判 offline）；且 G8 记「缺 `WidgetsBindingObserver` 钩子」措辞不准——`main.dart:36` 早有 observer，只用于引擎预热/释放，**未接 ping 探活**，真实缺口仅此一环。② In-band 理由是「端侧不可用」——**错**：端侧 LiteRT-LM 已真机实证（约束解码 regex 1861ms / json 2911ms）且在摘要化路径中使用；真实理由见 `host-gateway-accessibility-memory.md` §3.1 / D-E = **0 额外前缀 Token + §3.8 缓存断点 A 保护 + 强因果一致性**，是**正向设计**；其「污染上下文」的代价亦被断点策略反驳（标签严格置尾、记忆不建独立断点）。③ SQLite 理由是「原生 C 库跨平台编译踩坑」——**无中生有**：本仓 CM1 记的真实理由是「全仓无 sqlite 依赖、MemoryStore 同栈、零新依赖」，本仓从无 sqlite 使用史。④ 「会话落盘时机脆弱」——与 §8.3 实证冲突（`_guardRunning` + `_persistIfAny` 已挡切会话写冲突，守卫生效即不脆弱）。

**评估漏掉、但真正锁死天花板的三条（本轮新增，落 `context/todos.md` 4 条 `风险[long]`）**：① **拓扑自锁**——`coding-standards.md` §1 画出目标拓扑，同一份 SSOT 禁止新增文件走向它，「统一收敛拍板」无 owner/无触发条件/无日期 → `platform/` 永不建立 → 规则 1 三处 `dart:io` 豁免的整改条件（= `platform/interfaces` 建立）被自己锁死；② **零 DI / 零路由**（`main.dart:97-115` 直挂 `home: ChatPage()`）→ 3 处拼 `mcp_servers.json`，`gateway_controller:148` 漏 `prefs` = **已存在的生产正确性 bug**；③ **SSOT 反向改写**（CM1 实现改完回填 SSOT）。

**收敛条件**：判据 = 「延迟项的解除条件，是否依赖另一件同样没人做的事」——是则死锁式迁就（红灯），否则合理延后（绿灯）。据此：SessionManager 并发隔离 / 429 / TC13 双进程 / 海关过滤待接线 **维持绿灯**（均有可观测触发条件，勿误伤）；拓扑自锁 / 零 DI / SSOT 反向改写 **红灯**；In-band / McpRuntime / `_persistConversation` **黄灯**（半拉子或已勘误）。新建待办一律带「收敛条件」字段，无收敛条件的止血即无限期债。

**AI 洞察**：评估警告「不要把权宜之计误当架构真理」——**本仓已经发生了，但不在它列的 6 条里**：`coding-standards.md` 正文写着「UI 层禁 `dart:io`」，同一份规范给三处永久豁免，且记录行号已从 `:19` 漂到 `:35` 无人复核，`memory_store.dart:135` 仍在引用这条已被自己违反的规则。**权宜静悄悄变成规范正文，才是「误当架构真理」的标准形态**——比任何单项技术选型严重。另：评估把本仓**主动分期**（`McpRuntime` 命名收敛、D-C 用结构约束替代运行时审计）一律误读为「不敢重构 / 能力不足」，方向性误判——本仓这些取舍大多有 `window-kernel-split.md` §8.1 十二项裁决与 §8.3「不入本轮」台账，不是无意识的妥协。

**处置**：仅在 `context/todos.md`（4 条）与 `window-kernel-split/todos.md`（1 条：步 0 的 ServiceDirectory 兼作拓扑收敛 seed + ChatPage 注入位）落账；**未改动任何 `docs/` SSOT**——待用户确认后再决定是否回写 `coding-standards.md` §1 与各项解冻条件。
- [ADR 2026-10-23] 决策: 网关投影机制归一走「一个能力源、一个管道、多档策略」——新增宿主内部 owner 档（海关全豁免+防火墙照常），App 内机主全权视图形式化为 policy=owner 的管道求值；owner 不经 URL query / gateway__select_private 暴露（parse 显式拒绝），机制归一以「owner 目录集 == ToolRouter.focusedSchemas 集合」防漂移断言钉死，App 内运行时不替换 focusedSchemas（三段式确定序保 prompt 缓存前缀，管道按名排序会破坏 §7.4/§8.2）。背景: PC 网关与 App 内链路同源两份装配，可见性/私有切换语义分叉，用户裁决方向「一个面两信任视图、能力最终一致」。后果: 裁决逻辑单点化（capability = f(face, policy)），后续管道规则演进自动覆盖 App 语义；App 内目录装配暂未切换（focusedSchemas 保持运行时门控 owner 等价）。收敛条件: 装配层合一（chat 复用 GatewayController face 源、消双实例双冷启动）落地时，App 内目录正式改经管道 owner 求值，focusedSchemas 降级为排序适配器；届时删除防漂移断言改用管道单测。
