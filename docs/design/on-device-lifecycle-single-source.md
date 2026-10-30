---
status: draft
updated: 2026-10-30
---

# 端侧引擎生命周期状态单源化（A 工作流立项）

> 立项背景：2026-10-29~30 真机连续 11 起事故（ipc deadlock / 映射权限 / 游标回绕 / EPOLLHUP / 句柄符号位 / 受理态误判 / mem-pressure 击杀 / 数据面驱逐后静默短路）复盘定性——其中 7 起为跨进程接缝契约违规、4 起为同一环境（ColorOS）反复击杀 3GB 服务进程。打地鼠的机制根源是**生命周期状态机没有单一主权者**。本文是该缺口的收敛设计；B 工作流（装载存活策略，见 epic devlog 2026-10-30）已独立落地解当前阻塞，本文不重复其内容。

## 1. 问题定性：分布式状态机，无单一真相

「引擎是否可用」这一事实现分散于 3 层 6+ 状态持有者，靠单向事件异步同步：

| 层 | 状态持有者 | 说明 |
|---|---|---|
| Dart | `_loadState`（unloaded/loading/ready/failed） | 混合引擎与 UI 的决策依据 |
| Dart | `EngineCircuitBreaker` / `EngineThermalGate` / `_active` 流表 | 独立判断面 |
| 主进程桥 | `engine` 代理 / connection / dataPlane worker handle | 绑定与数据面句柄 |
| `:engine` | `session.ready/creating` / `dataPlane` / `EngineLifecycle`(TTL/护栏) / thermal | 唯一真正掌握执行真相的一层 |

必须全局成立的不变量没有单点立法，每条重入路径（bind/enable/loadModel/generate 兜底/驱逐回收）各自独立推导前置，任何异步事件（驱逐、进程死亡、热切云）打破前置即产生一类新的「说谎态」。已实证的同类事故：驱逐后 `loadState` 仍 ready（P0-3 前身）、`dataPlane` 驱逐后 `loadModel` 静默短路（2026-10-30）、`assetMissing` 序数承载受理/终态两义（P2-14）。

## 2. 目标态

### 2.1 状态单源化：真相收敛 `:engine`

- **权威状态机 = `:engine` 的 `EngineLifecycle`**：`IDLE → LOADING → READY / EVICTED / DEAD` 单机承载（含 TTL、内存护栏、驱动 Panic、外部处决全部迁移沿）。
- **主进程与 Dart 沦为投影**：`loadState`/bridge 句柄全部改为事件流驱动的缓存（`onLifecycleChanged(state, gen)` 单事件源），**禁止本地独立判定 ready**；判定需求一律转为「等待权威沿」或「发命令看结果」。
- **代次号（gen）贯穿**：装载/驱逐/释放沿递增，旧沿的迟到处账按代次丢弃——消除迟到处账覆盖新状态竞态（B-2 已在 Dart 侧预演同型机制）。

### 2.2 入口幂等自愈：前置内聚到命令面

所有 AIDL 入口（`loadModel`/`startGenerate`/`startDataWorker`）内部先跑 `ensure(preconditions)`：数据面缺失就地重建、会话缺失就受理装载、连接缺失就报中断。前置清单**只存在于 `:engine` 一处**；主进程不再需要知道「驱逐后要先 initEngine」这类私有前置。对外失败只有两态：

1. **可重试中断**：进程不在 / Binder 尸体（沿用 `kEngineInterruptCodes` 口径）；
2. **终态 + 真实原因**：经 `getLoadError()` 查询面取回（新增，承接 P2-14——`assetMissing` 序数不再承载受理/终态两义）。

### 2.3 接缝混沌钉子（配套回归面）

把已实证的 7 类契约事故固化为 `:engine` 生命周期混沌测试矩阵：`kill × rebind × evict × reload` 组合脚本（真机 adb 驱动），断言投影一致性 + 游标/fd 契约。JVM 单测测不到的跨进程不变量在此收口。

## 3. 实施切分（Expand-Contract 三步）

| 步 | 内容 | 契约动作 |
|---|---|---|
| 第一步 Expand | `:engine` 新增 `onLifecycleChanged(state, gen)` 事件与 `getLoadError()` 查询面；旧 `checkStatus`/`loadState` 原样保留，Dart 侧双读对账（影子期） | 纯新增，AIDL 序数不动 |
| 第二步 Migrate | Dart `_loadState` 与 bridge 句柄改由事件流驱动；`enable/generate` 决策改走 `ensure` 自愈入口；对账日志收敛零漂移 | 消费侧切换，双源并存 |
| 第三步 Contract | 移除 `checkStatus` 轮询面与 Dart 本地 ready 判定，序数表收敛为终态语义（P2-14 同轮销账） | 破坏性收口，单 commit |

## 4. 非目标

- 不改数据面传输语义（UDS socketpair 成帧/EOS/死锁口径，归 S3-7 既有口径；状态机只观测「数据面死/活」信号）；
- 不改熔断分级与环境对抗策略（B 工作流域）；
- 不动 Genie 管线内部（geniex AAR 黑盒边界不变）。

## 5. 验收

1. 混沌矩阵全组合通过且投影零漂移（对账日志为证）；
2. 11 起事故中的状态机类（7/9/10/受理态类）在矩阵中均有对应复现用例且新架构下不复发；
3. `checkStatus` 移除后全量测试与真机回归全绿。
