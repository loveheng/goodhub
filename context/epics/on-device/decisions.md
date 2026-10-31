---
dev-loop: decisions
format: v1
epic: on-device
total-merged: 0
last-merge: none
---

# on-device · decisions

### [2026-10-31] 会话一致性设计评审：四类隐患裁定 + 五项裁决（src: 外部评审 + ai）
- **场景/痛点**：`docs/design/on-device-lifecycle-single-source.md` v2 出稿后收到外部深度评审——四类工程盲点（在途生成 vs 驱逐重入、epoch 持久化弱点、Binder 死亡时隙、装载惊群）+ 五项裁决建议。需逐条裁定（含**不采纳项**），避免"评审意见全盘照收"把既有实证决策冲掉。
- **逐条裁定（含否决理由）**：
  1. **在途 vs 驱逐**：**否决新增 `DRAINING` 缓冲态**——实证 `EngineLifecycle.onTtlElapsed` 仅 `WARM_STANDBY` 生效，在途（ACTIVE）本就不被 TTL 打断；而 `onTrimMemory`/护栏击穿/主动 `release` 在 ACTIVE 照常驱逐是**有意设计**（内存水位优先于本轮产出）。评审自身在裁决 2 强调"端侧最宝贵的是瞬时内存水位"，DRAINING 与之自相矛盾。**改采纳其真实内核**：`onEngineEvicted` 携带在途信息，Dart 侧以 `SESSION_ABORTED_BY_EVICTION` 规范化收口（当前靠数据面 EOF 间接收口，被混同为"引擎死亡"，丢归因也误导切云/重试决策）。立不变量 I6：投影作废不中断在途流。
  2. **epoch 单调**：**采纳"进程实例标识 + 实例内序号"复合键，去磁盘持久化**（LMK 强杀下页缓存不可信、`fsync` 不现实，持久化单调是伪保证）。**修正**：`instanceId` 用进程启动时生成的 **UUID**——评审建议的 `elapsedRealtimeNanos` 重启归零存在碰撞可能，pid 可复用，二者均不如 UUID 干净。
  3. **Binder 死亡时隙**：**采纳强制作废**（禁止以旧票据原地重试），并**扩大范围**：generate 路径撞 `engine_binder_error`/`DeadObject` 现状落 `StateError` → 上层"显式报错不切云"，而通道中断属可自愈中断，应走切云完成本轮（M3 修正）；同族风险 **进程冻结（假死，无 `DeadObject`）** 需控制面调用**有界超时**，否则同步 AIDL 挂死 = ANR（当前无该面）。
  4. **装载惊群**：**采纳为不变量 I7**（Dart 侧 `_loadTask` 单飞已具形态，去重键从"有无在途"收敛为目标 `modelId`；`:engine` 侧 `beginLoad` 幂等作第二道闸）。
  5. **裁决 1~5**：epoch 复合键（采纳+修正）/ 换模型立即 `release`（**采纳**，并升为不变量"装载提交前必须完成旧会话释放"；**副作用必须写明**：`:engine` 单例纪律使换模型必然走一次冷重载，换来的是内存水位而非秒级换模型）/ 追加 `loading` 序数（采纳）/ 数据面随 epoch 重建（采纳）/ 等待时长（**部分采纳**：分档仍掩盖装载死锁，改为**装载进度活体打点优先** + meta 可声明 `loadTimeoutSec` 上界 + 默认 90s，与云端流"字节活体+自适应预算"范式同构）。
- **AI 洞察**：评审把"驱逐"当成单一动作，实际 `:engine` 已按触发源分了两种语义——TTL 温和（在途豁免）与护栏/trim/release 强硬（在途照杀）。一致性设计**不能抹平这个区分**：为一致性引入 drain，等于用一致性换掉内存水位，把已实证的取舍推翻。真正缺的不是新状态，是强硬路径上的**规范化中止信号**。另补评审未覆盖的同族边界：控制面 `startGenerate` 把整个 `promptJson` 走 Binder 事务（上限为系统共享缓冲区），长上下文有 `TransactionTooLargeException` 风险。
- **收敛条件**：M3 落地须验证「通道异常 → 切云」与「控制面有界超时」两条；若真机出现"护栏驱逐打断在途且用户可见半截输出"，重评是否引入**受限** drain（仅 WARM 档、仅剩余时长可预估的生成），回本 ADR 再裁。

