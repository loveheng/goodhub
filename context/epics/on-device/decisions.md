---
dev-loop: decisions
format: v1
epic: on-device
total-merged: 0
last-merge: none
---

# on-device · decisions

### [2026-10-31] 空闲驱逐后恢复链路断裂 + 端侧运行零感知：三缺口修复（src: user 报告 + ai 评估）
- **场景/痛点**：用户报告「启用端侧后初次可用，过段时间端侧不可用，App 内对端侧运行完全无感知」。评估定谳三根因：① `:engine` 拒绝同进程重载（loadedOnce 单进程单装载纪律）复用 `assetMissing` 终态序数捎带「进程将自杀重启装载」→ Dart 按终态「模型未导入」判死且误导重下，重载链路实际已断；② `EngineServiceBridge.bind()` 幂等判据 = `connection != null`（发起过绑定），进程死亡后 engine 置 null 而连接对象保留 → bind() 永久 no-op，恢复只剩 AMS 自动重启一条腿（其退避可达 ~11min）；③ `OnDeviceLoadState.loading` 全仓无人写入（UI「⏳ 端侧模型加载中…」为死代码），驱逐静默复位 unloaded 零提示——端侧「何时在跑/何时失效/下次为何变慢」全程不可见。
- **最终决定**：① `EngineStatus.reloading`（序数 8，末尾追加，双端同轮锚定）专用信号，Dart 按可重试中断走后台重试（短退避 600ms/1500ms 分档：等自杀落地 / 密询冷启动就绪）；重启窗口内 `not_bound`/连接超时不计入快死棘轮（`expectRestart` 标志防「有意自杀」被误判 LMK 快死把起跑水位抬到 5GB 反堵重载）。② 桥面幂等判据改「活引擎在位」（`engine != null`），断连即时重发 bindService，连接对象缓存复用（同一 ServiceConnection 不产生第二套回调）。③ 装载任务起跑即置 `loading`；AppBar 常驻端侧状态芯片（就绪/重载中/已释放/不可用，ListenableBuilder 自管重建）+ 驱逐/失败转场瞬态提示；装载在途时进程死亡不复位 loadState（防「装载中」指示被打断成「未启用」）。
- **AI 洞察**：P0-3 驱逐上行链路本身是通的（复位语义正确）——故障不在「知道被驱逐」，在「驱逐之后接不回来」。三缺口是同一事故的三个剖面：恢复语义错误（报错面）+ 重绑缺失（机制面）+ 感知缺失（观测面），单修任何一个都只会换个姿势复发。
- **收敛条件**：真机复测「启用端侧 → 空闲 5min+ → 再提问」应自动重载完成本轮（AppBar 显示「端侧重载中…」），不再出现「请重新导入模型」；混沌矩阵 `kill × rebind × evict × reload` 回归（§6 验收 1）覆盖本路径。P2-14 的 `getLoadError` 查询面（终态归因细化）仍开放，与本轮正交。

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
- **最终决定**（⚠ **已被同日 GPU 档 ADR 推翻**：CPU 兜底全量退役，见下条）：`GenieSession.doLoad` 以 `QAIRT+NPU` 为主路；**仅 QAIRT build 失败（NPU 驱动/HTP 不可用）时回落 `llama_cpp+CPU`** 完成本会话（同资产 + tokenizer）；`activeRuntime` 落 `:engine` 日志供可观测。**热/OOM 不触发兜底**——仍经既有决策收口云端。Dart 路由层（`HybridCloudEngine`/AIDL/`checkStatus`）**不动**，保持运行时无关。**D1a 设备分档不变**（中低端仍直收纯云端）；仅推翻 D1「无 CPU 跑大模型兜底」条款，且限定为高端 NPU 设备的「QAIRT 加载/驱动失败」情形。
- **AI 洞察**：① 运行时选择归 `:engine` 后端层而非 Dart 路由——路由层只知 ready/not-ready，兜底落 `doLoad` 是单点责任；② 兜底是**反应式**（装载期 QAIRT 失败）而非预测式（probe 期选路）——probe 期无法预知 NPU 装载会失败，反应式是唯一正确落点；③ 设计原已规定 `OnDeviceEngineFactory.resolve()` 作主运行时选择但代码未建——本轮为「兜底」能力的**最小闭环**，factory（主运行时选择）留 P1-B NeuroPilot；④ `activeRuntime` 现仅 `:engine` 日志，UI 暴露（「端侧（CPU 兜底）」）需 AIDL 变更，留后续。
- **收敛条件**：引入第三运行时（P1-B NeuroPilot / 联发科）或需将 `activeRuntime` 暴露到 UI（须 AIDL 变更）→ 升级为一等「运行时选择」能力（`OnDeviceEngineFactory.resolve()` + AIDL runtime 字段），回本 ADR 重评。

