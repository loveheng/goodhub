---
status: active
updated: 2026-10-30
---

# 端侧 NPU 最大化部署系统方案（v2 · 移动端 App 落地修订版）

> 状态：active（v2.7 定稿，2026-10-28 开工准入拍板；v2，2026-10-28 依评审修订；叠加 v2.6 工程拍板：Prefix Cache 唯一主路线 / 防 TOCTOU 原子抢占 / 连续分桶 KV / CPU 绑核 / 状态机术语对齐 / 6 深水区盲点补强：OTA 驱动断层·CMA 碎片·Detokenizer 资产·Stop Sequences 下沉·Prefill 分桶·OEM 冻结；v2.7 评审收敛：单 Context 多图打包 / FGS 前台时序 / Prompt 拓扑正规化 / 超长 KV Compaction / 驱动释放冷却 / RingBuffer 写超时）
>
> **v3 路线修订（2026-10-28 用户拍板）：推理内核改用 GenieX Android SDK（Genie/llama.cpp 管线）**——本稿中以下自研实现项由 Genie 内置能力取代，相关章节待 SDK 落位实证后同轮细化修订：§2.4/§3.6 Prefix Cache 分桶与 Prefill 编译（Genie 内置 KV 管理/前缀复用）、§3.5/§4.5 资产格式（**GGUF 取代 HTP 专属 context 二进制**，分发简化）、§6.7 停用词下沉（Genie 原生 stop sequences）、§6.4 Detokenizer（Genie 内置流式回调）。**【收口 2026-11-01，SDK 落位 P1~P6 实证后同轮细化完成】**：上述章节均已加「落位实证」标注——其中 §2.4/§3.6 自研实现由 Genie 内置取代（不适用）、§3.5/§4.5 分发路线改导入制+增配 AAR、§6.7 下沉路线被 SDK 拒收（ErrorCode -100016）、§6.4 G1 数据面终态；各章节以落位标注为准。
> **v3.1 数据面修订（2026-10-30 用户拍板，S3-7）**：§6.1 数据面由 **Ashmem RingBuffer + eventfd/pipe 唤醒整体退役，换 UDS socketpair 流式管道**——唤醒（socket 可读事件）、背压（SO_SNDBUF 满 → 写端阻塞，500ms 有界超时判 IPC_DEADLOCK）、崩溃隔离（对端关闭 → EOF → 判活自愈重建）全部由内核语义承载；无共享游标，P2-10/S2-5 游标错位类问题整体消失。成帧协议 = `[4B 大端 payload_len][payload]`，`len==0` = EOS 流终结帧（每代生成收尾前必发，Dart 收空批即本代流终，跨通道顺序凭据），`read()==0`（EOF）= 数据面死亡。以下 §6.1/§6.3/§6.4 中 RingBuffer/游标/唤醒协议表述为历史设计，**现行实现以 S3-7 落地标注为准**：写端 = `SocketTokenWriter`（:engine，Kotlin），读端 = `libgdw.so`（主进程 native）；句柄 = AIDL `getDataSocketFd():ParcelFileDescriptor`（socketpair 读端，detachFd 移交）。**不变章节**：§6.2 LMK/FGS/OEM 防护、§6.5 两级熔断、§6.6 单执行槽/原子抢占、§4.1 三态状态机。
> **v3.2 路线修订（2026-10-31 用户拍板）：NPU 兜底**——`:engine` 的 `GenieSession.doLoad` 以 `QAIRT+NPU` 为主路，**仅高端 NPU 设备在 QAIRT build 失败（NPU 驱动/HTP 不可用）时回落 `llama_cpp+GPU` 运行时**完成本轮（同份 GGUF 资产 + tokenizer；2026-11-01 GPU 档真机实证 model_path/tokenizer_path 契约与 39.3~39.6 tok/s，CPU 档已全量退役）。**不改「禁 CPU 分流」决策**：§2.1/§5.2「热降频不迁矩阵运算到 CPU」与「Thermal→Cloud SEVERE 全量切云」仍成立（热/OOM 仍收口云端、无 CPU 兜底）；仅「装载期 NPU 不可用（QAIRT build 失败）」的降级链改为「先 CPU 兜底、再切云」。§3.5「不做 CPU 兜底」的总述据此修订（见总纲 v3.2 / decisions.md ADR）。
> 关联：`docs/design/on-device-capability.md`（端侧能力总纲）、`context/epics/on-device/`
> 适用：依 D1，本方案仅针对**高端旗舰**（NPU 可用机型）；中低端收口纯云端。
> 视角修正：v1 偏"芯片原厂 Reference Design"，v2 改为**移动端第三方 App（含 Flutter/Dart）真机落地**视角，修正指标失真、HAL 权限越界、LMK/分发/FFI 盲点。

## 0. 设计目标与前提

- **NPU 不是万能核**：存在算子缺口、动态形状弱、片上缓存小，常态是"NPU 主算 + CPU/GPU 残差"。
- **Decode 是内存带宽瓶颈**：逐 token 算力需求低、权重搬运量大，优化主线是"减搬运 + 提复用 + 权重常驻内存"，不是堆 MAC。
- **热封顶优先于峰值**：持续满速必触发热降频，调度以"不降频下的可持续吞吐"为目标。
- **第三方 App 权限边界（v2 新增）**：本方案是**无系统签名、非 System UID** 的普通应用，不得直连系统级 HAL，须走公共应用层 API 与原厂 SDK 暴露的 QoS 档位。

## 1. 目标应用场景与性能指标

### 1.1 目标场景

| 场景 | 形态 | 计算特征 | NPU 友好度 |
|---|---|---|---|
| App 内会话（P1） | 短提示→长生成 | decode 内存受限，prefill 算力受限 | 高 |
| 端侧摘要/提取 | 中长文档→短输出 | prefill 重、attention 长 | 高 |
| 常驻轻量意图检测 | 小模型、周期唤醒 | 算力小、功耗敏感 | 高（duty-cycle） |
| 离线兜底 | 断网时小模型续答 | 同会话 | 高 |
| 端侧多模态（P2 候选） | 图像编码→文本 | 视觉 encoder 算力受限 | 中 |

### 1.2 性能指标（按上下文长度**分层**，修正 v1 失真）

**关键物理约束（v2 修正）**：旗舰 NPU（骁龙 8 Gen3/Elite、天玑 9300/9400）跑 3B~4B@INT4 的实测 Prefill 约 **200~500 tok/s**；2K ctx 纯 Prefill 通常 **4~8s**。v1 的"2K ctx TTFT≤800ms"要求 Prefill≥2560 tok/s，超出物理极限 5 倍以上，已作废。

| 维度 | 指标 | 目标（旗舰 3B~4B@INT4 量级） | 采集方式 |
|---|---|---|---|
| 延迟·短文本 | TTFT @ **256 ctx** | ≤ 800 ms | 端到端打点 |
| 延迟·长文本 | TTFT @ **2K ctx** | **≤ 5 s**（或引入 Prompt Cache 后压至亚秒级） | 端到端打点 |
| 延迟 | TPOT（decode token） | ≤ 35 ms（≥ 28 tok/s，权重常驻内存前提下） | 端到端打点 |
| 延迟 | p90/p99 尾延迟 | TTFT p99 ≤ 1.5× p50 | 百分位 |
| 利用率 | NPU 有效利用率（prefill） | ≥ 70% peak TOPS | 厂商 profiler |
| 利用率 | NPU 占空比（decode） | ≥ 60% 活跃（非空等数据） | perfetto |
| 带宽 | 权重带宽占用 | INT4 较 INT8 降 ≥ 45%（权重常驻，**不靠闪存搬运**） | roofline |
| 精度 | 量化质量回退 | 困惑度回退 ≤ +2%，下游 ≤ 1pt（**不含 2:4 稀疏**） | 基准集 |
| 内存 | 峰值驻留 RAM | ≤ 设备可用内存 70%；受 LMK 状态机约束（§4.1） | meminfo |
| 功耗 | 单 token 能耗 | ≤ CPU 路径 1/3 | 电量监测仪 |
| 热 | 稳态不降频时长 | ≥ 10 min 持续生成不触顶 | ThermalStatusListener |
| 可靠 | 端侧成功率 | ≥ 99.5%（剩余走云端兜底） | 埋点 |

> 决策取舍：以"decode 体验（TPOT）"优先；长文本 TTFT 接受秒级并引入 **Prompt Cache（前缀缓存）** 作为秒级预填充的必需机制，而非靠堆算力。

> 注（v2.6）：§1.2 内存门禁仅检验**虚拟内存**（`meminfo` / `ActivityManager` 空闲），不反映**物理连续内存（CMA）**可用性——长期开机后的物理碎片可触发内核级 `ENOMEM`，见 §4.9。

## 2. 计算单元协同分工策略

### 2.1 单元职责划分

| 单元 | 职责 | 不参与 |
|---|---|---|
| **NPU** | 全部线性层、QKV 投影、FFN、prefill 主体、GQA group matmul | 动态控制流、采样、分词 |
| **GPU** | 图像/特征预处理、embedding 查表、NPU 不支持算子的定点 fallback | 主 decode（能效低于 NPU） |
| **CPU** | 图编排、argmax/采样、tokenizer、KV 管理、残差算子、NPU 调度宿主 | **大矩阵乘（能效差，严禁作为热降频时的分流目标）** |

> v2 修正（反模式禁令）：**热降频时绝不分流矩阵运算到 CPU**。NPU 的 Tokens/Joule 通常是 CPU 的 5~10 倍，CPU 多核 GEMM 是整机发热/掉电最剧路径；且 NPU↔CPU 频繁同步拷贝会打乱静态图流水，加速升温。正确策略见 §5.2。

### 2.2 图分区（离线编译期）与三段流水

- 离线编译（QNN / NeuroPilot）切图，产出 `(op → 单元)` 映射；维护**算子支持矩阵**（§3.2），缺口算子**改写优先、回退最后**，残差算子集中成独立子图避免打断 NPU 连续执行。
- 单 token decode 三段流水掩盖开销：`CPU 准备/分词/KV 管理 → NPU 当前步 matmul/注意力 → CPU 采样/写 KV`，双缓冲零拷贝重叠。

