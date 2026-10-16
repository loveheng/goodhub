---
status: draft
updated: 2026-10-16
---

# 上下文阶梯截断与归档摘要（Stepped Context Pruning）

> 解决「朴素逐轮滑动窗口打碎前缀缓存」与「出窗即失忆」两个问题：历史区按**高低水位双缓冲**阶梯截断，被裁轮次经端侧摘要器归档为滚动摘要块回注上下文。
>
> SSOT 关系：窗口裁剪机制 SSOT = `lib/coordinator/context_governor.dart`；本文记录设计裁决与演进，实现偏差须回写本文。

## 1. 问题（现状缺口）

现状（stream-perf T6）：`trimMessagesToWindow(messages, 6)` 在发送边界**逐轮 FIFO**——每发一次，窗口起点前移一轮。两个后果：

1. **前缀缓存击穿**：前缀匹配从第 0 token 严格比对，`[System]` 之后第一个 token 每轮都变 → 历史区每轮 100% Cache Miss，只有 System 前导块吃到 ephemeral 缓存；
2. **出窗即失忆**：被裁的 6 轮之前内容无任何归档——四域提取（workspace_update）只覆盖结构化事实，叙事细节（过程、上下文铺垫）出窗即丢。

## 2. 设计裁决

### 2.1 高低水位双缓冲

| 参数 | 值 | 含义 |
| --- | --- | --- |
| 低水位（基底） | `windowRounds = 6`（现有参数复用） | 截断后保留的最小完整轮数 |
| 批次步长 | `windowStep = 6`（新增，默认 = 低水位） | 每次截断剪出的轮数 |
| 高水位（触发线） | 低水位 + 步长 = 12 | 可用轮数 ≤ 高水位时**纯追加不裁剪** |

行为：轮数 ≤ 12 → 原样发送（吃满缓存）；> 12 → 一次性剪出最早的 `windowStep` 轮 → 端侧摘要归档 → 剩余轮数回到 6，重新进入纯追加段。窗口在 6~12 之间阶梯波动，截断频率从「每轮」降为「每 6 轮一次」。

### 2.2 归档摘要块的位置与生命周期

- **位置**：`System` 之后、保留窗口之前，作为一条独立的 `UserMessage`（内容带系统注记头「以下为此前对话的归档摘要」）——不进记忆区（systemTail 是四域事实的落点，不与叙事摘要混装）；
- **滚动合并**：再次截断时，旧摘要 + 新被裁轮次一起送摘要器，产出单一新摘要替换旧块（摘要体积恒定封顶，`summaryMaxTokens` 复用端侧摘要器口径）；
- **端侧执行**：复用 `ToolResultSummarizer`（`summarizer` 参数）——摘要走端侧本地模型，零计费成本；
- **Run 内滚动，Run 间重算**（MVP 裁决）：摘要缓存挂在 loop 实例（Run 级句柄）。Run 结束即释放，下个 Run 从完整本地 transcript 重算一次。**理由**：本地 transcript 不裁剪（步数墙续跑依赖），重算数据源完整；端侧摘要零计费，重算代价可接受。延迟优化（摘要落 Session 持久化）列为后续演进（§5）。

### 2.3 降级路径（禁静默）

- `summarizer == null`（纯云路径 / 测试）：**保持现行为**——逐轮朴素滑动（windowRounds=6），不进阶梯模式。阶梯是端侧增强，不改变既有降级契约；
- 摘要失败：沿用 `_governedContent` 的 E1 兜底口径——**放弃本轮归档，直接按朴素滑动裁剪放行**（宁可丢归档不失可用性），`[DEGRADE]` 留痕；
- 步数墙放宽续跑：本地 messages 不裁剪的现状不变，阶梯只作用于发送边界。

### 2.4 与既有机制的分工

```
滑动窗口（阶梯化后）：最近 6~12 轮原文——短期保真度
四域提取（workspace_update）：结构化事实 keyed 覆盖常驻——跨轮精确存续
归档摘要（本设计）：被截断批次的叙事滚动摘要——窗口外细节兜底
$ref / 工具摘要：单个超长工具结果——单条体量治理
```

四者正交，互不替代。

## 3. 行为变更登记（须显式验收）

| 变更 | 旧行为 | 新行为 | 验收方式 |
| --- | --- | --- | --- |
| ① 窗口内容 | 恒 6 轮 | 6~12 轮阶梯波动（`summarizer != null` 时） | 单测锚定水位边界；真机长会话冒烟 |
| ② 历史区上下文形态 | 仅原文轮 | 可能含一条归档摘要 UserMessage | 摘要注记头可肉眼识别 |
| ③ 纯云路径 | 朴素滑动 | **不变**（summarizer=null 走旧路） | 存量 windowRounds 测试零改动通过 |

## 4. 实现落点

| 模块 | 改动 |
| --- | --- |
| `context_governor.dart` | 新增 `steppedWindow(messages, {low, step})` 纯函数：返回 `(kept, prunedRounds)`，裁剪点仍只落 Assistant 边界（配对完整性纪律不变）；**实现修正**：裁剪点回退越过紧贴保留轮 Assistant 的 UserMessage——保留轮自己的提问必须随轮走，否则保留区失去提问且语料混入下一轮 prompt |
| `agent_loop.dart` | 挂阶梯逻辑：`summarizer != null` 时以 `steppedWindow` 替代朴素裁剪；新增 Run 级 `_archivedSummary` 状态与摘要装配；摘要失败 DEGRADE 降级朴素滑动 |
| 测试 | `context_governor` 纯函数水位边界用例；`agent_loop` 归档行为用例（fake summarizer）；存量窗口测试不动 |