### [2026-10-31] GPU 档落地 + CPU 全量退役：运行时阶梯收口为「NPU → GPU → 终态」(src: user + ai)
- **场景/痛点**：同日「NPU 兜底」ADR 落地后复盘——① CPU 兜底（`llama_cpp+CPU`）两处契约均挂 UNCERTAIN 未真机实证（model_path/tokenizer_path 假设、输入形态猜测），属未验证即发货；② CPU 能效差 5~10×、2GB 权重全驻 DRAM，热降频不可持续（「不够长久」），兜底路径真实价值趋零；③ 纯 GGUF 资产走 `llama_cpp+NPU` 契约同样未实证，且 NPU 档绑定逐 SoC 预编译 ctx-bin，模型池被 AI Hub 预编译列表锁死——用户目标「可用模型多一些」与此反向。
- **可选方案（含否决理由）**：
  - A) 维持 NPU→CPU 兜底（**否决**：未实证代码 + 能效硬伤，见痛点）。
  - B) 阶梯收口为「qairt bundle→QAIRT+NPU 终态 / 纯 GGUF→llama_cpp+GPU 终态」，CPU 全量退役（**采纳**）：GPU（Adreno/Mali 通用 Vulkan/OpenCL）是任意 GGUF 即导入即用的唯一通路，非高通设备唯一档；`ComputeUnitValue` 枚举 GPU 档实证在座（AAR 反编译 CPU/GPU/NPU/HYBRID）。
  - C) 连 llama_cpp 运行时一并砍掉、qairt 单运行时（**否决**：砍掉纯 GGUF 导入制，模型池收窄，与目标反向——留待后续仅发 qairt bundle 形态时再评）。
  - D) LiteRT-LM / MNN-LLM 作非高通档主力（**否决**：`.litertlm`/`.mnn` 资产格式分裂模型池；MNN 需逐模型转换、MTK GPU 稳定性坑未清；均挂观察名单）。
- **最终决定**：① `GenieSession.doLoad` 阶梯化——qairt bundle → `QAIRT+NPU`（build 失败 = 终态收口云端）；纯 GGUF → `llama_cpp+GPU`（build 失败 = 终态）；两处 CPU 兜底分支删除；② 热/OOM 一律经既有决策收口云端（既有「禁 CPU 分流」收严为「CPU 档不存在」）；③ Dart 侧 `OnDeviceRuntime.llamaCpp` 口径同步为 GPU 档，AIDL/票据/路由零改动（runtime 仅诊断归因）；④ GPU 契约（`compute_unit=GPU` 实际后端 Vulkan/OpenCL + GGUF 输入形态）挂 UNCERTAIN，spike 与既有 #1 同次 Ace 6 真机裁定。
- **AI 洞察**：模型池宽窄的根因是**资产形态与 SoC 的耦合度**——ctx-bin 逐 SoC 编译 = 池锁死，GGUF+GPU 通用通路 = 池放开；砍掉低价值兜底分支（CPU）同时删掉两处 UNCERTAIN，是减法换确定性的典型收益。非高通不选 NeuroPilot（NDA + DLA 资产不通）、LiteRT-LM/MNN（格式分裂）的裁定一并留档。
- **收敛条件**：Ace 6 真机 spike 裁定 GPU 契约（归因日志确认后端与 GGUF 输入形态）→ 删 UNCERTAIN；混沌矩阵补「GGUF 资产 GPU 装载」用例；P1-B NeuroPilot / LiteRT-LM NPU 抽象触发条件不变（GPU 档吞吐实测不达标时回评）。

### [2026-10-31] 数据面唯一真相源：废弃 SDK 文本回调，锁定 token-id + GHDT（#三 UTF-8 治本）(src: user + ai)
- **场景/痛点**：当前存在两条并行解码路径——Kotlin `StreamTextSanitizer` 修 SDK `gen` 文本回调（SDK 内部 detokenize 按单字节解码把"中"拆成 `ä¸­`），以及 Dart `StreamingDetokenizer`（token-id + GHDT 表自重组、坏字节重建解码器，自承治标）。两端各打一层补丁且互不知对方擦什么屁股；更关键：若生产走 SDK 吐文本路径，腐化已发生在 SDK 内部 detokenize、早于任何 App 能拿到的字节，下游任何补丁都接不住。
- **可选方案（含否决理由）**：
  - A) 锁定 token-id + GHDT 离线表为唯一合法生产链路（**采纳**）：在 `libgdw` 原生 Worker 内完成 `id -> bytes -> UTF-8 滑动窗口` 原子组装，多字节序列未凑齐则滞留在 RingBuffer 绝不向上抛，只向 Dart 吐出保证合法的 String。App 掌控 detokenization，源头字节级腐化被消灭。
  - B) 保留 SDK 文本回调 + Kotlin `StreamTextSanitizer` 修字节（**否决**）：腐化发生在 SDK 内部 decode→text 边界，App 侧拿到的已是拆坏的 String，修复是事后拼凑、半截字节拼不出必丢字符；且无法保证跨 token 边界合法。
  - C) Dart `StreamingDetokenizer` 作为唯一源（**否决**）：Dart 侧仍感知裸字节、坏字节重建解码器是治标自承；UTF-8 变长状态机应下沉原生单点，Dart 只收 String。