### 2.3 约束解码落点（NPU 前向 + CPU 采样/Mask，v2.3 澄清）

复用既有 `OnDeviceResultSummarizer` 的「约束解码（Grammars/Regex）」职责，但须明确 `:engine` 进程内职责切分——**NPU 片上不支持动态 Grammars 状态机判断**：

- **NPU**：仅执行前向传播，输出原始 Logits 张量（词表 32000 / 128000 维）。
- **CPU（在 `:engine` 内部 C++ 推理循环）**：① **Token Masking**——用 xgrammar / outlines 状态机将不符合 regex/JSON 语法的 token 概率置 `-∞`；② **Temperature 采样**（或 greedy/beam）→ 产出最终 token id 写入 §6.1 环形缓冲。
- **与 §2.1 的边界**：CPU 此处**只做采样与语法 Mask 的控制流**（tiny 开销），**绝不承接任何 matmul/注意力矩阵运算**；矩阵计算 100% 在 NPU。两者不冲突。

### 2.4 Prefix Cache 实现（KV-Cache 复用，v2.6 确认；**v3 落位实证 2026-11-01**）

> **落位实证（2026-11-01）**：Genie 管线内置 KV-Cache 管理——自研 ION Buffer 槽位固化/DMA 指针维持不适用（Genie 封装）；前缀复用收益观测已入 bench `short-repeat` 用例（§7.1）。Prompt 拓扑正规化与 `truncateContext` 边界仍有效（后者 Kotlin 侧 no-op：Genie 无部分回滚 API，见 §6.4 S3-6 标注）。

移动端 NPU 物理约束下，**Prefix Cache（固定前缀 KV 缓存）是唯一符合静态图约束的 KV 复用路线**；增量 Prefill 不作为本期基线（标记未来探索项）。

- **物理约束**：QNN HTP / NeuroPilot 依赖编译期确定的张量形状与 HTP 块对齐（VTCM/SRAM Stationary 数据流）；动态长短的增量 Prefill 需动态 Reshape 或大量 Padding Bucket，易打乱片上局部内存、致算子编译失败或静默回退。
- **工程实现**：
  - 将高频固定上下文（System Prompt / Agent 指令 / Tool 定义模板）截断对齐到固定分块（**256 / 512 tokens**）；
  - 首次暖机跑完该前缀，将其 KV-Cache 保留在 NPU **ION Buffer 的 `[0, Prefix_Length)` 槽位**；
  - 后续会话生成经 **DMA 维持前缀 KV 指针不动**，推理指针从 `Prefix_Length` 开始写入，免去重复 Prefill 算力，TTFT 不随轮数线性恶化。
- **Prompt 拓扑正规化（v2.7 新增）**：上层业务 Prompt 拼接须遵守固定拓扑——`[绝对静态指令 + Tool 定义] → [时间/地理/动态 Profile 变量] → [会话历史] → [用户最新输入]`。所有动态插值（系统时间、用户位置、短期状态）**严格排在 `Prefix_Length` 偏移之后**；若动态变量落入前 256/512 tokens 的固化区，前缀物理 Hash 每次失配，§2.4 的 Prefix Cache 收益全部作废（每次都重算 Prefill）。该规范由 Prompt 编排层（AgentLoop 模板）统一保证，`OnDeviceEngine.generate()` 不做运行时校验。
- **与 `truncateContext` 关系**：多轮对话分支/回滚（"重新生成/编辑上一条"）经 `truncateContext(keepTokens: n)` 回滚末轮 KV；保留前缀即 `keepTokens ≥ Prefix_Length`。
- **验收边界**：Prefix Cache 为 **P1 标准实现**；增量 Prefill 标记"未来探索项（需 SDK 动态图能力成熟）"，**不纳入本期交付验收**。

## 3. 模型适配与算子支持

### 3.1 量化策略（v2 修正：去掉 2:4 稀疏）

| 对象 | 方案 | 说明 |
|---|---|---|
| 权重 | **AWQ INT4 / W4A16 混合精度**，分组量化 Group Size 32/64/128 | 直接砍半带宽（INT4 vs INT8）；**不叠加 2:4 结构化稀疏**（INT4 后冗余已极低，再剪枝 PPL 剧烈发散，无法守住 +2% 预算） |
| 激活 | INT8 / INT16（逐层校准） | KL 校准，敏感层升 INT16 |
| KV-cache | INT8 | 省显存/带宽，校验 attention 数值范围 |
| 敏感层保留 | 首层 embedding、末层 lm_head、少数敏感线性层 | 保留 FP16/INT8，不做 INT4 |

- 校准与回退预算：量化后须过 §7 精度回归；单点超阈自动升精度（局部带宽上升，可接受）。

### 3.2 算子支持矩阵与回退

| 类别 | 示例 | 处理 |
|---|---|---|
| NPU 原生 | MatMul、Conv、LayerNorm(融合)、GEMM | 入 NPU 子图 |
| NPU 可融合 | RMSNorm、RoPE、SiLU、KV 更新 | 编译器融合为复合核 |
| NPU 缺失/低效 | 动态 gather、控制流、特殊采样 | fallback CPU/GPU |
| 需改写 | 不规则 attention mask | 重写为稠密/分块形式 |

### 3.3 图变换与算子融合

常量折叠 → 融合（Conv+BN+ReLU、RMSNorm+MatMul、RoPE+投影、KV 更新融合）→ transpose/冗余 layout 消除 → 对齐 NPU 张量维度。融合直接减少核启动与中间搬运，是利用率关键杠杆。

### 3.4 模型架构适配

- 优先 **GQA**（减 KV 体积与 attention 计算，带宽友好）。
- 固定上下文上限 + 增长式 KV；超长上下文用滑动窗口/稀疏注意力。
- base 权重常驻，LoRA/adapter 小张量按需挂载。

### 3.5 工具链（v2 修正：联发科改走 NeuroPilot；**v3 落位实证 2026-11-01**）

> **落位实证（2026-11-01）**：高通推理内核 = **geniex-android 0.10.0**（Genie/llama.cpp 管线，Maven Central 公开构件，用户拍板 2026-10-28）——自研 QNN 编译链（qnn-context-binary-generator/Matrix Build）退役；**QAIRT 仅 8 Elite 系（v79/v81）作 HTP 加速后端**，v73/v75 走 llama.cpp 档；运行库分发 = 增配 AAR 运行时下载（`on-device-npu-runtime-split.md`）。下表 QNN SDK/QAIRT 行指该 AAR 内捆绑的 QAIRT 运行时，非独立自研工具链。

| 芯片 | 工具链（v2 基线） | 说明 |
|---|---|---|
| 高通 | **QNN SDK / QAIRT**（HTP 后端 INT4） | 原厂路径，峰值利用率最佳 |
| 联发科天玑 | **MediaTek NeuroPilot（Neuron Runtime / Neuron LLM）** | **v2 修正**：不再依赖 LiteRT/AICore |
| — | ⚠️ NNAPI 已废弃，不作第三方大模型部署基线 | 高版本 Android 停止维护相关 delegate |
| — | ⚠️ Google AICore 仅 Pixel 及极少数合作机型系统级开放，国内 OEM 天玑旗舰不对第三方 App 提供加载任意大模型的 AICore | 故联发科走 NeuroPilot 而非 AICore |

> **资产矩阵（v2.3 关键修正）**：高通 QNN 的 HTP 预编译 context 二进制**跨 HTP 架构版本向下不兼容**——8 Gen2=HTP v73、8 Gen3=HTP v75、8 Elite=HTP v79；**针对 v75 编译的产物无法在 v73/v79 加载**。云端分发键不能仅按 `qualcomm` 路由，必须细化到 **`SOC_CHIP_MODEL` / `HTP_ARCHITECTURE_VERSION`**（如 `llama3_int4_htp_v75.bin` 与 `llama3_int4_htp_v79.bin` 分文件下发）；联发科按天玑具体型号（9300/9400）下发 Neuron 产物，亦不互通。

> **分发粒度拍板（v2.4）**：确认路线 (a) **每 HTP 版本独立编译产物**——客户端由 `CapabilityProbe` 探测本机 HTP 版本**单选下载对应一份（≈1.8GB）**，用户流量与"兼容单一 graph"方案完全一致；云端仅多存数份静态文件（R2/S3 边际成本可忽略），CI/CD **Matrix Build** 统一产出，维护成本可控。因立项前提是"旗舰最大化压榨 NPU 利用率"，(b) 路线损失 10~20% 性能会跌出产品容忍阈值，故不取。

> 决策取舍：各芯片用**原厂 SDK**（保峰值利用率）；3B~4B 级 LLM **常态不做 CPU 兜底**——**v3.2 NPU 兜底修订后：QAIRT build 失败（NPU 驱动/HTP 不可用）时高端 NPU 设备先回落 `llama_cpp+GPU` 运行时完成本轮，兜底再败才收口云端；热/OOM 仍直接收口云端、无 CPU 兜底**（与总纲 D1/降级链一致，见总纲 v3.2 / decisions.md ADR），LiteRT 仅用于百兆级轻量小模型。Dart 抽象接口之上封装"编译产物 + 加载器"，上层 coordinator 不感知芯片差异（与总纲公共服务化一致）。

### 3.6 Prefill 分桶编译（v2.6 新增；**v3 落位实证 2026-11-01：整章自研设计不适用**）

> **落位实证（2026-11-01，SDK 落位后同轮细化）**：Genie 管线内置动态 batch/KV 管理——自研分桶编译、单 Context 多图打包、`SoC × HTP_ver × Bucket` Matrix Build 整章**不适用**（Genie 封装形状管理，资产即 GGUF/QAIRT bundle）。本章保留为 v2 时代 QNN 自研路线历史设计；现行资产/分发口径见 §3.5 落位标注与 `on-device-npu-runtime-split.md`。

§2.4 已确立"Prefix Cache 固化高频前缀"，但**用户每次输入的动态 Prompt 长度不可控**（10~500 tokens），而 NPU 无法执行动态形状的矩阵乘。若将最大上下文（如 2048）作为唯一编译形状，无论输入多短都 Padding 到满长 Prefill，短问答会产生数十倍无效算力，TTFT 从 ~150ms 被拉长到 2s+。