## 5. 后续演进（本轮不做）

- 摘要落 `ConversationSession` 持久化（省去每 Run 重算；需与 replaceTranscript 语义对账）；
- 截断批次的四域提取补偿（被裁轮次里模型漏提取的事实的二次扫描）；
- 端侧引擎不可用时的云端摘要降级选项（计费敏感，默认不做）。

## 6. 记忆冷热分层与增量压实（Memory Compaction）

### 6.1 核心目标与现状缺口

`systemTail`（记忆区）每 Run 由 `memoryPromptSection` 全量重渲染。**纯新增条目按旧→新顺序追加在尾部，前缀天然稳定；真正的粉碎机是 G1 keyed 覆盖（同 key 就地改写）、remove 与胶囊 undo**——任意一处中间字节变化，其后的阶梯原文窗口（数千 token）全部 Cache Miss。即阶梯窗口「保住了下半身」，记忆区一动「上半身」连带报废。

> **现状缺口（2026-10-16 核对）**：`session` 域事实落 `wsStates`，而 `wsStates` **不注入 prompt**——四域默会提取的默认域（session）目前只落盘不回注。本节 journal 覆盖**注入 prompt 的 user/srv 域**（MemoryStore）；session 域注入列为后续演进（届时其注入区同样适用本协议）。

### 6.2 状态结构（CQRS：展示视图与传输态分离）

不新建事实源——`MemoryStore` + `wsStates` 仍是单点真相（UI 胶囊/≡列表照旧直读 store）。仅新增**传输态投影**（窗口侧持有，会话切换即弃）：

| 字段 | 语义 | 稳定性承诺 |
| --- | --- | --- |
| `frozenBase` | 上次压实时 `memoryPromptSection` 的全量渲染文本 | 周期内**字节级不变** |
| `pendingDeltas` | 本周期内新变更日志（`SET/OVERRIDE/DEL` 行） | **只追加**，禁重排禁原地改 |

### 6.3 Append-Only 变更协议

增量区显式标记行（兼容端侧小模型）：

- `- SET {scope}.{key} = {value}`（周期内该 key 首次出现）
- `- OVERRIDE {scope}.{key} = {value}`（周期内该 key 已有记录的再次变更）
- `- DEL {scope}.{key}`（模型 remove 或胶囊 undo——**undo 同样走 DEL 行**，append-only 连撤销也覆盖）

约束：周期内增量区禁按 `serverScopes`/domain 过滤重排（会打乱增量区内部前缀）；过滤推迟到压实渲染时统一执行。

### 6.4 Tick 调度：Run 边界同频 + 机会主义压实

压实判定在 `chat_page._send` 组装期（严禁挂 loop 内——systemTail 是 Run 级组装的），与阶梯截断**同频同源**：

1. **常规 Tick**：transcript 可用轮数 > 高水位（`windowRounds + windowStep`）——此时滑窗截断本就要断前缀一次，压实顺车；
2. **TTL 机会主义**：距上次 Run 结束 ≥ 5 分钟（服务商 ephemeral 缓存已注定失效，冷启动反正要付）——提前压实白嫖这次冷启动；
3. **Token 突发兜底**：transcript 估算 token 超 `kTickTokenBudget`（轮数未到但体量爆窗时强制 Tick）。

同帧操作：`frozenBase = memoryPromptSection(全量现渲染)` → `pendingDeltas = []` → 新周期开始。快照渲染含预算截断（droppedCount 语义不变）。

### 6.5 物理组装序：Delta 后置（Post-History Injection）

前缀匹配要求**绝对字节位置**匹配——增量区若插在快照与历史之间，新增一行会把其后全部原文窗口整体推移 30+ token 位置，等价于全灭。因此**高频变化项必须沉底**：

```text
[System 静态前缀]                      ← 长期缓存
[systemTail = frozenBase]              ← 周期内字节不变
[阶梯窗口原文 6~12 轮]                  ← 周期内单调追加
--------------------------------------- ← 绝对稳定超级前缀
[contextFooter = pendingDeltas 压实行]  ← 唯一周期内变化点（沉底）
[本轮提问]
```

实现：`agent_loop.run` 新增 `contextFooter` 参数（UserMessage 形态插在 history 之后、userPrompt 之前，经 `escapeUserTag` 消毒）。附带近因效应收益：delta 紧贴当前提问，端侧小模型对 OVERRIDE 的感知显著增强。

### 6.6 周期内 Squash（惰性幂等裁剪）

组装时对 `pendingDeltas` 做 last-wins 折叠：同 key 多条只保留**最终有效态**一行（`SET/OVERRIDE` 归并为单行；终态 `DEL` 保留）。delta 已处尾部动荡区，折叠零缓存代价——收益是消除端侧模型的同 key 冲突值共存（降幻觉）+ 省 delta token。

### 6.7 单向栅栏（Yield Barrier）

`_send` 入口对 journal 做不可变快照用于本 Run 组装；本 Run 流式中 `onCapsule` 产生的新变更只进 pending 池、下一 Run 生效。保证单次 Run 从组装到 loop 启动数据不可变，杜绝「提取落库与组装的竞态抖动」。

### 6.8 预算合并口径

`len(frozenBase) + len(squashed deltas) ≤ memoryPromptSection 原有预算上限`。delta 区受批次步长（≤6 轮提取产出）自然封顶；快照超限走既有 droppedCount 截断；组合超限时触发提前压实（同 6.4 第 3 条）。