- **最终决定**：① 彻底废弃 Kotlin `StreamTextSanitizer` 及其基于 SDK 文本回调的整条路径；② 锁定 `token-id + GHDT 离线表` 为唯一合法生产链路，GHDT 表随 `model.bin` 同源 OTA 下发（已既定）；③ `id -> bytes -> UTF-8 滑动窗口` 原子组装下沉 `libgdw` 原生 Worker，未完成字符滞留 RingBuffer 绝不外抛；④ Dart `StreamingDetokenizer` 退役，Dart 侧 EventChannel/Stream 只接收合法 String。
- **AI 洞察**：UTF-8 合法性的唯一正确落点是"掌控 detokenization 的那一层"——既然 SDK 内部 detokenize 不可信，就必须绕开它（token-id 旁路），而非在它的输出上打补丁。token-id 路径本就存在（GHDT 表已下发），废弃文本路径是收口而非新增能力。
- **收敛条件**：确认生产路径确已全量切到 token-id（无残留走 `gen` 文本回调的请求）；`libgdw` RingBuffer 实现需单测覆盖"跨帧多字节滞留 + 完整字符才外抛"；退役 `StreamTextSanitizer` 后其单测一并移除。

### [2026-10-31] 死因可见性：LMK 墓碑机制（排除法裁定 SIGKILL，#五 指纹分类前置）(src: user + ai)
- **场景/痛点**：系统 LMK 发出的是**不可捕获的 SIGKILL**，进程死因对 App 不可见，导致 `kEngineInterruptCodes` 的软故障（LMK_SIGKILL / ION_OOM）与硬故障（驱动崩溃）长期靠 `livedMs < 30000` 推断 fastKill，启发式本身残留、分类不准。指纹退火熔断要区分软/硬故障，前提是死因可被确定性裁定。
- **可选方案（含否决理由）**：
  - A) 墓碑 + 排除法（**采纳**）：`:engine` 启动写 PID 命名状态标记文件（`FLAG_LOADING`/`FLAG_READY`）；JNI 注册可截获信号处理器（SIGSEGV/SIGABRT/SIGBUS 落盘 Crash Stack）；主进程 `DeathRecipient` 触发时——有 Stack → 驱动/SDK 硬崩溃；无 Stack 且状态 `FLAG_LOADING` + 整机可用内存低 → **100% 裁定 LMK_SIGKILL**，不再靠猜。
  - B) 继续 `livedMs < 30000` 推断（**否决**：是概率启发式，无法区分"暖机慢"与"被 LMK"，且快死未必是 OOM）；
  - C) 捕获 SIGKILL 本身（**否决**：SIGKILL 按 POSIX 不可捕获，技术上不可行）。
- **最终决定**：① `:engine` 启动时写 `<pid>.flag` 标记文件，`loadModel` 受理前 `FLAG_LOADING`、SDK `create` 返回后 `FLAG_READY`，进程正常退出时清标记；② JNI 层注册 `sigaction` 捕获 SIGSEGV/SIGABRT/SIGBUS，将 Crash Stack（PC/寄存器/backtrace）落盘到崩溃目录；③ 主进程 `DeathRecipient` 触发后读取 `<deadPid>.flag` 与崩溃目录：有 Stack → `HARD_CRASH`（驱动/SDK 崩溃，归入硬故障）；无 Stack + `FLAG_LOADING` + `ActivityManager` 内存水位低 → `LMK_SIGKILL`（软故障）；无 Stack + `FLAG_READY` → 运行期外部终止（按环境再判）；④ 裁决结果写入结构化死因文件供下次启动分类，替代 `livedMs` 推断。
- **AI 洞察**：SIGKILL 不可捕获，所以"直接观测死因"走不通，只能走"排除法 + 墓碑"——用"有没有 Crash Stack"把硬崩溃与 LMK 切开，再用"死在 FLAG_LOADING 且内存低"把 LMK 钉死。这是把不可观测事件转成可裁决契约的标准手法。注意 flag 文件须用 PID 命名且正常退出清理，否则进程复用 PID 会误判。
- **收敛条件**：真机验证 flag 清理时序（`:engine` 崩溃来不及清 flag 的情况须由主进程死亡时发现 stale flag 处理）；崩溃 Stack 落盘路径须在 `:engine` 独立进程沙箱内可写；与 #五 指纹字典联调——`LMK_SIGKILL`/`HARD_CRASH` 分类须被 `kEngineInterruptCodes` 消费以驱动退火。

### [2026-10-31] [ADR] SessionToken 拒绝引入 pid/sha256 及消费侧前置 Assert（终态架构评审裁定）(src: 用户 + ai)
- **场景/痛点**：终态架构评审提案将票据升级为三元复合体 `{epoch, pid, modelSha256}` 并要求消费侧发起调用前执行「前置原子 Assert」比对，以强收口 S2（modelId 对账只建未用）。
- **可选方案（含否决理由）**：
  - A) 三元 token + Dart 前置 Assert（**否决**，三处）：① pid 可复用（进程重启后旧票据撞新进程），§2.2 立法时已论证弃用；② 对 1.5~3GB 权重全盘 sha256 是运行时 IO 惩罚，I3 的 `modelIdOf`（目录名@meta 指纹前 12 位）零计算成本且身份必变语义等价；③ Dart 侧「先比对后发调用」复活 I4 明令禁止的 TOCTOU——查完到发之间会话仍可被驱逐/换模型；
  - B) expectModelId 进既有 startGenerate 原子比对（**采纳**）：给已落地的 epoch 闸门加一个比对维度（`expectInstanceId, expectSeq, expectModelId`），`:engine` 同一入口原子裁决，失配抛 `SESSION_MODEL_MISMATCH` 新拒绝码，Dart 作废镜像走重装——不是新造 token 格式，是补齐 §2.5 未兑现的一半。
