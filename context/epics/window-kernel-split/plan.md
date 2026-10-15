---
dev-loop: plan
format: v1
epic: window-kernel-split
status: active
updated: 2026-10-16
---

# window-kernel-split 实施计划（WBS + 门禁 + 回滚点）

> **设计 SSOT**：`docs/design/window-kernel-split.md`（§7.5 路线图是本计划的唯一来源；裁决台账 §8.1 十二项）。
> **本文件纪律**：只排**任务、顺序、门禁、回滚点**，**不抄设计正文**（防双源漂移）。条款冲突一律以设计稿为准。
> **准入**：S2 结构性引入（`context/decisions.md` 2026-10-16），否决信号 #2 命中 3 处，落点 = Directory。
> **冻结状态**：§8.2 待确认已清空（0 项），**步 0 可开工**。

## 0. 前置约束（开工前必读，违反即返工）

| # | 约束 | 出处 |
|---|---|---|
| C1 | **纯 Dart 内核**：新增契约文件**严禁 import Flutter Widget**（`material.dart` / `BuildContext` / `setState`）。内核跨 headless（gateway）复用，染 Flutter 即失效 | §7.5 步 0 |
| C2 | **两条流串行**：本重构流水线（步 0→1→2→3）与「内部服务改造」（chatmessage epic 的 G1/G3/D-H/D-I）**禁止同文件并发改**；报错无法归因（分不清接口接错 vs 服务改崩） | §7.3 |
| C3 | **测试基线不得推到步 1**：基线测试与契约**同轮完成** | §7.5 步 0 |
| C4 | **不碰 8 个 Deferred 内核内部**（EngineSupply / TrustGovernance / ConversationArchive / Memory / SkillSupply / Gateway / TaskLoop / Updater）；「未认领」≠「不接触」——装配必然依赖其接口 | §3.1 / §8.1-6 |
| C5 | **拓扑**：本计划只做**一个**目标拓扑 seed（见步 0-T7），其余文件落点沿用扁平域，不构成双轨 | `context/todos.md` 2026-10-16 |

### 0.1 开工动作：先测基线（**必做，勿跳过**）

设计稿记 583 / system-assessment memory 记 529 / workflow skill 记 491 —— **三口径互不一致，均不可信**。故本计划不锁死数字，2026-10-16 **已实测**，结果如下（两项**均与文档记录不符**）：

| 基线项 | 实测值（2026-10-16） | 与文档记录的偏差 |
|---|---|---|
| `flutter analyze` issue 数 | **0**（No issues found，14.1s） | ⚠️ 文档多处记「存量 1 info `gateway_loop_debug_page.dart:670`」——**该存量已消失**（疑随 page-revamp 轮或工具链升级被修）。`context/todos.md` 首条 `(清理)` 待办据此**可销账** |
| `flutter test` passed 数 | **588 全绿**（01:18） | 三份文档记的 491 / 529 / 583 **全部过时** |
| 真机冒烟（聊天 + 私有域切换） | 未跑（无模拟器） | 步 1 前必跑一次 |

> **门禁口径因此收紧**：既然实测是 **0 issue**，本计划全程按 **0 issue** 要求（不再是「0 新增、存量 1 不算」）。若开工时又冒出 info，先确认是否为新引入。

复测命令：

```bash
export PATH="$HOME/flutter/bin:$PATH" ANDROID_HOME="$HOME/android-sdk"
flutter analyze                    # 目标：0 issue
flutter test --timeout 120s        # 目标：588（只增不减）
```

## 1. 分期总览

| 步 | 一句话 | 破坏性 | 回滚代价 | 依赖 |
|---|---|---|---|---|
| **0** | 立契约 + 建基线测试 + 修 gateway 漏迁移 | **零接线、零破坏** | 删新增文件即回滚 | — |
| **1** | 搬迁装配内核（658-970），chat_page 变调用方 | 高（动 `_send` 心脏） | git revert 单 commit | 步 0 |
| **2** | 收敛 gateway_controller → 联调页 → task_loop | 中 | 逐调用点独立 revert | 步 1 |
| **3** | chat_page 接线瘦身 + 剥离配额与记忆面 | 中 | git revert | 步 1（可与步 2 并行） |

> 步 2 与步 3 无顺序依赖，但**建议串行**：步 2 第 1 项（gateway 生产路径）带活 bug，优先。

## 2. 步 0 · 立契约与基线（零破坏性）