- **分桶编译（Prefill Context Buckets）**：针对"Prefix 之后的可变上下文"离线编译 **3~4 个尺寸 Bucket**（建议 `128 / 256 / 512 / 1024`；超长再补 `2048`）。QNN 图按固定输入维编译，每个 Bucket 产出独立 context 二进制。
- **向上对齐填充**：运行时按"可变长度向上取整到最小覆盖桶"选桶（输入 80→`128`、300→`512`），对齐部分填 Padding Token 并在 Attention Mask 中遮蔽；Prefix 部分始终走 §2.4 固化 KV，不参与本桶 Prefill。
- **资产与驱动联动（重要）**：① 各 Bucket `.bin` 共享同一份权重 blob（QNN 支持权重复用），但**每个 Bucket 的 context 二进制同样强绑定 HTP 版本与驱动指纹**（见 §4.8），分发键须含 `bucket=128|256|512|1024` 维度；② 桶数 × 驱动版本 × SoC 型号 使资产矩阵膨胀，CI **Matrix Build** 须覆盖 `SoC × HTP_ver × Bucket` 笛卡尔积，首跑仅懒下发当前机型最小可用桶集合。
- **单 Context 多图打包（v2.7 修正）**：禁止把 4 个 Bucket 编译为 4 个相互独立的 context 二进制——运行时将生成 4 个独立 Context 句柄，权重重复加载且外部权重共享管理复杂易错。正确路径：经 `qnn-context-binary-generator` 将 `graph_prefill_128/256/512` + `graph_decode` 打包进**同一个 context 二进制**（如 `model_v75.bin`），多子图片上**天然共享同一权重内存池**（QNN HTP `QNN_HTP_CONTEXT_CONFIG_OPTION_WEIGHT_SHARING_ENABLED`，官方支持单 Context ≤64 图）。已核实约束：权重共享仅支持 **x86 Linux 离线 prepare**（ARM/Windows 在线 prepare 不支持）且 **v73+ 架构**、单 PD 内共享——与本项目 CI 编译矩阵（x86 云端出包）兼容；分发键仍含 `bucket` 维度（经单文件内 graph 名路由），资产矩阵不额外膨胀。
- **取舍**：桶越密 TTFT 越优但资产体积与编译矩阵越大；默认 4 桶（128/256/512/1024）在"短问答体验"与"资产成本"间取平衡点。

## 4. 内存与带宽优化

### 4.1 权重驻留与生命周期状态机（v2 重大修正）

**废除 v1 的"Decode 阶段闪存按层分页"**：LLM 每个 token 必须串行走完所有 Transformer 层；3B~4B INT4 权重约 1.8~2.4GB，UFS 实际读取常 <2GB/s，若逐 token 从闪存换入，单 token I/O 即 >0.9s，TPOT 直接崩到 900ms+。**权重必须一次性全量常驻于 DRAM / NPU ION buffer**。

但"常驻不释放"会撞 **Android LMK（Low Memory Killer）**：3B~4B INT4 + KV + App 上下文，RSS 易破 2.4GB；用户切到微信/相机/游戏后后台内存压力骤增，LMK 首先杀死最大进程 → 白屏/冷启崩溃。故建立**生命周期感知的内存分级释放状态机**：

```
        [ACTIVE 推断执行中]
           │
           ▼ 推理结束 / 退到后台
   WARM-STANDBY（模型常驻 NPU/ION，Inactivity TTL 3~5min）
           │ 超时 或 onTrimMemory(RUNNING_CRITICAL / BACKGROUND)
           ▼
   COLD-EVICTED（析构 NPU Context + 释放 ION/FastRPC 句柄，进程 RSS < 50MB）
           │ 再次需要推断
           ▼
   本地缓存编译产物快速重载（非重新下载）→ 回到 WARM-STANDBY
```

> 命名对齐：v2.2 的 `WARM / IDLE / RELEASED` 在此规范为 **ACTIVE（执行中，WARM 档内）/ WARM-STANDBY（常驻待命）/ COLD-EVICTED（原 RELEASED）**。

- **ACTIVE**：模型全量驻留 NPU/DRAM，正在执行前向+采样（§2.3），绑定 `BIND_IMPORTANT`。
- **WARM-STANDBY**：推理结束或退后台但模型仍驻留；启动 **Inactivity Timer（3~5min）**，期间可零重加载续答；计时内回到前台/新请求即转 ACTIVE。
- **COLD-EVICTED**：定时器超时或收到 `onTrimMemory(TRIM_MEMORY_RUNNING_CRITICAL | TRIM_MEMORY_BACKGROUND)` 时，主动析构 NPU Context、释放 ION/FastRPC 句柄，**进程 RSS 压至 50MB 以下**；下次调用触发快速暖机（非重新下载）。
- **内存预算护栏**：监控 `:engine` 进程 RSS，逼近 LMK 阈值时**即使仍在 TTL 内**也主动从 WARM-STANDBY 提前降级到 COLD-EVICTED。

### 4.2 KV-cache 优化（连续物理槽位 + 前缀固化，v2.6 修订）

- **连续分桶管理（Bucketized Contiguous KV）**：废弃依赖离散页表的动态 PagedAttention（NPU 静态图难以支持任意指针跳转）。预先分配连续的 ION Buffer，按 512 / 1024 / 2048 维度分桶对齐，对 NPU 始终呈现物理连续的张量切片。
- **前缀固化（Prefix Cache）**：槽位 `[0, Prefix_Len)` 物理固化高频 System Prompt 与 Tool 模板 KV，首次暖机后常驻片上/ION，后续对话推理指针直接从 `Prefix_Len` 偏移量开始线性追加，彻底省去重复 Prefill 算力（与 §2.4 互证）。
- **KV 量化 INT8**：体积与带宽双降，校验 Attention 数值缩放范围。
- **超长上下文 Compaction（v2.7 新增）**：多轮会话逼近最大上下文（如 2048）时，连续物理 KV 排布无法像离散页表那样逻辑解引用旧 Block，须显式策略（默认 A）：
  - **策略 A（内存紧凑搬运，默认）**：保留 `[0, Prefix_Length)` 前缀不动，将最老一段会话历史经 ION 缓冲区内 `memmove` 前移覆盖，同步更新 NPU 侧偏移指针；腾出的尾部槽位继续线性追加。
  - **策略 B（整区复位，摘要换空间）**：触发 `truncateContext(keepTokens: Prefix_Length)`，仅保留系统前缀，将近两轮对话摘要作为新输入重跑一次 Prefill；实现最简但 TTFT 抖动大。
  - 选择依据：A 保多轮上下文连续性（代价一次 ≤ 数百 KB 的片外拷贝）；B 仅作 A 失败（ION 搬移异常）时的兜底。
- **冷热分离**：非活跃会话的连续 KV 切片通过 DMA 换至系统 RAM，需要时整块写回 NPU 专用内存。

### 4.3 零拷贝与数据搬运

- CPU/NPU/GPU 间用 **DMABUF/ION / FastRPC** 硬件 buffer 共享，杜绝 memcpy。
- NPU 热 kernel 用片上局部内存（如高通 VTCM）放激活，减往返 DRAM。
- 权重 stationary 数据流，匹配 NPU MAC 阵列 tile 尺寸最大化复用。

### 4.4 Roofline 指导

定期 roofline（算术强度 vs 可达 GFLOPS）：decode 落带宽受限区 → 优化方向是 INT4/减搬运；prefill 落算力区 → 优化方向是融合/提 MAC 利用率。

### 4.5 动态分发与冷启动缓存（v2 新增；**v3 落位实证 2026-11-01**）

> **落位实证（2026-11-01）**：模型资产分发路线已改——**2026-10-31 多模型导入制拍板，OTA 分片下发退役**：本地导入（File Picker + 结构校验 + 分片合并，`OnDeviceAssetManager`）为主通道；**运行库（.so）分发改增配 AAR**（Maven 双源 + 断点续传，见 `on-device-npu-runtime-split.md`，与本章「.so 须内置 APK jniLibs」旧表述一并作废）。Tokenizer 版本对齐约束仍有效（QAIRT bundle 须 genie_config+tokenizer 同源同版）。

端侧大模型最痛的资产链，v1 完全缺失，此处补全：

- **为什么不能随包模型 `.bin`**：Google Play AAB ≤200MB，国内商店亦不允许上架数 GB 包；1.8~2.4GB 权重必须**增量按需下载**（注：此限制仅针对模型 `.bin` 数据资产；QNN/Neuron 原生驱动 `.so` 须内置 APK `jniLibs`，见 §4.7，不在此 OTA 之列）。
- **分片机制**：权重分片 + 每片校验和 + 断点续传 + 本地防篡改解密（验签）。
- **SoC 专属编译产物**：QNN `.bin` / Neuron 编译产物含特定 SoC 二进制上下文，**8 Gen2 / 8 Gen3 / 8 Elite / 天玑各代互不通用**；**绝不打包全部芯片产物**，改为**按本机 SoC 型号云端动态下发**（Model Assets Dynamic Delivery）。
- **本地编译 vs 云端预编译**：提供"首跑云端拉取预编译 context"为主、必要时本机编译器兜底两条路径。
- **冷启动**：首跑 fetch+compile+cache；后续跑加载缓存 context；前台"预热"避免推理真空期（与总纲「离线引擎唤醒中」反馈呼应）。
- **资产打包形态（v2.6 补强）**：单次 OTA 下发的模型包必须是 **Zip 归档**，内含 `model.bin`（权重+编译 context）+ `tokenizer.json`（词表/特殊 token）+ `config.json`（架构与特殊 token 定义）；三者须同一次 CI 产出、同版本 hash 绑定，杜绝"新权重 + 旧词表"错配导致 Detokenize 乱码或越界（见 §6.4）。
- **Tokenizer 版本对齐**：词表随模型权重一并演进（如 Qwen2.5 达 151,646 词）；分发键须含 `model_version`，主进程载入的 `tokenizer.json` 必须与本地 `model.bin` 同源同版，否则直接拒载并回云端。

### 4.6 资产落盘与热更新防护（v2.3 新增）