- **最终决定**：① 票据维持 `(instanceId UUID, seq)` 复合键不扩字段，资产身份用 `modelIdOf` meta 指纹，严禁运行时全盘哈希；② S2 修复 = `startGenerate` 原子比对加 `expectModelId` 维度（F2），不在 Dart 侧新增任何判定；③ 大载荷传输（共享内存/fd 解除 Binder 上限）与 2B 模型 KV-Cache 推理窗口（阶梯截断保留）**解耦立法**——1200 字符预算是推理约束非纯传输迁就，通道升级不解锁模型窗口；④ 装载超时由 `:engine` 内部自治裁决（分阶段活体回调 + 阶段硬超时 → 自签 `LOAD_STALLED` 终态票据 → 走 reloading 冷重载自裁），主进程**不新增跨进程 SIGKILL 权**——否则墓碑排除法把有意重启误判为 LMK 快死，`fastKillStreak` 抬水位反堵重载（上轮已修 bug 换姿势复发）；⑤ 原语降级「可自动、不可静默」：failFast/degradeToCloud/degradeToTruncate 三档类型化 + `[DEGRADE]` 标记，熔断双轨隔离（PrimitiveFailureCounter 不污染聊天会话 CircuitBreaker）。
- **AI 洞察**：终态目标与 Expand-Contract 施工不矛盾——前者定义终点，后者是抵达终点的唯一安全路径；评审提案的「意图」全部成立，被否决的是三处「机制落点」：可碰撞键、IO 惩罚型身份、把判定权从唯一主权者手里拿回客户端。
- **收敛条件**：F2 落地后混沌矩阵扩「modelId 失配重装」与「装载停滞 LOAD_STALLED」两用例；`SESSION_MODEL_MISMATCH` 码与既有 `SESSION_EPOCH_MISMATCH`/`SESSION_LOADING` 同走 message 前缀分码管线。

### [2026-10-31] [ADR 修订] G1 手段修订：token-id 直取 → QAIRT Genie C API 直绑（长期方案，弃反编译/边界还原短期路）(src: 用户拍板 + ai)
- **场景/痛点**：G1-3「切 token-id + libgdw 原子组装」的实施前提被证伪——geniex-android 0.3.5 AAR 的 `LlmStreamResult.Token` 输出回调**只吐 `result.text`（已 detokenize 文本），无 token-id 出口**（全仓取证零命中；`inputIds` 仅输入侧）。候选补救中「反编译 AAR 查内部面」被用户否决：内部面无版本契约，SDK 升级即断；「Latin-1 边界还原」自校验方案被判为短期形态，不采纳。
- **可选方案（含否决理由）**：
  - A) 反编译 AAR 内部面直取 token-id（**否决**：无文档契约，版本升级即断链，静默腐化风险回归）；
  - B') Latin-1 字节还原 + 启动自校验探针（**否决**：用户裁定为短期形态——还原依赖 SDK 腐化模式恒为 Latin-1 误读，探针 fail-loud 仍需双管线维护，是妥协不是终态）；
  - C) 绑定 QAIRT Genie C API 直取代 AAR wrapper（**采纳**）：QAIRT SDK 免费可下，Genie C API 为官方文档化契约，版本稳定性由 Qualcomm 版本本契约背书；若其回调暴露 token 级出口，G1 按原 ADR 落地且摆脱 AAR 黑盒。
- **最终决定**：① G1 前置 = **spike：安装 QAIRT SDK（qpm-cli / Qualcomm ID），核查 Genie C API 对话回调的 token 级出口**（头文件实证，不反编译）；② spike 通过 → G1-1/2/3 按「GenieSession 走 C API 绑定层（JNI 新建）、数据面载 token-id + libgdw 原子组装」施工，`StreamTextSanitizer`/Dart 旧解码路径物理退役照原 ADR；③ spike 证伪（C API 亦无 token 级出口）→ **回本 ADR 重裁**（届时候选 = C API 文本回调 + 边界还原降级形态 / 上游 issue 等 SDK 修 detokenize 边界，维持现状为默认）；④ 弃用短期方案是用户主权决策，Latin-1 还原路径不再评估。
- **AI 洞察**：「唯一事实源」的不变量（Dart 只收绝对合法 UTF-8）不变，被推翻的是手段层的可达性假设——ADR 立法时「token-id 路径本就存在」未经代码实证，本轮取证证伪后按裁决链回修手段而非硬切。
- **收敛条件**：spike 结论（C API 回调面核查报告）回填本 ADR；通过则 G1 三子项按 B 路线重排施工，证伪则按 ③ 重裁。

