---
status: draft
updated: 2026-10-28
---

# 架构收敛施工稿：owner 注册中心 + 装配 Profile 化

> 本文是架构盘点（epic `arch-review-2026-10`）产出的**结构性施工稿**，覆盖 `docs/project/index.md` 活跃债 **#20 ~ #26**。
> 规则 SSOT = `docs/project/coding-standards.md`（尤其 §1.1 形态判据、§3.1/§3.2 并发与写安全、§6.2 主体绑定）；本文只写**施工形态与验收**，不复制规则正文。

## 0. 目标与非目标

**目标**：让「新增一个能力」只需改一处装配、一处落盘路径、一处 Isolate 判定、一处主体声明，而不是三份接线 × N 处消费点。

**非目标**：
- 不重划分层拓扑（12 域不变，扁平域纪律见 coding-standards §1.6）
- 不引入事件总线 / DI 框架 / Immutable State 框架（§1.1 规则 3 明禁总线）
- 不改对外协议面（`:/mcp` 路径、`policy` 单轴、`_meta.goodhub.visibility` 口径）

## 1. 现状结构事实（改谁、为何）

| 事实 | 落点 | 后果 |
|---|---|---|
| 装配容器只供给 3 个构件，其余应用级状态在消费点构造 | `app/service_directory.dart` + 各 `ui/` 段与 `chat_page` | 同一路径多实例，各自全量 cache 写回 → 陈旧内存态覆盖（#20） |
| `McpRuntime.assemble` 只有窗口路径调用 | `ui/chat_page.dart` 一处；`gateway_controller` / `task/` 自拼 | 能力接线三份且不等价（#21） |
| Run 时序住在窗口 State 的单方法里 | `chat_page._sendGuarded` + 手工复位 | 每加一个能力都改同一处千行区域（#22） |
| 原子写有五份手写实现 | `coordinator/*` 四件 + `resources/resource_store` | 崩溃安全语义漂移（#23） |
| 重活卸载无阈值、无统一助手 | 仅 `pii_fence` / `resource_store` 两处 `Isolate.run` | 新功能易踩主 Isolate 卡顿（#25） |
| 调用主体不是值对象 | 网关仅常量时间 Bearer 比对 | 新增特权工具缺可机械核验的主体矩阵（#26） |

## 2. 施工分期

### S0 · 保护网先行（阻塞以下各步）

重构没有回滚判据就是赌博。先交付两类单测，再动结构：

1. **装配等价性**：`McpRuntime.assemble` 输入固定注入件 → 断言产物（face 集合 / 执行面链成员 / quota / 是否含 FencedCloudEngine）逐项一致；
2. **发送链路 golden**：把一次完整 Run 的**事件序列**落成可比对快照。

Golden 第一批必须同时覆盖**四类边缘切片**——Happy Path 不是 `chat_page._sendGuarded` 膨胀的原因，中断与异常才是：

| 切片 | 触发 | 断言要点 |
|---|---|---|
| `Golden-Happy` | 正常跑完 | `ChatRunStarted` → `LoopToolCallStarted` / `Note` / `Plan*` → `LoopFinished` 序列与顺序 |
| `Golden-Abort` | 工具执行中途发出取消信号 | 边界停下、`abort` 早于 `run` 的合法形态、部分写入以 `Cancelled` 收口、已有进度不回滚抖动（§10） |
| `Golden-Reject` | 确认卡被用户拒绝 | 回填 `user_rejected` 结构化结果、循环安全终止、**不计入两步熔断**（coding-standards §4.1） |
| `Golden-Watchdog` | 长任务看门狗 / SSE 断连 | 状态重置、`[DEGRADE]` 上报、退化为徒手可见而非静默 |

验收：两条 **先于** S1/S3 合入，且 `flutter test test/coordinator/ test/ui/` 全绿作为后续每步的基线。

### S1 · Owner 注册中心（#20）

把 `app/service_directory.dart` 升为**唯一应用级状态注册中心**：

**两段式生命周期（异步断层必须先立法）**：Widget 构造函数是同步的，Store 访问器是 `Future` 的——若不区分，必然逼出「路由处 await 卡白屏」或「UI 里塞 FutureBuilder」两种坏味道。按性质分两类：

| 类别 | 判定 | 获取方式 | 允许出现在 Widget 构造 |
|---|---|---|---|
| `SyncInitializable` | 纯内存 / 轻量元数据，构造即就绪（如 registry / 会话内核） | 同步工厂，可持有 `File`/路径参数 | 允许（走 `xxOverride` 注入位） |
| `AsyncStore` | 带磁盘 IO（`load()`）或依赖 `path_provider` 解析目录 | `Future<T> xxxStore()` + 进程内缓存 | **禁止** |

由此推出四条硬约束：