模型资产落盘若选错目录或热更新方式，会在生产环境引发反复重下 / 段错误：

- **目录选型（严禁 cacheDir）**：模型权重/编译 context **必须落 `context.getFilesDir()`（或应用私有 `getExternalFilesDir()`）**——`context.getCacheDir()` 在系统可用存储偏低时会被**后台静默无通知清空**，导致文件损坏/丢失、反复触发模型重下（≈1.8GB）与流量消耗。
- **双倍空间门禁**：下载/解压前强制校验 **Free Disk Space ≥ 5 GB（≈ 2.5× 模型体积 1.8GB，含解压峰值余量）**；不满足直接中止并提示，避免 `ENOSPC` 崩溃。
- **热更新原子替换**：`:engine` 以 `mmap`（只读共享）打开旧模型文件期间，直接覆盖旧文件会导致 SIGBUS 段错误。须采用 **下载至临时文件 → `rename`/`link` 原子替换 → 旧句柄在本次卸载/下次启动或引擎 COLD-EVICTED 空闲时释放** 的替换策略。

### 4.7 原生库分发与 W^X 限制（v2.5 新增）

§3/§4.5 明确模型 `.bin` 按 HTP 版本动态下发，但**原生驱动库自身的分发方式**此前未界定，存在 Android 安全违规风险：

- **W^X 禁令（API 29+）**：Android 严格禁止 `dlopen()` 加载位于应用私有存储（`filesDir` 等）中**运行时下载的可执行 `.so`**——直接报 `dlopen failed: permission denied`（SELinux + W^X 可写即不可执行）。
- **QNN 库构成**：前端控制库 `libQnnHtp.so` + 硬件专有 Skel 库（`libQnnHtpV73Skel.so` / `V75Skel` / `V79Skel` 等）**均必须打进 APK/AAR 的 `jniLibs`**，随安装包发布（单架构 ~30MB，体积可控）。
- **OTA 仅分发静态数据资产**：动态下发的**只限离线编译好的模型拓扑与量化权重上下文二进制 `.bin`**（只读数据，无执行权限要求）；Native 库统一经 `System.loadLibrary` 从系统只读原生库目录加载，**彻底规避 W^X/SELinux 违规**。

### 4.8 OTA/驱动断层与 .bin 兼容性自愈（v2.6 新增）

**致命盲点**：QNN HTP 的 context 二进制（`.bin`）不仅绑定 `SOC_CHIP_MODEL` / `HTP_ARCHITECTURE_VERSION`（§3.5 资产矩阵），还**严格强绑定 Hexagon DSP 底层驱动版本与 FastRPC 协议版本**。用户系统 OTA（HyperOS / OneUI 月度安全补丁）更新 NPU 驱动后，本地已下载的 `.bin` 在 `QnnContext_createFromBinary` 会直接返回 `QNN_CONTEXT_ERROR_INCOMPATIBLE_BINARY`。

**灾难链**：若未感知，主进程反复加载旧产物 → 连续失败 → 触发 §6.5 熔断计数 → 该机型 24h 全量锁死走云端（误杀正常能力）。

- **驱动指纹哈希（Driver Fingerprint）**：下载与加载 `.bin` 时，持久化记录三要素指纹并写入资产元数据：① `Build.FINGERPRINT`（ROM 版本）；② 经 `QnnGetBackendVersion` 取得的 `Qnn_Version_t`（QNN 后端库版本）；③ HTP Skel 库版本串（`libQnnHtpVxxSkel.so` 版本）。分发键由 `SoC × HTP_ver` 升级为 `SoC × HTP_ver × Driver_Fingerprint`，做到驱动级精确匹配。
- **失效自愈（严禁计入熔断）**：加载返回 `QNN_CONTEXT_ERROR_INCOMPATIBLE_BINARY`（及同类 backend/driver 不兼容错误族）时：① 立即将该本地 context 标记为脏数据并**静默删除**（不弹错、不重试旧产物）；② 携带新驱动指纹向服务端请求匹配的新 context（或触发本地重编译兜底）；③ 自愈窗口期内推理**降级切云**；④ 此错误类**严格不计入 §6.5 的 L1/L2 熔断计数**（属环境变更，非本端代码 Bug）。
- **双向门禁**：新驱动编译产物也绝不回灌到旧驱动机型（指纹单向匹配），避免反向崩。

### 4.9 物理连续内存（CMA）分配防护（v2.6 新增）

**盲点**：§1.2 内存门禁（≥2.5GB 空闲）与 §4.1 只检验**虚拟内存**；但 QNN HTP / 天玑 APU 经 ION / DMA-BUF 申请大块**物理连续或 SMMU 可映射专用内存（CMA）**。一台 12GB 机型即使 `ActivityManager` 显示 4GB 空闲虚拟内存，连续开机 7~15 天、高负载跑过相机/游戏后，物理内存严重碎片化，一次性申请 1.8~2GB ION 连续缓冲会触发内核级 `ENOMEM` 或深度 Direct Reclaim，整机卡死数十秒甚至软重启。

- **预分配探针（真实尺寸，非极小探针）**：暖机/下载前，`:engine` 经 JNI 以**与目标同量级（而非极小）**的尺寸向 ION/DMA-BUF 试分配；失败即判定 CMA 不可用 → 放弃端侧、降级云端，并提示用户"重启后重试"，**不重试旧分配、不计入熔断**（见 §6.5 口径）。
- **IOMMU Scatter-Gather 放宽连续要求**：与 QNN/NeuroPilot 确认开启基于 IOMMU 的 SMMU 映射，使 KV/权重可离散物理页经 IOMMU 拼成连续虚拟视图，降低对单一平铺大块物理连续的硬依赖；若平台不支持离散映射，则退化为"分段 ION 槽 + 索引拼接"，并如实写入 §3.2 算子约束。
- **与状态机联动**：`ACTIVE` 阶段若运行中 ION 分配失败（非暖机），按 §4.1 直接转 `COLD-EVICTED` 并上抛 `EngineDiedException` 切云，不空转。

## 5. 功耗与散热约束下的调度

### 5.1 约束模型

- 功率封顶、热封顶（thermal 状态升档即可能降频）、电池低电量需重估能效。

### 5.2 调度策略（v2 修正：禁 CPU 分流）

| 模式 | 触发 | NPU 策略 | 取舍 |
|---|---|---|---|
| **Performance** | 短请求/前台交互 | 满频，优先 TTFT | 瞬时热升，限短时 |
| **Balanced（默认）** | 长生成/持续会话 | 选最优 OPP，稳定在热封顶线下 | TPOT 略降，不降频 |
| **Powersave** | 低电量/后台 | 降频 + 更激进量化/小模型 | 延迟升换续航 |
| **Duty-cycle** | 常驻轻量检测 | 周期唤醒 NPU（ms 级开/关） | 平均功耗极低 |
| **Thermal→Cloud** | `SEVERE/CRITICAL` 温控 | **直接全量切云端**，不做 NPU↔CPU 层切分 | 保整机稳定 |

核心机制（v2 修正）：
- **降频限流**：逼近温度阈值时**降 NPU OPP、插入休眠 duty-cycle 拉大采样间隔以降 TPOT 占用**，而非迁 CPU。
- **退后台主动降档（OEM 冻结防御，v2.6 新增）**：检测到 App 退后台但 `:engine` 仍在长生成时，**立即将 NPU OPP 降至 `Powersave` 并插入采样间隔**，使 NPU 占空比跌破厂商私有电源管理（小米 Joyose / OPPO Athena / vivo 魔方引擎）的"异常高耗能"监控阈值，避免被直接 `SIGKILL`（与 §6.2 互补）。FGS 保活的挂载时序约束见 §6.2（必须前台预挂）。
- **极端温度全量云端**：达 `SEVERE` 级，经 `HybridCloudEngine` 收口云端（与总纲降级判据联动）。
- **严禁**把矩阵运算临时迁 CPU（反模式，见 §2.1）。

### 5.3 OS 协同（v2 修正：降级公共 API）

**v1 越界修正**：第三方 App 无系统签名，**无法直接 IPC/HIDL/AIDL 连 `android.hardware.power` / `thermal` HAL**（会 Permission Denied）。改为：

- **温控监听**：用公共 `PowerManager.addThermalStatusListener()` 接收 `THERMAL_STATUS_MODERATE/SEVERE/CRITICAL` 状态变化，驱动 §5.2 的降级/切云决策。
- **性能档位**：经原厂 SDK 暴露的标准运行时参数调节 NPU 性能，如 QNN `QNN_HTP_PERF_INFRASTRUCTURE_POWER_CONFIG` 设置 Perf Level；**不试图控制系统 DVFS**。
- **与 OS 协同**：前台交互申请更高性能档；退后台降级避免被系统杀；极端热/低电由 §5.2 收口云端。

## 6. 运行时边界：Dart/Flutter ↔ Native 闭环（v2 新增）

本方案上层为 Flutter/Dart，且推理引擎运行于 `:engine` 独立进程，存在**跨语言 + 跨进程**双重边界陷阱（v1 未覆盖）。总原则：**控制面低频走 Binder，数据面高频走共享内存；解码闭环 100% 下沉 Native；取消/优先级下沉系统**。

- **下沉闭环**：Token decode 循环、采样、KV-cache 管理必须 **100% 封闭在 Native C++ 线程池**内，绝不在 Dart 主线程/Isolate 内跑推理循环（避免 GC、序列化、跨 FFI 频繁调用导致掉帧）。
- **零拷贝传递**：跨进程传 `ParcelFileDescriptor` / 句柄而非深拷贝大 buffer；仅在共享内存映射边界建立一次。
- **FFI 设计**：推理句柄、采样器、KV 管理器在 Native 侧为长生命周期对象，Dart 侧仅持 opaque handle + 控制指令，状态变更走命令式调用而非轮询。
- **独立进程隔离（`:engine`）**：完整 NPU 引擎（3B~4B 常驻 1.8~2.4GB + FastRPC 驱动交互）必须运行于 `android:process=":engine"` 独立私有进程，经 Binder / 共享内存与主进程通信。NPU 驱动 Panic 或 OOM 仅使主进程收到 `EngineDiedException` 并无缝收口云端，**绝不导致 Flutter 主进程闪退**（与总纲 P1 刚性前置一致）。