### [2026-10-31] [ADR 终裁] G1 关闭：QAIRT SDK 不安装 + 私有方法不探测 → 维持现状为终态 (src: 用户拍板)
- **场景/痛点**：B 路线（QAIRT Genie C API 直绑）的前置 = 安装 QAIRT SDK 做 spike。用户拍板：**QAIRT SDK 不会装、私有方法不去探测**——B 路线的前置永久不可达，G1「数据面唯一真相源」三子项（废弃 StreamTextSanitizer / 解码器退直通 / token-id+libgdw 组装）按 ③ 预案关闭。
- **可选方案（含否决理由）**：
  - 反编译 / 内部面探测（**否决**：用户裁决——无版本契约 + 不探测私有方法）；
  - Latin-1 边界还原（**已否决**：前轮裁定短期形态，不再评估）；
  - **维持现状（采纳，终态）**：SDK 文本回调（`LlmStreamResult.Token.text`）+ Kotlin `StreamTextSanitizer` 修复 + Dart identity 直通——在「SDK 能力边界」约束下这是可用且实证过的方案（真机 S2-5 全链验证）。
- **最终决定**：① G1-1/2/3 **不实施**，G1 关闭；② 现状件重新定性：`StreamTextSanitizer` 从「补丁自认治标」改为「**SDK 能力边界内的合法方案**」（注释去自贬，留已知局限说明）；③ 唯一后续通道 = **登记上游问题**（geniex-android / Qualcomm：detokenize 按单字节解码拆散 UTF-8 多字节字符的边界缺陷，期望 SDK 输出侧提供 token-id 或修复 detokenize 边界）——SDK 若未来修复，重开 G1 评估；④ UTF-8 腐化的**运行时防线保持现状不撤**（sanitizer + Dart 对账打点），任何下游改动不得绕过。
- **AI 洞察**：「唯一事实源」不变量在 SDK 黑盒约束下无法以 App 侧手段达成——承认约束、把方案定性从「治标」翻转为「边界内终态」，比挂着永远不可达的前置更诚实；上游 issue 是唯一能让约束松动的杠杆。
- **收敛条件**：上游 issue 登记完成；geniex-android 后续版本若暴露 token-id 输出或修复 detokenize 边界 → 重开 G1 评估（回本 ADR）。

### [2026-11-01] [ADR] 端侧多栈推理框架构型：LiteRT-LM 内置底座 + GenieX 增配选装——四裁决 + 联发科通道升格 (src: 用户 + ai)
- **场景/痛点**：用户提出「LiteRT-LM 必装通用底座 + 厂商原生 SDK 选装包（高通先行、联发科留位）」的框架重构，初稿含「GenieX(NPU) 挂死 → 运行期切 LiteRT-LM(QNN) 跨栈兜底」链路。评估发现三处硬约束被忽略：① GGUF 与 `.litertlm` 资产内存镜像完全不互通，运行期跨栈=先卸载 1.5~2GB 再数十秒冷装载，单请求内必超时且冲破内存水门；② AIDL 现契约 `stopTokenIds` 传预编码 id，GGUF（BPE 词表）与 `.litertlm`（SentencePiece/Gemma vocab）词表无关联，跨后端传硬编码 id = 静默乱码或无法截断；③ GenieX AAR 与 LiteRT-LM QNN dispatch 各自捆绑 `libQnnHtp*` 系 QAIRT 库会产生符号冲突 + 数十 MB 冗余。LiteRT-LM NPU 官方事实已核实（Google AI Edge：Qualcomm AI Engine Direct / MediaTek NeuroPilot 双通道，`.litertlm` NPU 资产目录现仅 Gemma3-1B、ctx 1280、按 SoC 分发 SM8550/8650/8750 + MT6989/6991）。与 devlog 同日 npu-geniex-runtime D1 终裁（LiteRT-LM 内置默认 APK + GenieX 拆增配）互相印证。
- **可选方案（含否决理由）**：
  - A) 运行期跨栈横跳兜底（**否决**：资产族不互通，切栈=换模型，1.5~2GB 卸载+冷装载在单请求内不可达；正确落点=资产分发期定栈）；
  - B) 「仅高通」构型（砍掉 LiteRT-LM 底座）（**否决**：底座运行库仅 +10-12MB 且已被 D1 终裁定为内置基线；砍掉后 GenieX 崩溃/熔断/EXCLUDED 时无本地退路直接跳云端，测试矩阵 2 态变 3 态，收益趋零）；
  - C) 停用词维持预编码 id 契约（**否决**：预编码绑定单一 tokenizer，多资产族下跨栈语义错乱，属隐形定式炸弹）；
  - D) LiteRT-LM GPU 实证前直接退役 llama.cpp（**否决**：llama_cpp+GPU 已真机实证 39.3~39.6 tok/s（2026-11-01 拍板基线），未实证先删 = 回退链中段失稳）；
  - E) 中低端借 LiteRT-LM 解禁端侧（**否决**：GPU/CPU 档能效未经中低端实证，D1 设备分档产品决策维持）。