- **Widget 入参里不许出现 Store**：构造时只注入**同步件**——`ChatSendUseCase`（纯协调者）与 `RuntimeDelegates`（UI 弹层实现）；`AsyncStore` **不进 Widget 入参**，由此规避「路由处 await 冻屏」与「页面内 FutureBuilder 白闪」两条弯路。
- **异步屏障止于用例层**：Widget / 窗口禁止直接索要 `AsyncStore` 实体；窗口只注入 UseCase / Controller，`AsyncStore` 由 UseCase 在执行动作时 `await` 解析（既有 `resourceStore()` / `appVersion()` 的 `*Override` 注入位范式继续沿用给同步件与测试）。
- **消费点构造禁令**：`lib/ui/` 与 `lib/coordinator/` 不得出现受管 store 的构造表达式（含别名工厂与 `underSupportDir` 形式工厂）；构造点只剩三类：注册中心内部、类型自身 factory、测试注入位。
- **测试隔离**：注册中心的进程内缓存必须提供 `resetAllForTest()`，单测在 `setUp` / `tearDown` 成对调用——否则静态缓存会跨用例串扰（`KeyedWriteQueue.instance` 同为进程级单例，一并纳入复位契约）。
- 「同一路径多实例」由构造点收敛消掉；写侧串行不依赖实例收敛，`KeyedWriteQueue.keyForPath` 以 `File.absolute` 规范化路径键，跨实例同一条链（已有制度，S4 不再重复发明）。

### S2 · 装配 Profile 化（#21）

`McpRuntime.assemble` 接 `RunProfile`（`chat` / `gateway` / `headless`），由它决定：

| 装配产物 | chat | gateway | headless(task) |
|---|---|---|---|
| 执行面链 | 全量（含 Plan / 记忆 / 资源） | Allowlist 内 + 确认卡同一咽喉 | 任务原语子集 |
| 权限裁决 | RuntimeDelegates 有人值守 | `GatewaySecurity` 会话级 | 无人值守 fail-closed |
| 反向请求 | sampling + elicitation | sampling（host 面除外） | 不接线 |
| 生命周期 owner | Run（UI 可 Abort） | 连接会话 | 单次任务 runOnce |

**一期已落地**（`lib/coordinator/run_profile.dart`）：`RunProfile` = `chat` / `gateway` / `headless`，映射表 `capabilitiesFor()` 是能力上限的**唯一映射点**；`McpRuntime.assemble(profile:)` 按声明接线：

| 能力 | chat | gateway | headless |
|---|---|---|---|
| `sampling`（反向推理） | ✅ | ✅ | ❌（不外借宿主推理） |
| `elicitation`（结构化提问） | ✅（需 UI 委托） | ❌（无 UI 恒不接） | ❌ |
| `cowSync`（模板同步） | ✅ | ❌ | ❌ |
| `planFence`（编排围栏） | ✅（需 `planState`） | ❌ | ❌ |

释放语义**不随 profile 退化**：`close` 仍全覆盖且幂等（单测钉死）。

**二期已收口（结论修正）**：实施时核到——网关本就经**共享挂载原语**（`McpRuntime.mount/mountEndpoint`）建 face，「三路并行」的实际第二副本是 **sampling 接线循环**。已收口为唯一实现 `lib/coordinator/reverse_wiring.dart` 的 `wireSampling()`（差异只允许出现在参数：排除集 / 回调；网关传 `excludedServerIds: {kHostServerId}`）。任务管道经 `goodshare_task_api` 直连，本就不是 MCP 装配面——原「三路」表述有误，实证更正。**生命周期差异（常驻 vs Run 焚）是设计而非债**：强并 `assemble` 属过度设计，不再立项。「debug 联调页不并回」红线维持（其单 Server 裸名 + 静态 tools 语义独立）。

### S3 · 发送链路下沉（#22）

**一期已落地**（`lib/coordinator/chat_send_use_case.dart`，纯 Dart 132 行）：
- `ChatRunSink`（渲染端口，UI 实现）+ `ChatSendUseCase.run()` 承接 **plan → 事件消费 → writeback → 收口**时序；`cancel()` 统一持有在途装配（F19 预中止转发）；
- `chat_page._sendGuarded` 的事件 switch（~145 行）整体迁入 `_RunSink`（同库私有可见，逻辑逐条照搬），`_sendGuarded` 降至 ~380 行；窗口层剩「装配 + delegates + 渲染」。