### 6.1 Token 流式 IPC 双平面（避免 Binder 事务饱和）

Decode 阶段 25~35 tok/s，若每 token 一次 AIDL/Binder 事务，JNI + Parcel 序列化 + 上下文切换会造成显著 CPU 开销并可能饿死 Binder 线程池。采用**双平面**隔离：

- **控制面（Binder/AIDL，低频）**：`init / generate(request) / cancel / release / onEngineDied`，仅生命周期与指令，频率极低（次/分钟级）。
- **数据面（Ashmem RingBuffer + eventfd，高频）**：`:engine` 将生成的 **token id（int32，非字符串）** 直接写入共享内存环形缓冲；写完仅对 `eventfd` 做一次 `write(1)` 轻量唤醒，**完全不占用 Binder 线程**。
  - **环形缓冲结构**：SPSC，头部 `{write_idx, read_idx}` 用 `std::atomic` 以 `release`（写后）/ `acquire`（读后）语义发布；载荷为 `uint32_t[]` **原始 token id（非字符串）**，处理回绕避免重复消费。
  - **单调自增掩码协议（无锁回绕）**：环形缓冲容量固定为 2 的幂（如 N=1024 槽），定义 `MASK = N-1`；`write_idx` / `read_idx` 为无符号 `uint32_t`，仅做单调 `++`，经 `idx & MASK` 寻址。利用 C++ 无符号整型自然溢出（wraparound）免显式回绕重置；空满判定极简（`write_idx - read_idx == N` 为满、`== 0` 为空），彻底消除无锁队列边界回绕死锁风险。
  - **唤醒与微批**：主进程将 `eventfd` 注册进其 `Looper`（`addFd`）或由 Native listener 经 `NativePort` 唤醒 Dart Isolate；**接收端按 40ms 节拍（或 eventfd 触发）一次性排空可用 token**，将 IPC 频率从 ~30/s 压降至 8~10/s，且与 token 速率解耦（非"每 3~4 token 通知"，而是满窗口排空，更稳）。
  - **载荷为原始 Token ID，绝不做字符串转码**：`:engine` 只产 `uint32_t` token id 写入环形缓冲，**绝不**在 Native 侧把多 token 拼成 String 推管道——否则 Qwen Byte-level BPE 等会把一个 3 字节 UTF-8 汉字切成 2~3 个独立 token，跨 40ms 微批边界的不完整字节被强制转义为 `\uFFFD` 永久乱码。词汇查表 / SentencePiece / **流式 UTF-8 重组** 统一在主进程胶水层（§6.4）经 `utf8.decoder` 累加器完成，跨批次无损拼接；共享内存占用极小（每 token 4B），且不占用 NPU 进程的 CPU 做字符串工作。
  - **fd 传递**：Ashmem 与 eventfd 的 fd 经 Binder `ParcelFileDescriptor` 由 `:engine` 传给主进程 `mmap` 映射。
  - **S3-6 落地标注（2026-10-29）**：数据面已全量落地——生产侧恢复 ring 写入（EngineService sink 40ms 微批冲刷 `dp.ring.write`；载荷 = GenieX 管线文本块 UTF-8 字节值 identity 编码，非 tokenizer id——GenieX 产物即文本，identity 表语义无损）；消费端 = 主进程 native worker（`libgdw.so`，`cpp/engine_data_worker.cpp`）：epoll 等 pipe 唤醒读端（JVM 侧以 pipe 等价 eventfd，fd 类型对契约不透明）+ `SharedMemory.mapReadOnly` 直接 ByteBuffer 过 JNI 取址（绕开 getFd @hide 面）+ drain 后 `Dart_PostCObject_DL` 微批投 Dart Isolate（Uint8Array）；驱动权在 Kotlin（`GdwNative.start/stop`，AIDL `getSharedMemory`/`getEventFd` + `detachFd` 移交所有权），Dart 侧仅传 NativePort + `initializeApiDLData` 指针；Binder onTokens 过渡通道同轮退役（AIDL Listener 已删该方法，禁双路）。
  - **S3-7 落地标注（2026-10-30，UDS 化定案；同日评审五点修订 + TLV 协议定型收口）**：上述 RingBuffer/eventfd/pipe/游标面**整体退役（代码删净，无 USE_SHM 开关）**。现行数据面 = `:engine` 侧 `SocketTokenWriter`（`engine/SocketTokenWriter.kt`，**TLV 成帧 `[2B 魔数 0x5A 0xA5][2B 帧类型][4B 大端 len][payload]`——协议终生定型**：`FrameType` TOKEN_CHUNK 0x0001 / IMAGE_META 0x0002（留位）/ PROGRESS 0x0003（留位）/ EOS 0x000F；魔数失步 fail-fast + **3s 有界写超时**抛 `IpcDeadlockException`（512KB 缓冲池吸收 GC/渲染数百毫秒瞬时卡顿，仅真实长失速触发），`IpcDeadlockException` 随迁此文件）+ `engine/EngineDataPlane.kt`（`ParcelFileDescriptor.createSocketPair` 建连，双端 `SO_SNDBUF/SO_RCVBUF` 显式 512KB，写端 `SO_SNDTIMEO` 100ms 切片 + `Os.poll(POLLOUT)` 可写等待；SIGPIPE 由 zygote fork 继承 SIG_IGN 承载）；读端 = 主进程 `libgdw.so`（`cpp/engine_data_worker.cpp`：epoll{sockFd,eventfd 停止面} + 魔数校验帧重组 + **未知类型 skip + 计数日志**（前向兼容，单端先升级不互炸）+ **首帧直通/微批聚合**（TOKEN 帧聚合，≥4KB 或可读沿收口即投，高吞吐段 N 次 Post 压 1 次）+ `Dart_PostCObject_DL` 投 **kArray `[Int32 type, Uint8List payload]`**；**EOF → kNull 信号**即刻上抛后 worker 终态退出，`isAlive` 判活自愈链不变；initApi 再设 `signal(SIGPIPE, SIG_IGN)` 双保险）；句柄 = AIDL `getDataSocketFd():ParcelFileDescriptor`（Binder dup，主进程 `detachFd` 移交 native）；Dart binding 分发：type 0x0001 → `onDataBatch(载荷)` / 0x000F → `onDataBatch(空批)` / 其余留位类型防御性忽略 / **null = EOF**。**流生命周期唯一事实源 = EOS**（收到 EOS 即无条件收口活跃流；`onGenerateFinished` 仅作控制面通知不参与流开关，旧双沿门控 2s 兜底定时器退役）；EOF 即刻 `failAllActive(EngineDiedException)` 切云，不经看门狗。**大块数据（文生图产物等）不入本协议载荷**：写端落盘后经 IMAGE_META 帧传引用（零拷贝范式；建议载荷带资源中心 `$ref` 句柄而非裸 path，对接 resource-center 既有架构），socket 上恒为 KB 级帧——IMAGE_META/PROGRESS 的生产端/消费端/临时文件所有权（建议「写端只产不删、消费端读完即删」单向所有权）挂多模态 epic 开工时启用。
  - **数据面协议收口（2026-10-30，ipc deadlock 误判定案）**：四条协议事实钉死——① **唤醒-背压协议**：写者**等待空间期间必须持续唤醒消费端**（进入等待前先唤醒 + 5ms 周期重复唤醒，幂等）；写完才唤醒 = 写者等空间 × 消费者等唤醒的自锁假死锁（500ms 后被误判为「消费端死亡」→ 无谓切云）。② **消费端兜底节拍落地**：§6.1「接收端按 40ms 节拍（或 eventfd 触发）排空」的实现侧原先**只剩唤醒沿**——丢一次唤醒即消费端永久停摆；native worker 的 `epoll_wait` 改为 40ms 超时，超时即排空（丢唤醒不再致命）。③ **游标单调（单写者语义）**：`read_idx` 只向前——`:engine` 的 `clearPending`（丢弃在途）与消费端 drain 的在途回写构成双写，普通 store 会把「跳过」拉回（lost update）→ 被丢弃的上一代尾字节二次投递 → 新流首字节落在 UTF-8 字符中间 → 解码异常洪泛；消费端推进改 CAS max 单调。④ **消费线程死亡须自愈**：worker 退出（EPOLLHUP / epoll 错误）后宿主句柄仍在，幂等短路会把「数据面死」当「数据面活」→ 后续生成必撞 ring 满 → 反复切云且数据面永不重建；新增 `isAlive` 判活面，宿主短路改判活（死线程先收旧再重建）。⑤ **投递顺序即契约 + 尾字节不得丢**：消费端**投递完成后再推进 `read_idx`**（`read_idx` 是写侧「已消费」凭据，先推进会让写侧以为尾批已交付 → 收尾事件先于尾批抵达 → 尾字节被丢）；`:engine` **正常收尾等排空**（`awaitDrained`，有界 500ms）而非收尾即 `clearPending`——收尾即丢弃 = 回答「像没说完」（真机实证）；只有中断/死锁/失败路径才丢弃在途（下一轮不得混入本轮残字节）。⑥ **跨语言内存布局常量必须由对端也认账**：`read_idx` 的宿主侧访问经 `byteBufferViewVarHandle`，其 int 坐标语义**在 JVM 与 ART 之间可能不一致**（字节偏移 vs 元素下标）——错配即「写者读到槽区载荷当游标」→ 写者永远看不到消费端进度 → ring 假满 → 误判消费端失速；故建环时**运行时自检**坐标语义并自适应（真机 Android 17 实测 = 字节偏移，`readIdxCoord=4`）。

### 6.2 LMK 防杀与进程优先级（绑定 / 回收信号）

`:engine` 因常驻 1.8~2.4GB 必为 LMK 首选目标，须主动管理 oom_adj 与回收信号：