- **最终决定**（四裁决 + 一升格）：
  - **D-1 跨栈横跳剔除，固化为双段路由**：① 资产路由（静态/下载面）= 按机型与资产族定栈，GGUF→GenieX 系、.litertlm→LiteRT-LM 系，二选一下载；② 运行时降级链（同栈内闭环）= GGUF 族 `QAIRT(NPU) → llama_cpp(GPU) → 云端 [DEGRADE]`、.litertlm 族 `LiteRT-LM(NPU) → LiteRT-LM(GPU) → 云端 [DEGRADE]`；CPU 全程出局（禁 CPU 分流不变）；跨栈兜底只发生在资产分发推荐层，禁入推理运行时。
  - **D-2 D1 设备分档维持**：中低端（≤6GB RAM）不对端侧大模型开放，即便 LiteRT-LM 底座具备跨平台能力；`DeviceTierGate` 门禁不变。
  - **D-3 停用词契约重构**：AIDL `stopTokenIds: intArray` → `stopSequences: List<String>` 字符串序列下发，编码判定下沉各 Runner Native 自治（自绑 tokenizer 实时 match）；属接缝契约变更，施工时须同轮修 goodshare 仓 `ai-dev-spec.md` §4（立法源）。关联既有事实：Genie SDK 曾拒收 stop sequences（ErrorCode -100016，deployment §6.7 落位标注），GenieX 现行走 `:engine` 文本截断+sanitize 兜底——重构须覆盖该现状语义，不得回退。
  - **D-4 GPU 档双轨并存（2026-11-01 用户修订：llama.cpp 永久保留）**：已实证 `llama_cpp+GPU`（39 tok/s 基线）与 LiteRT-LM GPU **长期并存，llama.cpp 代码留着不删除**——不设退役条件、不打 PATCH 标记（非权宜，是长期并存架构：llama.cpp 承载 GGUF 通用通路与已实证基线，LiteRT-LM 承载 .litertlm 标准化通路）；LiteRT-LM GPU 真机基准仅作能力对照归档，不触发任何分支删除。
  - **联发科接口留位（2026-11-01 用户修订：现阶段不支持）**：路线认定不变 = `LiteRT-LM + NeuroPilot Delegate` 打 APU（联发科×Google 官方合作，免 GenAI Toolkit 企业 NDA，天玑 9300/9400 已入 .litertlm NPU 支持表）；但**现阶段不支持**——Runner 注册表/接口预留 NeuroPilot 扩展位，不实现、不排期真机实证；P1-B NDA 专项不再阻塞任何路径。重评触发 = 官方 `.litertlm` NPU 资产目录扩展（出 3B 级/多模型）或天玑旗舰真机到位，届时回本 ADR 立项。
  - **首发节奏（2026-11-01 用户修订：llama.cpp 先不放出，从 LiteRT-LM 起步）**：D-4 的「永久保留」指**代码保留**，不指用户面放开——llama.cpp 通路（GGUF 导入/GPU 兜底档）首发**关闸不暴露**：GGUF 导入入口、分发推荐、设置面均不开放（feature flag/编译保留，代码与已实证能力不删）；首发资产路线 = **仅 `.litertlm` 族（LiteRT-LM 栈）**，双段路由的 GGUF 分支降为「在码未启用」。重评触发 = LiteRT-LM 首发稳定运行且 GGUF 资产链（分发/推荐面）就绪，届时按新 ADR 立项放开。
- **AI 洞察**：① 路由的真正维度是「模型资产族」而非「设备装配状态」——构型选择发生在下载面，运行时只做同族降级，这一刀切下去跨栈问题整体消失；② LiteRT-LM 的战略价值不在 GPU 档，而在它是唯一同时打通高通/联发科 NPU 官方通道的标准化运行时（联发科侧且免 NDA）；③ QAIRT 运行库必须单源化（共享一份 runtime 依赖，两栈经 `nativeLibraryDir`/`setQairtRuntimePath` 统一指向），双份捆绑是符号冲突定时炸弹；④ llama.cpp 永久保留后，双栈并存的长期成本 = GGUF 与 .litertlm 两套资产链的维护面，由资产路由 backend 维度单点收敛，不外溢到路由层。
- **收敛条件**：① LiteRT-LM GPU 真机基准完成 → 数据归档作能力对照，**不触发 llama.cpp 删除**（永久并存，llama.cpp 退役需新 ADR 立项）；② `.litertlm` NPU 资产目录扩展出 3B 级模型且高通 SoC 覆盖对齐 → 评估 GenieX 增配包收敛为纯 QAIRT/HTP 加速器；③ 联发科：`.litertlm` NPU 目录扩展或天玑真机到位 → 回本 ADR 立项实证 NeuroPilot Delegate（此前仅接口留位，不排期）；④ D-3 施工时若 Genie 系停用词下沉仍被 SDK 拒收 → 契约按「字符串下发 + 各 Runner 自治实现」双轨评审后落码。