### [2026-10-31] 运行时选择升级一等工厂能力（D2，兑现 ADR① 收敛条件）(src: user + ai)
- **场景/痛点**：用户要求把运行时做成工厂模式三选一（GenieX-QAIRT / GenieX-llama.cpp / llama.cpp 纯）。现状运行时选择是 `GenieSession.doLoad` 内部反应式 if/else（按资产布局推断主路+兜底）。继续堆 doLoad 触发 solution-admission 否决信号 #1/#3/#4/#6（跨模块传参、三路分支+兜底组合爆炸、AIDL 契约必改、特殊性注释堆积）→ 判 **S2**；且 ADR① 收敛条件「引入第三运行时或 UI 暴露 activeRuntime 时升级 factory」两触发同时命中。
- **可选方案（含否决理由）**：① 第三路处置：**骨架+扩展点（采纳，用户拍板）** vs 本轮真集成纯 llama.cpp（否决：无实现载体，需新 JNI/llama-server 集成工程，与 GenieX-llama.cpp 能力重叠，且其独立价值恰是真机 spike 要实证的）vs UI 三选项映射两实现（否决：选择面名不副实）；② 失败语义：**报错不兜底（采纳，用户拍板）**——显式选择被尊重、归因清晰，兜底语义只保留给 auto（布局推断）模式 vs 仍自动兜底（否决：选择被静默覆盖）；③ 选择粒度：**每模型 meta（采纳，用户拍板）**（`.asset-meta.json` 记 `runtime`，导入时按资产布局预填可改；auto 为缺省值仍在）vs 全局设置（否决：选 QAIRT 却导 GGUF 必冲突）vs 双层（否决：多一层对账成本）。
- **最终决定**：Kotlin 侧立 `RuntimeBackend` 接口（tryBuild/query/close）+ `QairtBackend`（qairt 插件+NPU，需 genie_config 三件套）/ `GenieXLlamaCppBackend`（llama_cpp 插件，GGUF，NPU 主+CPU 兜）两实现 + `PlainLlamaCppBackend` **扩展点留位不实现**；`RuntimeBackendFactory.resolve(mode, assetLayout)` 含「模式↔资产」匹配校验（显式 QAIRT + 纯 GGUF 资产 → 直接报错）；`mode=auto`（缺省）= 现行反应式布局推断 + 兜底；显式选择 build 失败 → **显式报错收口云端，不兜底**；运行时选项经模型 meta（`runtime` 字段已存在）→ AIDL 传参 → 工厂。**接缝契约**：AIDL 加参数须同轮修 goodshare 仓 `ai-app-split.md` + `ai-dev-spec.md` §4（立法源）。
- **AI 洞察**：工厂的价值不在三条路本身，而在把「模式↔资产↔兜底」的纠缠从装载核心里解耦——显式/auto 双语义分离后，兜底组合不再随运行时数量爆炸。第三路是否真集成由 spike 数据裁决（若 GenieX 包装层采样/模板可控则纯 llama.cpp 无独立价值）。
- **收敛条件**：PlainLlamaCppBackend 扩展点被第二次引用（如 PC 侧复用、或 spike 证明 GenieX 包装层不可控）→ 真集成；AIDL 参数演化出第三维度 → 工厂参数改 bundle 化。