- **绑定标志**：主进程经 `bindService` 连接 `:engine` 时必须 `Context.BIND_AUTO_CREATE | Context.BIND_IMPORTANT`，使 `:engine` 的 `oom_adj` 与主应用处于同一生命周期梯队（避免无前台依附时被优先强杀）；绑定由单例 `ServiceConnection` 常驻持有，避免反复 rebind 抖动。
- **Trim 信号驱动状态机**：`:engine` 注册 `ComponentCallbacks2` / `onTrimMemory`，将 `TRIM_MEMORY_*` 等级映射到 §4.1 的 `ACTIVE / WARM-STANDBY / COLD-EVICTED` 状态机——在系统尚未杀进程前**主动**降权/释放 NPU 上下文，而非被动等死。
- **长生成前台态（前台服务兜底，v2.7 修正挂载时序）**：进入长文本生成时，若需强保活可在 `:engine` 内 `startForeground`（极简/可折叠通知"正在本地生成"）；通常靠"前台 Activity 经 `BIND_IMPORTANT` 绑定"已足够，且 §4.1 规定退后台即进入 WARM-STANDBY 倒计时释放，故默认不强制常驻通知。
  - **FGS 挂载时序硬约束（v2.7，已核实 Android 官方文档）**：Android 12（API 31）起，应用处于后台时调 `startForeground` 抛 `ForegroundServiceStartNotAllowedException` 直接崩溃（非仅 Android 14；Android 14 起另有类型强制）。因此 FGS 提权**必须在 Activity 仍处前台时预挂**（`generate()` 发起且判定可能耗时时即附着），或在主进程 `onUserLeaveHint()` / `onStop()` 前完成提升——严禁"退后台后再补救"。
  - **类型声明（Android 14 强制）**：`:engine` 的 Service 须声明 `android:foregroundServiceType`，长生成选 **`dataSync`**（须 `FOREGROUND_SERVICE_DATA_SYNC` 权限，海外渠道需 Play Console 合规说明）；**不选 `shortService`**——其约 3 分钟硬超时（超时 ANR），长文本生成会超限；`specialUse` 仅作兜底备选（需用途说明）。
- **厂商私有冻结防御（v2.6 新增；S3-5 落地标注 2026-10-29）**：国内 OEM 拥有超越 AOSP 的自研后台策略（小米 Joyose / OPPO Athena / vivo 魔方引擎），可在 **5~10s 内强行 `SIGKILL` 后台高耗能的 `:engine` 进程且不下发 `onTrimMemory`**。防护：① 长生成期间切后台时短时挂载**前台服务通知栏**保活【✅ S3-2 已落地：FGS promote 先于 startGenerate 硬时序，`kFgsPromoteMinTokens=256`】；② 同步将 NPU 降档至 `Powersave`（见 §5.2），跌破厂商监控阈值【⛔ geniex 路线不适用：无运行时 perf 切换 API，`perf_profile` 在资产 htp config 固化（`sustained_high_performance`，S2-5 实证），降档会回退 S2-5 达标指标——FGS 在位时高耗能判定主要针对后台进程，本条收益被 ① 覆盖】；③ 引导用户在系统电池设置将本应用加入"不受限制/白名单"【✅ S3-5 已落地：端侧模型设置节引导行（未加白显提示 + 跳系统申请，查询/申请复用网关电池白名单通道，应用级白名单两端共用）】；④ OEM `SIGKILL` 视为 `EngineDiedException` 无缝切云，**不计入 §6.5 熔断计数**（外部处决非本端 Bug）【✅ 已落地：`onServiceDisconnected → onProcessDied → report(countable:false)` 仅 500ms 冷却窗口】。**边界**：OEM 冻结（暂停进程而非 SIGKILL）不在 `binderDied`/`onServiceDisconnected` 检测面内——在途 Binder 调用会挂起，挂起检测（调用超时→判死切云）归真机验收 §7.1 观测项。
- **进程声明**：`:engine` 须 `android:process=":engine"` 且 `android:isolatedProcess="false"`（需访问 NPU 驱动/HAL，不可隔离）。

### 6.3 及时中断与背压（Cancellation & Backpressure）

用户在 UI 点"停止生成"或退出页面时，Dart `Stream` 取消必须**立即下沉中断 NPU 算子**，否则 `:engine` 会空跑到最大上下文，浪费发热与能耗。

- **原子停止标志**：Dart 侧 `cancel` / `release` 映射为 Native 侧 `std::atomic<bool> stop_requested`；Decode 循环**每步执行前**做轻量检查，命中即跳出。
- **中止 NPU 与流收尾**：触发后立即向运行时发 abort 指令（QNN 上下文取消 / NeuroPilot 等价 API），释放当次推理上下文，**不空转**；并**直接清空 RingBuffer 未消费在途 Token**，下发单条 `finishReason: "cancelled"` 的 `EngineChunk` 后闭合流，避免 Dart 侧序号不一致（与总纲 §2 流生命周期自动绑定一致）。
- **cancel vs release 区分**：`cancel` = 中止当前生成但保持引擎热（WARM-STANDBY，可续答）；`release` = 额外析构 NPU 上下文进入 COLD-EVICTED（与 §4.1 一致）。
- **背压与写超时（不丢 token，v2.7 收敛边界）**：环形缓冲按数秒容量预留（如 ≥1024 槽 ≈ 4KB）；若接收端偶发卡顿致缓冲满，写入端施加**有界等待/短超时**而非丢弃，自然形成背压；因接收端 40ms 排空，实际极少触发。**超时阈值定为 500ms**（decode 节拍 35ms/token，500ms 未被消费意味着消费线程死锁或主进程 ANR）；写超时后 `:engine` 不得永久挂起——判定为 `IPC_DEADLOCK`，主动中断本次生成（走 §6.3 中断路径）、清空 RingBuffer、上报 `EngineDiedException` 切云，防止 NPU 算子占住物理硬件资源空转。**等待期间必须唤醒消费端**（2026-10-30 收口：不唤醒即写者等空间 × 消费者等唤醒的自锁假死锁，500ms 后被误判为消费端死亡）；**满判据用 `>=` 而非 `==`**（游标失步时 `==` 会让背压完全失效 → 写者无限前进覆盖未消费槽 → 字节流腐化）。
- **生命周期耦合**：页面退出 / App 退后台且仍在生成 → 自动 `cancel` 当前生成并启动 §4.1 的 WARM-STANDBY 倒计时，避免后台空跑发热。

### 6.4 主进程事件消费线程（eventfd → Dart 投递，v2.3 澄清；S3-6 落地 2026-10-29）

Dart/Flutter **无法直接从 eventfd `read`**，须由主进程 Native 胶水层搭桥，否则 Android 工程师写 JNI 无法闭环：

> **落地标注（S3-6，2026-10-29）**：实现 = 主进程 `libgdw.so`（cpp/engine_data_worker.cpp）——epoll 等待唤醒 fd（pipe 读端，detachFd 移交 native）+ 只读映射 `:engine` RingBuffer + `Dart_PostCObject_DL` 按 4KB 微批投递 Dart Isolate；Dart 侧 ReceivePort（NativePort）经 MethodChannel 传 `initializeApiDLData` 指针启动（`startDataWorker`/`stopDataWorker`，binding 面）。S1-4 偏差销项：mmap 化以「native worker 只读映射共享内存」承载，词表仍 Dart 单次读入（GenieX 管线载荷即文本块，identity 字节级编码语义无损）。CPU Affinity 绑核归 geniex 管线（cpu-mask knob 实测无收益，见 epic devlog）。

- **Native Epoll/Looper Worker Thread**：主进程 C++ 层维护专用 worker 线程，经 `Looper`/`epoll` 监听 `:engine` 传来的 `eventfd` 唤醒信号，从 Ashmem 环形缓冲批量消费 token id。
- **投递 Dart Isolate**：worker 线程通过 `Dart_PostCObject`（或 FFI `NativeCallable.listener` / `NativePort`）将批量 token 异步投递给 Dart Isolate，驱动 `Stream<EngineChunk>` 发射——全程不阻塞 UI 线程，维持 60/120 fps。
- **流式 UTF-8 重组**：worker 将批量 token id 经 `utf8.decoder` 流式累加器组装为字符串再投 Dart——多字节汉字跨 40ms 微批边界时无损拼接，杜绝 `\uFFFD` 乱码（载荷协议见 §6.1）。
- **职责边界**：该 worker 仅做"消费 + 转发 + 重组"，**不做推理/采样**；解码闭环仍在 `:engine`（§6 原则）。
- **S3-6 落地标注（2026-10-29）**：消费闭环已落地——native worker 线程（pthread，非 Looper addFd）epoll 双 fd（pipe 唤醒 + 自建 eventfd 停止面），drain 即 `Dart_PostCObject_DL` 直投（Uint8Array 微批，Dart_PostCObject 复制语义消费安全），Dart 侧 `NativeCallable`/`ReceivePort` 收 `Uint8List` 喂 `StreamingDetokenizer`（identity 表跨微批无损重组）。`StreamController(onCancel:)` 自动下沉 cancel 与 `truncateContext` 接口均已在册（后者 Kotlin 侧 no-op：Genie 无部分回滚 API，Prefix Cache 语义由 GenieX 管线内置承载，§2.4）。IPC 死锁自救链落地：ring 写超时（500ms）→ sink 就地 `session.abort()` + `ring.clearPending()` → AIDL `onIpcDeadlock`（oneway）→ Dart `EngineDiedException` 切云（不计熔断，仅 500ms 冷却）。worker 生命周期：`enable()` 显式加载时启动（失败 = 加载失败显式报错，不静默切云）、generate 内幂等兜底、disconnect/unbind/release 三路停收（fd/映射随 `:engine` 数据面销毁）。
- **S3-7 落地标注（2026-10-30，UDS 化定案；同日评审五点修订 + TLV 协议定型收口）**：消费闭环换 UDS 读循环——native worker epoll 监听数据面 socket 读端（可读事件即唤醒，40ms 兜底节拍退役）+ `[2B 魔数 0x5A 0xA5][2B 帧类型][4B BE len][payload]` TLV 魔数校验帧重组（魔数不匹配/帧长 >1MB 判协议腐化 → worker 终态退出自愈重建；未知类型 skip + 计数日志，前向兼容）+ **首帧直通/微批聚合**（TOKEN 帧聚合，≥4KB 或可读沿收口即投，高吞吐段 N 次 `Dart_PostCObject_DL` 压 1 次，防 Dart 事件循环被高频小事件冲垮丢帧；投递形状 kArray `[Int32 type, Uint8List payload]`）；`read()==0`（EOF）= `:engine` 数据面死亡 → **投 Dart kNull 信号**即刻 failAllActive 后 worker 退出 → `isAlive` 判活自愈重建。IPC 死锁自救链换轨：socket 写超时（3s 有界，512KB 缓冲池吸收瞬时卡顿）→ sink 就地 `session.abort()` + `dp.close()`（EOF 通知对端）→ AIDL `onIpcDeadlock`（oneway）→ Dart `EngineDiedException` 切云（不计熔断，仅 500ms 冷却）。JVM 单测：`SocketTokenWriterTest`（TLV 成帧/EOS/部分写/写超时）。
- **端侧流无进展看门狗（2026-10-30 收口）**：端侧流此前**无任何超时兜底**——`:engine` 收尾事件（`onGenerateFinished`）一旦丢失/迟到，活跃流永挂 → 混合引擎的端侧单发聚合 await-for 永挂 → **本轮问答零响应**（真机实证「第二轮没有任何响应」）。判据取「字节活体」：生成期字节每 ~40ms 一批（§6.1 微批），连续 30s（对齐云端首 token 口径）无字节即判数据面失联 → 以 `EngineDiedException` 收口 → 混合引擎无缝切云（产出优先，**绝不静默挂死**）。切云沿的云端流同样复用 `_cloudSend` 的自适应看门狗（禁裸 `c.send()`）。
- **核心亲和度绑定（CPU Affinity）**：`:engine` 推理循环、Grammar Masking 以及主进程的 eventfd Worker 线程，必须通过 `sched_setaffinity` 强制绑定至性能核心（Performance Cores），严禁运行于效率小核（Efficiency Cores），消除因内核调度颠簸造成的 JNI/IPC 与采样延迟毛刺。
- **轻量 Detokenizer（v2.6 补强；**G1 终态 2026-10-31**）**：主进程 `utf8.decoder` 重组前需 `id → raw bytes` 映射。仅载入 `tokenizer.json` 导出的**只读紧凑 ID-to-Byte 表**（mmap 只读，避免 RSS 尖峰），**禁止引入全功能 BPE 分词框架**（30~60MB，且客户端无需 encode）；该表由 §4.5 OTA 包随 `model.bin` 同源下发并版本对齐。停用词/终止判定不在此做（见 §6.7）。**G1 数据面终态（用户拍板 2026-10-31）**：Genie 管线载荷即文本块（SDK 文本回调），现行 = `StreamTextSanitizer` + Dart identity 直通——token-id 直取/C API 直绑/Latin-1 还原三路均不可达，本方案为 SDK 能力边界内的合法方案而非治标补丁；唯一后续通道 = geniex-android 上游 issue（detokenize 单字节解码拆散 UTF-8）。