### [2026-11-01] [ADR] LiteRT-LM Runner 集成准入：Runner 抽象 + 资产族单点路由（多栈构型 ADR 施工） (src: ai + 用户拍板多栈构型)
- **场景/痛点**：多栈构型 ADR（同日）「Runner 注册表预留扩展位」需施工落地——首发路线「仅 `.litertlm` 族」当前被 fail-fast 闸挡住（`kOnDeviceLiteRtLmEnabled=false`），Runner 不集成则首发目标不可达。现状 `:engine` 的 `EngineService.session: GenieSession` 硬编码单一推理后端，第二栈接入需结构落点。
- **可选方案（含否决理由）**：
  - A) **Runner 抽象（接口 + 单点路由）（采纳）**：`OnDeviceRunner` 接口为能力槽，GenieSession/LiteRtLmRunner 同构实现，`loadModel` 入口按资产布局单点分派；
  - B) 不抽接口，EngineService 双实例 + if 双路分支（**否决**：信号 #2——消息 JSON 解析要在 LiteRtLmRunner 重写一遍；信号 #3——loadModel/startGenerate/checkSession/releaseEngine 四处双路分支，NeuroPilot 接入时触第 3 次强制重构阈值，未来两次修改各 O(4 处) ≥ A 的 O(1 处)）；
  - C) 两栈两个独立 Service（**否决**：进程级外围防护（单执行槽/epoch 闸/数据面/墓碑/FGS/TTL）须复制一套，破坏「单执行槽 + 策略 B」纪律，属 P0 级结构回退）。
- **solution-admission 判定**：S2 结构性引入（否决信号逐条核对：#1 未命中——选择结果仅存 :engine 实例内，AIDL 契约零改动；#2 命中（若中立解析不抽出）；#3 未命中（注册表分派是单点，非散落双路）；#4 命中（:engine 内类型泛化，属结构引入必然形态）；#5/#6 未命中）→ 结构性方案放行；**非 S3**——双栈并存是多栈 ADR 长期架构（D-4 修订「永久保留」），不打 PATCH 标记、无收敛义务。
- **最终决定**：① 新增 `engine/OnDeviceRunner` 接口（ready/creating/abortRequested/loadError/activeRuntime/lastProfile/beginLoad/doLoad/query/abort/close）+ 公共 `EngineProfile` 类型（TTFT/decodeSpan/tokens/stopReason 归因面，各 Runner 自治填充）；② `ChatMLComposer` 抽 `parseNeutral` 中立解析（消息 JSON → role+content 轮次序列单源，模板渲染归各 Runner 自治：GenieX=SDK applyChatTemplate/ChatML，LiteRT-LM=SDK 原生 bundle 模板）；③ 新增 `engine/LiteRtLmRunner`——Conversation API + messages JSON 角色映射（契约=末轮必为 user，违例显式失败非静默）；backend 阶梯 = NPU（GenieX 增配已装时，`Backend.NPU(nativeLibraryDir)`）→ GPU → loadError 收口云端（CPU 全程出局，不用 `Backend.CPU`）；采样参数真实生效（P1-8 采样面在本栈增量兑现）；停用词复用 `StopSequenceMatcher` 文本流自治（D-3 契约）；④ QAIRT 运行库单源化 = `GenieXRuntime.qnnRuntimeDirOrNull` 共享解析器（`Backend.NPU(nativeLibraryDir)` 与 GenieX `ensureLoaded` 共用同一「已装」判据）——增配未装时 LiteRT-LM 自动 GPU 档，产品语义（增配选装）与工程判据（单源）同构；⑤ `EngineService.session` 改 `OnDeviceRunner` 类型，`loadModel` 入口单点分派（注册表扩展位 = NeuroPilot，ADR 接口留位）；⑥ Dart `kOnDeviceLiteRtLmEnabled` 翻真。AIDL/控制面/数据面/单执行槽/epoch 闸/墓碑/FGS/TTL/两级熔断 = **零改动**（外围防护 Runner 无关，与 2026-10-29 GenieX 换线先例同层：「仅换 :engine 推理后端实现，外围 100% 保留」）。
- **AI 洞察**：① 能力槽分层已被 2026-10-29 GenieX 换线 ADR 立法（「仅换 :engine 推理后端实现，外围 100% 保留」）——多栈 ADR 的「Runner 注册表」是该分层对 N 个 Runner 的推广，非新架构；② 模板归属 Runner（资产原生模板），messages JSON 是 Runner 无关契约——「角色表达归还模板层」原则的第二次落地（第一次 = 2026-10-31 复读环修复）；③ QAIRT 单源化让「增配开关」天然成为 NPU 可用性判据——产品语义与工程判据合一，无需第二个判据源。
- **收敛条件**：非临时补丁（无 PATCH）。未来扩展（NeuroPilot Runner / .litertlm 资产族扩展）按本抽象零结构改动接入；若 Runner 数 ≥3 且公共面不足以承载新栈（如多模态输入面、约束解码面差异）→ 届时重评 Runner 接口面，回本 ADR 立项。
- **UNCERTAIN（真机验证点，验证后回填销项）**：U1 `modelPath` 绝对路径语义（官方样例传 assets 名，绝对路径支持未实证）；U2 SDK NPU 失败语义 = 抛异常 or 静默回落 CPU（CPU 出局红线验证点）；U3 NPU 编译 bundle 可否在 GPU 后端装载（降级链可行性）；U4 MessageCallback 回调线程模型（与 GenieX JNI 回调同构假设）；U5 Conversation 每请求创建的开销（KV 分配成本）。