### [2026-10-31] 多模型导入制：注册表落点与校验分层（评估拍板）(src: user + ai)
- **场景/痛点**：llama.cpp 运行时纳入后资产面分裂（qairt 专属 bundle：genie_config.json+tokenizer.json+metadata.json+HTP 分片 vs 通用 .gguf），可用模型从固定两个变任意 GGUF。现状导入通道强挂 `kOnDeviceModelCatalog` 固定双档位（`_dirOf(model)` 目录取自目录项）+ `expectedTotalBytes ±20%` 档位体积对账；**阻塞性缺口**：`GenieSession.doLoad` 在运行时选择之前无条件检查 genie_config.json/tokenizer.json，GGUF-only 模型会被挡在 llama_cpp 兜底之前（loadError→云端，NPU 兜底走不到）。
- **可选方案（含否决理由）**：① 身份落点：磁盘扫描注册表（**采纳**，用户拍板）vs 常量 catalog 动态 append（**否决**：身份双源，常量+导入两处对账是持续债）；② 装载验证：导入完成页「验证装载」手动按钮（**采纳**，用户拍板）vs 导入后自动试装载（**否决**：突吃 2~3GB 内存，与懒加载/内存门禁时序冲突）vs 不验证（**否决**：坏模型可能隔很久才发现跑不了）；③ 校验深度：仅导入期做完整校验（**否决**：等价于装载）。
- **最终决定**：① 模型身份 = `models/` 磁盘扫描 + `.asset-meta.json`（meta 增 `runtime`(qairt/llama_cpp/auto) + `displayName`）；② 导入解耦固定档位——±20% 档位对账退役（职责由防 LMK 转交），改「按设备 RAM 的体积上限 + 导入期结构校验」；③ 校验分层：导入期结构校验（必备文件按 runtime 在位 / GGUF 头魔数 / tokenizer.json 可解析 / 尺寸上下界 / 磁盘门禁）= **预过滤**，**最终校验 = 装载期 `LlmWrapper.build()`**（不可前移），导入完成页提供手动「验证装载」；④ `doLoad` 资产检查运行时条件化（genie_config.json 在场 → qairt 主路；仅 .gguf → 直 llama_cpp，跳过必败尝试）；⑤ **前置 spike**：llama_cpp 资产布局（model_path 指向 .gguf 还是目录 / 是否需独立 tokenizer / ChatML 模板来源）真机实证后冻结导入校验清单。
- **AI 洞察**：结构校验只能证明「文件像模型资产」，证明不了「HTP 能编译该图 / llama.cpp 支持该架构」——最终裁定天然在装载期，导入期校验的价值是 fail-fast 省 3GB 垃圾拷贝与防半份资产被装载（staging+原子替换纪律保留）。档位对账的防 LMK 职责由 RAM 体积上限承接（内存护栏仍管运行时）。
- **收敛条件**：spike 实证与假设冲突（如 llama_cpp 需独立 tokenizer 文件或模板资产）→ 导入校验清单回本 ADR 修订后再施工。

### [2026-10-31] 会话一致性：事件复位补丁 → 会话票据代次对账（S2 结构性方案）(src: user + ai)
- **场景/痛点**：真机（2026-10-31）端侧请求恒撞 `startGenerate rejected: genie session not ready (loadError=null)`——主进程 `_loadState` 持 ready 而 `:engine` 侧会话未装载，混合引擎「ready 即跳过 enable」短路使本轮未装载就生成；现场触发面 = 设置页删除模型 → 重导入 → 立刻提问（资产换了，会话身份无判据）。用户裁决：**不要继续打地鼠，要一套完整方案**。
- **准入判定（solution-admission）**：**S2 能力补丁，禁止用补丁糊**——六条信号逐条核对：#1 命中（需跨模块传 `modelId`/`epoch`）、#2 命中（同一「复位」处理已写第 2、3 处：`onEngineEvicted` / `_onProcessDied` / `start_rejected`）、#3 命中（`enable` 的 ready/no-op 双路分支）、#4 命中（AIDL 公共接口签名必改）、#6 命中（每处都需注释解释特殊性）。同一位置第三次补丁亦触发 ascan 强制重构阈值。
- **可选方案（含否决理由）**：
  - A) 会话票据 + 代次对账（**采纳**）：`:engine` 签发 `SessionTicket{epoch, status, modelId, runtime}`，主进程只持「最近见证的票据」，失效 = 作废（未知）而非猜测复位，生成入口带 `expectEpoch` 原子判定；
  - B) 继续逐事件补复位（**否决**：补丁数随失效路径线性增长，未预见的失效路径永远漏；且纯 Dart 无法构造 ready 态 → 无回归钉）；
  - C) 每次请求前无条件 `checkStatus`（**否决**：先查后发 = TOCTOU，与 §6.6 原子抢占纪律冲突；查完到发之间被驱逐即失败）；
  - D) 每次请求都重装（**否决**：2GB 权重 + ~2.7s 暖机，不可接受）。