### 6.5 进程守护与熔断（Circuit Breaker，v2.3 新增）

`:engine` 崩溃主进程捕获 `EngineDiedException` 切云已覆盖"单次崩溃"，但**未防重启风暴**：若根因是恶性 Prompt 命中 NPU 驱动未处理算子越界，盲目重启再执行会陷入「Crash → 驱动 Panic → 重启 → 再 Crash」死亡循环，耗尽资源甚至触发系统前台强杀。

- **两级阶梯熔断（内存态优先，v2.4 拍板）**：

  | 级别 | 触发条件 | 惩罚行为 | 恢复条件 |
  |---|---|---|---|
  | **L1（单进程级，默认）** | 5 分钟内连续 Crash ≥ 2 次 | 内存置标志 `isCircuitBroken=true`；**当前 App 进程生命周期内**所有推理直接走云端 | 用户杀进程**冷启动 App 后自动重试**（自愈绝大多数瞬时系统内存抖动） |
  | **L2（持久化级，防恶性 Bug）** | 当天累计触发 L1 达 **2 次**（表明存在特定 Token/Prompt 必崩驱动） | 熔断时间戳写入本地持久化（MMKV / DataStore），**锁定 24 小时**强制切云 | 24h 自然过期 / 模型版本更新（hash 变化）/ 用户在调试菜单手动清缓存 |

- **设计意图**：L1 用内存标志仅覆盖当前进程，避免一次偶发系统低内存驱动抖动就剥夺普通用户整天端侧能力；L2 才持久化 24h，专治"恶性 Prompt 必崩"的硬伤。
- **复位**：模型版本更新（新 `context`/权重 hash）或用户手动清缓存均解除 L1/L2；L1 冷启动即复位。
- **驱动释放冷却（v2.7 新增）**：`:engine` 进程被外部处决（OEM `SIGKILL`/LMK）或 Crash 退出后，内核释放 `/dev/fastrpc-*` 节点与 glink 通道、DSP 固件端完成 RPC Session Tear-down 存在**异步延迟**（FastRPC 清理路径与设备/会话拆除存在竞态，属内核已实证问题族，具体延迟毫秒数未官方公布）。主进程重拉管理类必须施加 **500ms 冷却窗口（Backoff Window）**，窗口内严格阻断本地暖机请求，避免立即重初始化撞上 FastRPC 僵尸通道（典型报错 `QNN_COMMON_ERROR_SYSTEM_COMMUNICATION` 族）；冷却期结束仍失败则计入熔断口径。冷却等待期间推理直接走云端，不阻塞用户。
- **与状态机关系**：熔断独立于 §4.1 的 COLD-EVICTED；熔断期间即便本地有产物也不启用端侧。
- **熔断计数口径（v2.6 收窄）**：仅**本端 NPU 驱动 Panic / 算子越界 abort（恶性 Prompt 必崩）**计入 L1/L2；以下错误类**严格不计入**熔断，按对应自愈/降级路径处理：① `QNN_CONTEXT_ERROR_INCOMPATIBLE_BINARY` 等驱动不兼容错误（§4.8，触发脏数据删除 + 重拉 + 切云）；② ION/CMA 分配失败（§4.9，降级云端 + 提示重启）；③ 外部进程处决（OEM `SIGKILL` / LMK，按 `EngineDiedException` 切云，§6.2）。误计会致正常机型被 24h 误锁。

### 6.6 并发互斥与抢占（单执行槽 + 策略 B 驳回，v2.4 拍板）

端侧能力已升格公共服务，被 `AgentLoop`、离线兜底、`OnDeviceResultSummarizer` 等多方调用；但 NPU 静态图/KV-Cache/VTCM **物理单重入、单会话互斥**，同刻绝对无法并发推理。无防护会导致 KV 覆盖或驱动 Panic。

**已拍板：坚决采纳策略 B（后台任务快速驳回切云），不维护跨请求堆积队列**——彻底消除后台积压造成的内存波动与前台 TTFT 劣化。

- **单执行槽**：`:engine` 仅一个推理执行槽；任何时刻至多一个 `generate` 在跑。
- **后台任务驳回（默认）**：NPU 占用态时，后台 `Summarizer`/定期意图探测等非交互式任务收到 **`ServiceBusyException`**，`HybridCloudEngine` 直接无缝分流至云端执行。
- **前台对后台（抢占）**：前台会话请求到达、若后台正在轻量推理 → 对后台发 `stop_requested` 主动中断并将其切云，**立即让出执行槽**给前台 UI。
- **前台对前台（连续发消息）**：上一次生成未结束、用户又发起新消息 → **不驳回用户**，而是对旧请求发 `cancel(requestId)` 触发 Native 快速中断（§6.3），清空执行槽后立即执行最新前台请求。
- **与 cancel 联动**：`cancel(requestId)` / 抢占中断均经 atomic `stop_requested` 下沉（§6.3），中断完成方可接纳下一请求。
- **原子抢占与防 TOCTOU 约束**：上层 `HybridCloudEngine` 严禁采用「先 `checkStatus()` 后 `generate()`」的非原子调用模式。`checkStatus()` 返回的 `busy` 仅作为瞬时监控展示，严禁建立 TTL 缓存；一切推理任务直接调用 `generate()`，由 `:engine` 进程内部的互斥锁进行原子判定。冲突时由 Native 层原子抛出 `ServiceBusyException`，上层捕获该异常瞬间切云，杜绝并发竞争缝隙（与总纲 §2 v2.6 调度纪律一致）。

### 6.7 生成终止条件下沉（Stop Sequences，v2.6 新增；**v3 落位实证 2026-11-01：下沉路线被 SDK 拒收**）

> **落位实证（2026-10-30 真机 / 2026-11-01 收录）**：qairt 插件**拒收** `--stop` / `--stop-file` 参数（geniex ErrorCode -100016 直接拒绝整个 LlmCreate）——「终止条件全下沉/stop_token_sequences」设计**不可行**。现行实现：`:engine` GenieSession 流回调内文本级 `<|im_end|>` 截断 + 主进程 `StreamTextSanitizer` 兜底；多 token 停用词待 geniex-android 上游支持（与 G1 同通道）。本章保留为 v2 时代设计历史。

**盲点**：对话模型除单 token EOS（如 `<|im_end|>`）外，还依赖多 token 组成的自定义停用词（如 `\nUser:`、`\nAssistant:`）。若停用词匹配放主进程做，Ashmem 按 40ms 微批排空，主进程识别并下发 `cancel` 时 NPU 已在片上超前生成 2~4 个无意义 Token，UI 停止后闪现半句假话、破坏下一轮 Prompt 对齐。

- **终止条件全下沉**：`generate(request)` 控制面请求体除 `prompt` 外，须由调用方下发预编码的 **`stop_token_ids: Set<uint32_t>`**（含 EOS 及业务 EOS）与 **`stop_token_sequences: List<List<uint32_t>>`**（多 token 停用词，已编码为 id 序列）。
- **解码循环内滑动窗口匹配**：`:engine` C++ Decode 循环在**产出每个 Token 的瞬间**做滑动窗口匹配；命中即终止循环、阻断续生成，并下发 `finishReason: "stop"`（非 `cancelled`）闭合流，杜绝在途冗余 Token。
- **停用词预编码约束**：多 token 停用词须**提前编码为 token-id 序列**再传入（客户端无全功能 BPE encoder，见 §6.4；由服务端/共享 tokenizer 产出 id 序列），`:engine` 不做字符串级匹配。
- **与 §6.3 关系**：命中 stop 属自然结束，不触发 `cancelled` 流收尾；用户主动 `cancel` 仍走 §6.3 中断路径，二者并列。