**二期已落地**：`ChatSendUseCase.assembleRun()`——skills 装载（注册闸降噪经 `onNoticeOnce` 回窗口）+ 会话绑定 + `McpRuntime.assemble` 全段下沉（`_sendGuarded` 1571→1526 行，方法体 ~330 行）；信任闸门仍留窗口（信任卡片是 UI，§7.1 纪律）。**尾项已收口（独立小步）**：① 取消统一入口——`ChatSendUseCase` 自 `assembleRun` 起持有取消锚点（`_active`），窗口 `_abort()` 改经 `useCase.cancel()` 收口（不再直戳 `_activeAssembly?.abort()`；`_resetSessionState` 纯会话切换复位，与取消解耦，无 `CancellationToken` 类新增——避免空壳件）；② `dual_track_stream.renderEntry` 巨型 switch 拆为 15 个按卡片类型的 `_TrackXEntry` 子组件，`renderEntry` 退化为薄 switch 委托，行为等价（22 例 `dual_track_stream_test` 全绿）。

验收：S0 的 golden 事件序列零改动通过（回放等价即行为等价）。

### S4 · 写通道收口（#23）

**反模式（本文明确禁止，不得实现）**：脱离队列的静态 `writeAtomic(path, content)`。它自身不带互斥，两个调用方对同一路径会各写一份临时文件并在 OS 层 `rename` 互撞（POSIX 下后发先至覆盖；Windows 族下 rename 会被拒），串行队列的语义被旁路。

**唯一合法入口**（一期已落地）：

- `KeyedWriteQueue.instance.enqueueAtomicWrite(path, bytes)`：以 `keyForPath`（`File.absolute` 规范化）排队，在任务内部执行 `tmp → flush → rename`，失败透传 + 残档清理 + 不毒化队列；
- **六处**手写副本全部迁入：`coordinator/{cow_sync, user_prompt_store, conversation_archive, ref_store}` + `resources/resource_store` + `mcp/server_endpoints`（第六处为实施时全仓扫描新发现——恰是「清单外还有副本」这一根因的现场证明）；
- `SequentialFileWriter` 维持既有接入者（MemoryStore / WorkspaceStateStore / ConversationStore 等）不变；
- 机核已落（§2.7）：arch-guard **R10** 按调用签名禁 `File.writeAs*`（白名单仅 `lib/core/storage/` 两基准件；`File.rename` 不拦——损坏备份等合法用法）+ CI 镜像 `test/architecture/atomic_write_rules_test.dart`（含金丝雀）。行为单测：`keyed_write_queue_test` 的 S4 组（写透 / 并发串行化 / 失败透传不毒化）。

### S5 · 卸载阈值与看门狗（#25）

**适用范围（先收窄，再谈阈值）**：`offload` 只服务**纯 CPU 密集的同步转换**——大型 JSON（反）序列化、加密/摘要、AST 与 Markdown 解析、超长文本正则。以下三类不列入：

| 明确排除（不做 Isolate 卸载） | 理由 |
|---|---|
| 普通异步文件 IO（`readAsBytes` / stream） | `dart:io` 由 native 线程池驱动，主 Isolate 只收事件通知；包 `Isolate.run` 反而多两次数据拷贝 + 上下文切换 |
| 「预估耗时 ≥ N ms」类规则 | 闭包耗时不可前置判定，写成规则只能靠人猜——违背本文「规则必须可判定」的前提，直接不立 |
| IO 之后的纯搬运 | 数据在使用点已就位的，不再跨 Isolate 转一圈 |

**一期已落地**：`lib/core/concurrency/offload.dart`——

- `OffloadThresholds`（初值集中调参）：JSON ≥256KB / 正则 ≥64KB / 加解密 ≥128KB / 入参 ≥1MB 改 `TransferableTypedData`；
- `shouldOffload(kind, bytes)` 可判定谓词（无「预估耗时」）；
- `OffloadPool.run(task, timeout:)`：有限并发（默认 2）+ 超时守卫 + **僵尸占位语义**——超时弃等不弃占，槽位在底层 Isolate 真结束时才释放（超池快速失败 `OffloadBusyException`，禁无限积压）；
- `offloadIfHeavy(...)` 便捷封装：够阈值进池，池满退主 isolate（DEGRADE 留痕，保正确性）。

示范迁移两处：`pii_fence.mask`（超时语义不变，原 TimeoutException 分支原样保留）与 `resource_store` 导入解码+哈希（阈值口径从「>1MB 才卸载」收紧为 crypto 128KB，行为单测全绿）。

### S6 · 调用主体一级抽象（#26）

- `Actor` 值对象（`owner` / `local` / `external(id)`）**只在鉴权层推导**（same-signature / 信任白名单 / Bearer），禁止从请求载荷字段读取（§6.2）；

**关键分野（必须与 S2 对齐）**：`Actor` 是**每请求动态**的，而 `assemble` 是**每次场景**的。若在装配期按当前 Actor 静态裁剪工具表单，常驻网关就必须为「每个连接 × 每种主体」重跑一次完整 `assemble`，与网关单端口共享缓存的连接模型直接冲突。故：