- **评估三问**：① 正确落点 = `:engine`（唯一掌握执行真相）+ 资产面（唯一掌握资产身份），主进程只允许持镜像——补丁落在「让投影猜真相」是落点错误；② 影响面 = AIDL 契约、`EngineService`/`EngineLifecycle`、`AidlOnDeviceEngine`（`enable`/`_loadState`/`generate`）、`HybridCloudEngine` 端侧分支、`OnDeviceAssetManager`（`modelId`）、`EngineServiceBridge`、聊天页装载指示与设置页资产变更路径、新增镜像单测；③ 三次成本：结构性方案首次大（M1–M4 四步），之后每新增一类失效路径成本 ≈ 0（失效矩阵自动覆盖）；补丁方案首次小，之后每路径一处补丁 + 一处特殊性注释 + 无钉，第三次即触发强制重构。
- **最终决定**：按 `docs/design/on-device-lifecycle-single-source.md`（v2 修订，本轮升级为完整方案）分四步落地——M1 Expand（票据面 + 影子对账）→ M2 Migrate（`SessionMirror` 切换 + 事件改作废 + 资产身份 + UI 派生）→ M3 Atomic（`startGenerate` 带 `expectEpoch`）→ M4 Contract（移除 `checkStatus` 与本地 ready 判定）。**当前两处复位补钉保留并标 PATCH**（进程死亡 / 会话未就绪），正解与重构条件写入标记行。AIDL 为本仓内部契约，不涉及 goodshare 接缝。
- **AI 洞察**：补丁的形态不是「改得少」，而是「每类失效都要再来一次」——本轮的根本转变是把投影语义从「我知道现在是什么态」改为「我不再声称知道」，未预见的失效路径由此自动覆盖；资产身份入票据则把「换模型」这类与生命周期无关的一致性也纳入同一机制，无需第四处补丁。
- **收敛条件**：M2 落地即删两处 PATCH 标记；若 M1 影子对账出现投影与权威状态漂移 > 0，`epoch` 单调保证（待裁决 1）须升为强持久化方案并重评。

### [2026-10-31] NPU 兜底：GenieX llama.cpp 运行时纳入（S2 结构性方案）(src: user + ai)
- **场景/痛点**：`geniex-android` 0.3.5 AAR 捆绑**两个** runtime 插件（`libgeniex_plugin_qairt.so`=NPU/HTP、`libgeniex_plugin_llama_cpp.so`=CPU/GPU，均已在 APK debug+release 内），但 `:engine` 的 `GenieSession.doLoad` 只接线 `QAIRT+NPU`。D1 产品决策原口径「NPU 不可用直接收口纯云端、非 CPU 跑大模型」——高端 NPU 设备一旦 NPU 驱动失败（driver panic / HTP init 失败），本轮端侧能力硬断、无端侧兜底，只能切云（隐私/时延/配额代价）。
- **可选方案（含否决理由）**：
  - A) QAIRT 加载失败 → llama_cpp CPU/GPU 兜底（**采纳**）——同份 GGUF 资产 + tokenizer，两插件 AAR 已捆绑，改动收敛 `:engine` 后端单点。
  - B) 驱动/热/OOM 三者全兜底 CPU（**否决**：热→CPU 违反已锁定「禁 CPU 分流」决策——CPU 能效差 5~10×、分流加剧发热；OOM→CPU 权重全驻 DRAM 反向，内存压力最大时最雪上加霜）。
  - C) 不做 CPU 维持纯云端（**否决**：NPU 驱动失败成为端侧硬断点，本轮无端侧兜底）。
  - D) 扩到中低端设备跑 CPU（**否决**：属推翻 D1a 设备分档的独立决策项，超出本轮「NPU 兜底」范围）。
- **最终决定**：`GenieSession.doLoad` 以 `QAIRT+NPU` 为主路；**仅 QAIRT build 失败（NPU 驱动/HTP 不可用）时回落 `llama_cpp+CPU`** 完成本会话（同资产 + tokenizer）；`activeRuntime` 落 `:engine` 日志供可观测。**热/OOM 不触发兜底**——仍经既有决策收口云端。Dart 路由层（`HybridCloudEngine`/AIDL/`checkStatus`）**不动**，保持运行时无关。**D1a 设备分档不变**（中低端仍直收纯云端）；仅推翻 D1「无 CPU 跑大模型兜底」条款，且限定为高端 NPU 设备的「QAIRT 加载/驱动失败」情形。
- **AI 洞察**：① 运行时选择归 `:engine` 后端层而非 Dart 路由——路由层只知 ready/not-ready，兜底落 `doLoad` 是单点责任；② 兜底是**反应式**（装载期 QAIRT 失败）而非预测式（probe 期选路）——probe 期无法预知 NPU 装载会失败，反应式是唯一正确落点；③ 设计原已规定 `OnDeviceEngineFactory.resolve()` 作主运行时选择但代码未建——本轮为「兜底」能力的**最小闭环**，factory（主运行时选择）留 P1-B NeuroPilot；④ `activeRuntime` 现仅 `:engine` 日志，UI 暴露（「端侧（CPU 兜底）」）需 AIDL 变更，留后续。
- **收敛条件**：引入第三运行时（P1-B NeuroPilot / 联发科）或需将 `activeRuntime` 暴露到 UI（须 AIDL 变更）→ 升级为一等「运行时选择」能力（`OnDeviceEngineFactory.resolve()` + AIDL runtime 字段），回本 ADR 重评。