**落点**：`lib/coordinator/mcp_runtime.dart`（与 `hybrid_assembly.dart` 同级）+ 装配容器 seed。

| # | 任务 | 关键约束（照抄伪代码会编译失败） |
|---|---|---|
| T1 | `SessionContext` —— **纯不可变快照** | 含 `activePrivateServerId` / `activatedSkills` / `conversationId` / `degradationState` / transcript / `_wsStates`；**不含配额**（§8.1-4） |
| T2 | `SamplingQuota` **实例独立入参** | 真实语义 `Duration? tryConsume(String serverKey, DateTime now)`（20 次/60 分钟·按 serverKey 分桶），**不是 token 数、不是 bool**（`sampling.dart:14-32`） |
| T3 | `RuntimeDelegates` **八端口** | 挂起 `Future<T>` = gate / fence / block / consent / majorJump；广播 `void` = onNote / onProgress / connectionReport（`onToolCall` **不在内**）。`gateDelegate` **可空**（headless 传 null，§8.1-2） |
| T4 | **Abort 兜底**（防悬挂，必做） | Abort 时以 `GateDecision(approved:false, reason:'aborted')` 完成**所有** pending 卡，防 `TrackConfirm.completer`（`dual_track_stream.dart:69`）永挂 |
| T5 | `McpAssembly` 句柄 | 出 `loop` / `router`（**仅 `close()` 前有效**，窗口不得缓存）；**内部**持有 `List<McpToolFace>`（不暴露）；`abort({required String reason})` 同步遍历取消（**不释放**）；`close()` **幂等**（先 abort 再释放，内部 `_closed`） |
| T5a | 两处实现约束 | `McpToolFace.cancelActiveRequest` 返回 **void**（`mcp_tool_face.dart:203`）→ **不可 await / Future.wait**；`AgentLoop.abort()` **无参**（`agent_loop.dart:193`）→ `reason` 只用于 cancel notify |
| T5b | `close()` 关到哪一层 | = `McpConnection.stop()` **+ `client.close()`**（现状 finally 只调 `stop()`，底层传输未释放 = 既有债，随本步修，不单独立项） |
| T5c | `clientFactory` 注入位 | 装配**必须**接受 `McpClientFactory? clientFactory`，默认 `McpClient.http`（范式 `server_probe.dart:49-52`）——否则步 1「全部连接已 close」无从断言 |
| T6 | `ConversationSession` 写回签名 | `replaceTranscript`（**全量替换**，命名 `append` 会致 transcript 跨轮翻倍，`chat_page:1067` 是 `clear()+addAll()`）/ `bindPrivateServer`（**三态** `null`=未绑定 / `''`=显式公共 / `id`=锁定）/ `unbindToPublic`；`toJson`/`fromJson` **只立签名、不实现持久化** |
| T7 | **`ServiceDirectory` 单一入口** + 修 `gateway_controller:148` 漏 `prefs` | 收敛三处拼装（`chat_page:303` / `settings_page:270` 带 prefs / `gateway_controller:148` **不带**）；**落点改由新建 `lib/app/`（或 `lib/core/di.dart`）装配容器承载** —— 这是解除 `coding-standards.md` §1 拓扑自锁与三处 `dart:io` 豁免死锁的唯一单点，**零额外工作量**（换个落点而已）。**其余文件落点不变** |
| T8 | `ChatPage` 注入位（同轮） | 加 `storeOverride` / `engineOverride`（范式 `settings_page` 的 `endpointStoreOverride` / `probeOverride`），解「构造无参 → `chat_page_smoke_test` 只能冒烟」的可测性债 |

### 2.1 基线测试（**与契约同轮**，C3）

| # | 用例 | 要点 |
|---|---|---|
| B1 | **归档** `test/coordinator/discovery_executor_test.dart:177-305` 已有断言为基线 | **不要重写**（私有槽位 / 三段式序已覆盖） |
| B2 | `_resolveBinding(endpoints)` 回退链纯函数测试 | 全局钉选 → 首个启用 private → `null`；私有方法、**最易改错** |
| B3 | **私有域三态往返断言** | `null` / `''` / `serverId` 各一次，落盘反序列化**原样无损**（无 `isEmpty ? null` 归并）——专为防日后被"顺手优化"成二态致「显式公共」回跳（`conversation_store.dart:61-63`） |