## 7. 端到端性能评估与验证

### 7.1 基准套件

- 微基准：matmul/attention 吞吐、roofline 取点。
- 真实负载：会话 trace、摘要/提取标准集、常驻检测周期任务。
- 压力：长上下文 + 持续生成（验热稳态）、多会话并发（验连续分桶 KV 与常驻共享）、**后台切回（验 LMK 状态机与冷重载）**、**首跑分发（验 §4.5 下载/校验/编译）**、**并发 `generate` 互斥（验 §6.6 原子抢占不 Panic，不维护堆积队列）**、**Crash 重启风暴熔断（验 §6.5 5min≥2 次休眠）**、**模型热更新原子替换（验 §4.6 不 SIGBUS）**。
- **深水区盲点验收（v2.6 新增）**：① OTA 驱动断层自愈（模拟 DSP 驱动升级后旧 `.bin` 加载报 `INCOMPATIBLE_BINARY`，验 §4.8 脏删+重拉+不计入熔断）；② CMA 碎片（长开机后试分配 1.8GB ION，验 §4.9 探针失败降级云端）；③ Detokenizer 资产（验 §4.5 Zip 含 `tokenizer.json` 且主进程 mmap 只读 ID-to-Byte 表、不引入全功能框架）；④ Stop Sequences 下沉（验 §6.7 多 token 停用词在 `:engine` 内即时阻断、无在途冗余 Token）；⑤ Prefill 分桶（验 §3.6 短问答对齐 128 桶、TTFT 不退化到 2s+）；⑥ OEM 冻结（模拟后台长生成，验 §6.2 前台服务+降档不被 SIGKILL、被 SIGKILL 走 `EngineDiedException` 不计入熔断）；⑦ FGS 前台时序（Android 12/14 真机验 §6.2：前台预挂 `dataSync` 通知，退后台瞬切不抛 `ForegroundServiceStartNotAllowedException`）；⑧ Crash 后重拉冷却（验 §6.5 500ms 冷却窗口内阻断暖机、不撞 FastRPC 僵尸通道）。

### 7.1.1 实测基准快照（2026-11-01，S2-5 真机回填）

> **口径标注（防误读）**：单机（S2-5 = 一加 Ace 6，SM8750/HTP v79）单轮多测汇总，历次 bench 会话热态波动区间内取值（decode 17.6~20.5 全区间见 epic devlog）；**非合同指标**，合同口径仍以 §1.2 分层指标为准。bench 口径 = `short~256ctx` / `long~2Kctx` / `short-repeat`（前缀复用观测）三用例 ×128 tokens。

| 档位 | 模型 | decode | TTFT short | TTFT long 2K | 备注 |
|---|---|---|---|---|---|
| **QAIRT+NPU**（主路） | qwen3-4b W4A16 QAIRT bundle（3GB） | 17.6~20.5 tok/s | 196~229ms | 1205~1338ms | §1.2 2K≤5s **达标**；装载 model ready ~8-9s |
| **llama_cpp+GPU**（兜底档） | qwen3.5-2b Q4_0 GGUF（1.2GB） | 37.5~39.6 tok/s | 739~961ms | ~6619ms | 2K TTFT 超 §1.2 5s 档——兜底档长上下文 Prefill 为 NPU 档 ~5×（§3.5 落位实证口径） |
| short-repeat（前缀复用观测） | 同 QAIRT 主路 | 18.0~20.5 tok/s | 196~217ms | — | 与首案基本一致，**前缀复用收益未显著观测**（S2-3 遗留观测项仍开） |

装载链实测（增配 AAR 89MB）：全量下载 ~102s；**断点续传 ~34s**（弱网演练，partial 保留跨触发）；解压+指纹 marker 秒级；双断网周期演练三次触发完成（P3/P4）。

### 7.2 指标采集

| 类别 | 工具 | 关键量 |
|---|---|---|
| NPU 利用率/频率 | 厂商 profiler（QNN profiler / NeuroPilot）、perfetto、systrace | 有效 TOPS、占空比 |
| 功耗 | 电量监测仪 / `batterystats` | mW/token |
| 热 | `PowerManager` ThermalStatus + 壳温 | 降频触发点、稳态时长 |
| 内存 | meminfo、NPU 分配器、LMK 事件 | 峰值 RSS、状态机切换 |
| 延迟 | 端到端打点 | TTFT/TPOT 百分位 |
| 分发 | 下载/校验日志 | 分片完整率、首跑耗时 |

### 7.3 验证闭环

1. 精度回归：量化后跑困惑度 + 下游基准，对比 FP 基线，超阈自动升精度（§3.1）。
2. Roofline 体检：确认 prefill/decode 落预期区。
3. 热/功耗门禁：持续生成 ≥10min 不降频、单 token 能耗达标；否则回退调度参数/模型尺寸。
4. A/B vs 云端：质量/延迟/离线成功率。
5. CI 回归：参考机型 harness + dashboard，防劣化。

## 8. 关键设计决策与取舍（v2 修订）

| 决策 | 选择 | 代价 | 理由 |
|---|---|---|---|
| TTFT 基线 | 短文本 256ctx≤800ms；长文本 2K≤5s + Prompt Cache | 长文本非秒级 | 守住旗舰物理上限（200~500 tok/s） |
| Decode 权重 | 全量常驻 DRAM/ION，**废闪存按层分页** | 占用大量内存（需状态机兜底） | 逐 token 走全层，闪存 I/O 会拖垮 TPOT |
| 量化 | AWQ INT4 / W4A16，**去 2:4 稀疏** | 放弃稀疏带宽增益 | INT4 后稀疏致 PPL 发散，守不住 +2% |
| 热降频策略 | 降频限流 + SEVERE 全切云，**禁 CPU 分流** | 极端时放弃端侧体验 | CPU 能效差 5~10×，分流加剧发热 |
| OS 协同 | ThermalStatusListener + SDK 档位，**不连 HAL** | 拿不到底层功率预算 | 第三方 App 无系统签名权限 |
| 联发科基线 | NeuroPilot（非 LiteRT/AICore） | 双 SDK 维护 | NNAPI 废弃、AICore 不对第三方开放 |
| 资产分发 | 按 SoC 动态下发 + 分片校验 + 本地解密 | 需 OTA 链路与首跑复杂度 | 商店禁止数 GB 包、context 不跨芯片 |
| Dart 边界 | 推理闭环下沉 Native + 微批回调 | Native/C++ 工程量增加 | 避免 FFI/GC 掉帧，保 60/120fps |
| 内存 | LMK 感知状态机（ACTIVE / WARM-STANDBY / COLD-EVICTED） | 切回有重载开销 | 防后台被 LMK 强杀致白屏 |
| OTA 驱动断层 | `.bin` 绑定驱动指纹，不兼容即脏删重拉、**不计熔断** | 资产矩阵膨胀（SoC×HTP×驱动指纹） | 系统 OTA 升级 DSP 驱动会废旧 `.bin`，误计熔断将锁死机型 24h |
| Prefill 分桶 | 离线 4 桶（128/256/512/1024）向上对齐 | 资产体积与编译矩阵增大 | 静态图不能动态形状，全量 Padding 短问答 TTFT 退化数十倍 |
| Tokenizer 资产 | OTA Zip 含 `tokenizer.json`，主进程只读 ID-to-Byte 表 | 主进程 +30~60MB（mmap 可控） | 流式 Detokenize 闭环缺词表会乱码/越界 |
| OEM 冻结 | 后台长生成挂前台服务 + 降档 Powersave | 后台体验略降、需引导加白名单 | 厂商私有电源管理会无回调 `SIGKILL` 后台高耗能进程 |
| Prefill 资产形态 | 单 Context 多图打包（`model_<htp>.bin`，权重共享） | 须 x86-Linux 离线 prepare、≤64 图 | 4 桶拆独立 `.bin` 会重复加载权重且句柄管理易错（§3.6） |
| FGS 时序 | 前台预挂 `dataSync` 型 FGS，禁后台补救 | 通知出现更早 | Android 12+ 后台启 FGS 抛 `ForegroundServiceStartNotAllowedException`；`shortService` 3min 超时不适用长生成（§6.2） |
| Crash 重拉 | 500ms 驱动释放冷却窗口 | 极端时重载延迟 +0.5s | FastRPC 会话拆除异步，立即重拉撞僵尸通道（§6.5） |

## 9. 落地里程碑（v2 修订）

1. **M1 探针与基线**：参考旗舰跑微基准 + roofline，确认 NPU 上限、Prefill 实测吞吐、算子矩阵（支撑 §2/§7）。
2. **M2 单模型闭环**：3B~4B@INT4 经 QNN/NeuroPilot 跑通 prefill+decode，达成 §1.2 分层延迟/利用率。
3. **M3 资产分发**：§4.5 分片下载 + 按 SoC 下发 + 校验解密 + 冷启动缓存。
4. **M4 调度与热 + LMK 状态机**：ThermalStatusListener 联动、Balanced 不降频、SEVERE 切云、ACTIVE / WARM-STANDBY / COLD-EVICTED 生命周期。
5. **M5 Native 闭环、FFI 与独立进程**：推理/KV/采样下沉 C++，Dart 微批回调，验 UI 帧率；落地 `:engine` 独立进程与 `EngineDiedException` 无缝切云（与总纲 P1 刚性前置一致）。
6. **M6 回归体系**：CI harness + dashboard，纳入总纲 `HybridCloudEngine` 云端兜底联动。

---
*本方案与 `on-device-capability.md` 的芯片分发（高通=QNN、联发科=**NeuroPilot**）、D1（仅高端启用端侧）、公共服务化抽象一致；v2 相对 v1 修正：TTFT 物理上限、去 2:4 稀疏、废 Decode 闪存分页、联发科改 NeuroPilot、OS 协同降级公共 API、禁 CPU 热分流、新增资产分发与 Dart/FFI 闭环。*