| 层次 | 职责 | 时机 |
|---|---|---|
**一期已落地**：

- `lib/core/actor.dart`：`Actor` 值对象（`owner` / `external(id)`；`external` 为 const factory，身份粒度随鉴权层演进——当前配对 Token = 通道级，UID 白名单落地后细化）；
- `HostExportEntry.allowedActors` **必填**（编译期强制：新增导出项未声明主体即不合格）；声明出处即 `kHostExportAllowlist`（唯一声明面）；
- 运行时闸 = 网关 `toolsCall` 的 `host__` 分支（先于路由/环路防护）：`_hostEntryFor(tool).allowsActor(actor)` 不满足 → 协议级拒绝 `kGatewayActorDeniedCode`（-32003）**且不触达执行面**；server 层在 Bearer 校验通过后置 `Actor.external('gateway')`（禁从载荷读）；
- 单测 `test/gateway/host_actor_gate_test.dart`（4 例：配对 PC 放行且真实触达 / 集外主体拒绝且零触达 / owner 恒可读 / 非 host 服务不受矩阵辖制）。

**二期余项**：Binder 通道（同机插件）的 `Actor.external(<包名>)` 推导随其调用链接入时补；`Actor` 细粒度化（per-app）依赖鉴权层演进。

### S2.7 · 机械镜像的抗脆弱性

Guard 规则若按「字符串长相」写，必然被改名绕过，也必然误伤合法代码。两条新规则按下表执行：

| 目标 | 脆弱写法（不采用） | 采用的写法 |
|---|---|---|
| S1 受管 store 构造禁令 | 匹配 `ResourceStore(` 字面量——别名工厂 / typedef 转发即绕过 | **按构造形态**：在 `lib/` 内检出受管类型的 `InstanceCreationExpression`；**白名单只有三处**：注册中心内部、类型自身 factory、测试注入位。范围内的重定向构造（工厂函数转发）同样计入。机械细节由落规则时确定；若需精确 AST，评估引入 Dart 分析包作为 dev 依赖的成本（现有 `test/architecture/` 为文本/行级实现） |
| S4 原子写唯一的入口 | 匹配 `'.tmp'` 字面量——改成 `.temp`、动态拼接即绕过；注释含该词即误伤 | **按调用签名**：除 `lib/core/storage/` 外，`lib/` 禁止出现 `File.rename` / `File.writeAsString` / `writeAsBytes` 的调用；允许调用面 = `KeyedWriteQueue.enqueueAtomicWrite` 与 `SequentialFileWriter`。 绕过的成本从「改字符串」变成「自建一套文件写实现」，肉眼可审 |

**测试隔离的双重保护**：规则只作用于 `lib/`，`test/` 内的 Mock / Stub 不受约束（已在既有 arch-guard 的目录口径内）。

**机核落点**：这类「代码形态禁令」落在 `test/architecture/`（CI 必跑全量 `flutter test`）并由 `scripts/agent-tools/arch-guard.sh` 提供 pre-commit 秒级镜像；**不落在 `drift_rules_test.dart`**——该件是 registry 数据驱动的契约面漂移镜像（BANNED/CONST/OVERSIZE 三类），不承担静态 API 调用禁令。

## 3. 施工顺序与依赖

```
S0 保护网 ──┬─ S1 owner 注册中心 ──┬─ S2 装配 profile 化 ── S3 发送链路下沉
            │                      └─ S4 写通道收口（独立，可并行）
            └─ S5 卸载助手 ── S6 主体抽象（在 S2 之后才能挂到 assemble）
```

- S0 **阻塞** S1 / S3；S2 是 S6 的前置；S4 / S5 可并行。
- 每步合入线：`flutter analyze` 0 issue + 全量 `flutter test` 不劣于基线 + arch-guard / drift-guard 通过。

## 4. 风险与取舍

- **S1 一次性引入多个访问器**会扩大注册中心的治理面；取舍：优先迁移「已确认存在多实例」的 store 清单，不一次性迁移全部。
- **S2 profile 化**可能把联调页的特异语义拉回 `assemble`；取舍：profile 只决定「有没有某能力」，不承载假的传输——假传输继续经 `clientFactory` 注入。
- **S5 阈值**是初值，须真机实测；取舍同上，阈值集中在 `offload` 一处，便于调参而不到处散落。

## 5. 关联 SSOT

- 规则：`docs/project/coding-standards.md`（§1.1 / §1.4 / §3.1 / §3.2 / §6.2 / §8）
- 登记：`docs/project/index.md`（活跃债 #20 ~ #26、超标清单、直连白名单基线）
- 约束边界：**本文不改规则正文**；规则须调整时按 coding-standards §9 三条同轮同步