**DoD（步 0）**：新增文件**零接线**；`flutter analyze` **0 新增**；`flutter test` **计数不劣于基线**；`lib/coordinator/mcp_runtime.dart` grep 无 `package:flutter`。

**回滚点**：步 0 全部为零接线新增 → `rm` 新增文件 + revert gateway 一处即完全回滚。

## 3. 步 1 · 搬迁装配内核

**搬迁边界（写死）**：`chat_page._send` **658 → 970**（末行 `loopBox = loop`，即 `AgentLoop` 构造完成）。**991 起事件循环不搬**——`LoopToolCallStarted/Progress/Finished` 是**执行期**事件流消费，属窗口渲染；塞进端口组会把范围扩到 1015-1105 的双轨 UI 核心，违反"先抽纯壳"。

| # | 任务 |
|---|---|
| T1 | 搬迁装配段 658-970 → `mcp_runtime.dart` |
| T2 | 搬迁 `_startConnection`(1113-1138) 三回调（含 `mounted` 守卫）→ `connectionReport` 端口 |
| T3 | 搬迁 `_GuardedExecutor`(65-80)（纯 Dart，coordinator 件却住在 UI 文件） |
| T4 | **整个 try-finally 一起搬**（`connections` 声明 658 / finally 1089-1108）——只搬装配、把 finally 留页面 → Run 级生命周期不成立，连接泄漏立刻出现。判据 = **谁持资源谁释放** |
| T5 | 留窗口（**视图态**，铁律 3）：`_streamBuf.flush()`、`_running` 置位 |
| T6 | `_persistConversation` **本轮不迁**（属 `ConversationArchive` 持久态，§8.1-5 勘误），暂留窗口作临时替身 |

**单测** `test/coordinator/mcp_runtime_test.dart`：

1. **装配产物等价性** —— 搬迁后 `privateServerIds` / `activatedServers` / `activePrivateServerId` / `focusedSchemas()` 与搬迁前**逐项一致**（不是重测 `ToolRouter`，那段已被 `discovery_executor_test` 覆盖）；
2. **资源释放** —— 装配异常 + Run 结束 `finally` **两条路径**下全部连接 `close()`，且 `refStore.expireAll()`/`dispose()` 被调用。断言手段：经 `clientFactory` 注入 fake client 计数（句柄封死，不能从句柄观测）。`close()` 内部失败按 **DEGRADE 留痕、不抛穿 finally**。

**DoD（步 1）**：`chat_page` 改为调用方；`flutter analyze` 0 新增；测试全绿；**真机端到端冒烟通过**（聊天 + 私有域切换）——无模拟器，真机侧载为唯一 UI 验证路径。

**回滚点**：步 1 单 commit，`git revert` 可整体回退（步 0 契约文件保留，不浪费）。

## 4. 步 2 · 收敛其余调用点（**按此顺序**）

| 顺序 | 调用点 | 做法 | 禁忌 |
|---|---|---|---|
| 1 | `gateway_controller._assemble`(109-168) | **生产路径 + 带漏迁移活 bug，优先接入**。装配选项参数化：无 UI 通知 / 无装饰器链 / 填充 `handler.faces` | — |
| 2 | `gateway_loop_debug_page._run`(294-360) | **不复用完整装配**——单端点、无路由、无装饰器链、自有 `_TextEntry` 轨迹。**只复用挂载原语**（`client → negotiate → face → listTools`） | **不开 `isFakeDebug` 特权分支**；fake 传输经步 0 已定的 `clientFactory` 注入，与生产同路径（§8.1-11） |
| 3 | `task_loop_service:206` | 仅适配 `mountEndpoint(ServerEndpoint.ephemeral(url, key))`，**不动** claim→心跳→apply 调度模型 | **不开 `assemble(baseUrl:)` 重载**（会让 McpRuntime 出现两套入口语义） |
| 3a | ↳ 凭证隔离（§8.1-9） | ① ephemeral **不进 Directory 列表、不参与 `save()`**（`store.save()` 全量覆写，进列表即落盘）；② 记忆/日志 **scope 强制任务上下文**，禁写 user / srv 全局域 | — |

**DoD（步 2）**：三个调用点编译通过；gateway 生产路径真机冒烟；`gateway_controller:148` 迁移 bug 消失（旧单端点配置网关侧可读到）。

## 5. 步 3 · ChatPage 接线与瘦身验收