### [2026-11-06] 降版 0.3.5 + 语义补全准入评估：S3 临时补丁 + 集中收口，升级等价有保障 (src: 用户发起评估, ai 取证)
- **场景/痛点**：geniex-android 0.10.0 llama.cpp 后端退化 9~21×（版本二分锁定 0.3.5→0.8.0 区间，见同日 devlog），但固定 0.3.5 与「总要升上去」的产品方向冲突——用户提出「低版本期补全语义，升级高版本后行为等价」。取证：两版 AAR classes.jar javap 差分 + goodhub 全部 SDK 触点扫描（GenieSession/EngineService/LlmBridge/GenieXNative/ChatMLComposer/LiteRtLmRunner 八文件）。
- **可选方案（含否决理由）**：
  - A 固定 0.3.5 裸降版（**否决**：增配运行库架构依赖 0.10.0-only `setQairtRuntimePath`，裸降 = 架构解绑且无收敛形态）；
  - B 新建版本中立 facade 抽象层（**否决**：SDK 推理触点已天然集中在 GenieSession 一文件，一次切换不值得常设抽象层，YAGNI；且 facade 内若按版本分支即触发否决信号 #3 双路）；
  - C **降版 0.3.5 + 适配集中单 commit + PATCH 标记 + 切换 runbook（采纳）**：API 差异消化在 GenieSession/ChatMLComposer/GenieXNative/build.gradle 四文件，GenieSession 公共契约面（query 签名/状态码/流回调语义）零变化，升级 = 反向 apply + bench 对照重验。
- **最终决定**：方案 C 放行（S3 临时补丁）。升级等价性分三档——①**可等价**（适配即达）：LlmCreateInput.model_name（0.3.5 有缺省）、GenerationConfig.nPast（goodhub 不用）、generateStreamFlow 签名（goodhub 走 config= 命名参数双版同形）、SamplerConfig 三采样参数（双版同形直传）、ProfilingData 消费字段（双版同在）、stopWords（Dart sanitizer 兜底已单源）；②**不可等价/结构性摆动**（升级才恢复，PATCH 标记 + 收敛条件）：setQairtRuntimePath 增配链（0.3.5 无此 API——降版期运行库回 APK 内置，与 2026-11-02 运行库分发终态裁决临时冲突须 ADR 显式记）、增配下载通道停用；③**升级后新获得**（无等价义务）：性能恢复、grammar/tool-call 新语义（Genie 管线当前 -5 拒服务，无影响面）。
- **收敛条件**：上游发布修复版（0.11+ 或 hotfix）→ 立即反向切换 + bench 对照钉（short/long/repeat × NPU/GPU 六例）重验 + NpuFitStore 升版自动重评 + 删 PATCH 标记；**放行前置门 = qairt 主路（QAIRT+NPU bundle）在 0.3.5 的性能补测**（两版未对照，降版可能伤主路——未补测前不得开工）；补测若 qairt 主路 0.3.5 劣于 0.10.0 → 改评估「llama_cpp 插件单插件降版混合栈」形态重评。
  - **前置门结果（2026-11-06 真机补测，已触发转向）**：qairt 主路 0.3.5 **不是性能劣化而是加载硬失败**（`create() error code -100201` / `[STDERR] Could not create context from binary index 0: err 5000`）——0.3.5 AAR 内置旧 QNN HTP 运行库无法加载 2026-10-17 新版 QAIRT 编译的 4 分片 .bin；0.10.0 同 bundle 主路健康（decode 41.34 tok/s / prefill 2479 tok/s）。**整包降版 0.3.5 否决**（打穿 qairt NPU 主路，比 llama_cpp 慢更严重）→ 转评「llama_cpp 单插件/ggml 运行库降版、qairt 栈维持 0.10.0」混合栈形态（约束：插件本体与 ggml 库均内置 AAR，混合栈可行性取决于增配运行库机制能否单独替换 ggml 库而不动 qairt 栈 + 插件本体替换验证）。
  - **路线拍板（2026-11-06 用户选路线 B）**：走「提交上游 issue + 等修复版」，**混合栈降版评估暂缓**（待办保留、不排期）。上游 = github.com/qualcomm/GenieX（issues 活跃，维护者 mengshengwu/zhiyuan8 在积极处理）；issue 稿已打磨为提交就绪形态（含 #1584/#1507 交叉引用 + SM8750 数字差异归因提问）落 `issue-draft-geniex-0.10.0-llamacpp-regression.md`；期间 llama_cpp 档维持现状 5~6 tok/s（qairt 主路不受影响、一直健康）。**重评触发器**：上游回复修复版 → 反向切换 + 六例 bench 对照重验 + NpuFitStore 升版自动重评；或用户改主意回评混合栈。