| # | 任务 |
|---|---|
| T1 | `_send` 变薄：收集会话上下文 → 组装 `SessionContext` → `McpRuntime.assemble` → `finally` 释放 |
| T2 | 剥离 `_samplingQuota`(106) → **`ConversationSession`**（不是 Runtime——60 分钟窗口跨 Run 共享，是会话级） |
| T3 | 剥离记忆 In-band 提取面 —— `WorkspaceStreamFilter` 本身已是纯 Dart，要搬的是它内联在 `_send` 663-700 的**构造与落盘**；UI 胶囊部分走 `onNote` 回传 |
| T4 | 会话五字段 + `_resetSessionState`(219) 手工枚举 → `ConversationSession`（枚举随之消失，解 §2.3） |

**三项行为变更（步 0 裁决引入，须**显式**验收）**：

1. 配额归 Session 后**切会话即重置**（原 `chat_page:106`「D3：重启清零」是页面级）；
2. **headless 路径 L2 写操作恒返回 `user_rejected`**（`gateDelegate=null` → `PermissionGateway` fail-closed `_rejected('宿主无确认界面…')`，`isError=false`，模型可自纠）；
3. transcript **全量替换**语义不变（同会话多轮后条数**不翻倍**）。

**DoD（步 3）**：`flutter analyze` **0 issue**（实测基线即 0）；测试全绿且**计数 ≥ 588**；端到端聊天与私有域切换回归正常；三项行为变更逐条验过；`chat_page.dart` 从 ~1647 行瘦到 ~600-700 行。

## 6. 全局门禁（每步结束都必须过）

```bash
export PATH="$HOME/flutter/bin:$PATH" ANDROID_HOME="$HOME/android-sdk"
flutter analyze                    # 0 issue（实测基线即 0，见 §0.1）
flutter test --timeout 120s        # 全绿，计数 ≥ 588（只增不减）
flutter build apk --debug          # 需真机验证的步（1/2/3）
```

**每步收尾落 `devlog.md` 一行 `[验证]`**（dev-loop §2 第 4 条），格式：`[验证] <命令> → <结果>`。

## 7. 风险登记与熔断

| 风险 | 触发信号 | 处置 |
|---|---|---|
| **无 chat_page 级测试基线** | 步 1 改 `_send` 心脏却无回归网 | 步 0 先建 B1-B3 基线 + T8 注入位；**基线未绿禁止进步 1** |
| **装配段与 UI 深度交织** | 直接搬迁编译不过 / 被迫传入整个 `_ChatPageState` | 违反即停——**先定义 8 端口再搬代码**（§7.1），传 State 等于没解耦 |
| **与 chatmessage epic 同文件冲突** | 两边都要改 `agent_loop` / `tool_router` / `context_governor` | 走 C2 串行纪律，**禁止并发** |
| **真机不可用时** | 步 1/3 需真机端到端 | 真机为唯一 UI 验证路径，**不可跳过**；不可用时该步**挂起**不交付，禁止以"编译通过"冒充验收 |
| **8 端口定义蔓延** | 端口数从 8 涨到 10+ | 回设计稿复议——端口膨胀说明边界划错（可能误搬了执行期事件） |

## 8. 明确不在本计划范围（记债，非遗忘）

| 项 | 去向 |
|---|---|
| `MemoryStore` 兼审计日志 `opsLog` 拆分 | `context/epics/chatmessage/todos.md` `(风险)[long]`（收敛条件：审计与记忆需不同保留策略时） |
| 8 个 Deferred 内核的内部改造 | §3.1 Catalog Only，另立 epic |
| `AgentLoop` / `PermissionGateway` / `ToolRouter` 内部 | §9 不做边界 |
| `SamplingQuota` 落盘 / Directory 通知通道 | `todos.md`（Archive Deferred） |
| 拓扑**全面**收敛 | 本计划只做 T7 一个 seed；整体收敛仍待 `coding-standards.md` §1 补 owner + 触发条件（`context/todos.md`） |
| `lib/mcp/tool_router.dart` 处置 | **不删、不引**（F1.9 海关过滤唯一实现，SA-Q6 已拍板保留待接线，§8.1-12） |

## 9. 断点

- [断点] 下一步：**步 0 → T7**（`ServiceDirectory` 单一入口 + 修 `gateway_controller:148` 漏 `prefs`）——建议**先做 T7**，因为它是唯一带**活 bug** 的项，且是拓扑 seed 的落点；T1-T6 契约紧随其后。
- 开工前置动作：§0.1 基线实测（填表），基线未记录不得开工。
