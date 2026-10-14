---
status: active
updated: 2026-10-14
---

# 流式输出性能优化

> 背景：主流 AI 客户端（ChatGPT Web / Claude / Cursor）化解流式卡顿的分层防御（流控层 →
> 容错预处理 → 渲染隔离 → 高开销降级）在 goodhub 的落地评估与裁剪。评估结论（2026-10-14
> 用户拍板立项）：**只做流控层（P0）与渲染层前缀缓存（P1）**；容错预处理层由现有
> 纯函数 parser 的 EOF 语义天然满足，高开销降级层当前无对象（无语法高亮）。

## 1. 现状热路径（对账基线）

```
SSE chunk → parseSse → CloudTextDelta → LoopTextDelta
  → chat_page._appendText(delta)        # 每个 delta 一次 setState + _pinToBottom
  → DualTrackStream.build → renderEntry(TrackText)
  → MarkdownSubsetParser().parse(全文)   # 每个 delta 一次全文重解析（O(n²) 累积）
  → RichTextView 全量重建所有块 widget   # 无缓存、无 RepaintBoundary
```

零节流、零缓存。长回答（AgentLoop 单轮可达数千字符）累计解析量 O(n²)，是卡顿根因；
底层 AST 算法无需改动（`../rich_text` 为跨仓共享包，纯函数全量 parse 语义稳定）。

## 2. 分层裁剪决策

| 业界维度 | goodhub 裁定 | 理由 |
|---|---|---|
| 流控 Buffer & Batching | **做（P0）** | 现状零节流；`StreamTextBuffer` 40ms 节拍批量刷盘 |
| 流式虚拟闭合 | 不做 | `_FenceSyntax` 未闭合围栏「吃到文末」产 CodeBlock，parser 段落恒兜底，AST 恒合法 |
| 块级 DOM/Widget 隔离冻结 | **做（P1）** | 前缀块缓存 + 安全切点增量解析 + `RepaintBoundary` 隔离稳定前缀 |
| 代码高亮/公式延迟计算 | 不做（未来约束） | 当前 CodeBlock 即纯等宽文本、公式子集外降级；将来加高亮时遵循「流式纯文本、闭合帧异步激活」 |

Web → Flutter 术语映射：RAF 批处理 → `Timer` 节拍合并（setState 本身按帧合并，节流同时
降 parse 频次）；CSS `contain` → 稳定块 widget 实例复用（Element 复用跳过 layout）+ 前缀
`RepaintBoundary`（跳过 paint 重录）。

## 3. P0 流控层设计

- `StreamTextBuffer`（`lib/ui/components/stream_text_buffer.dart`，纯 Dart 可单测）：
  delta 入池，40ms（≈25fps）节拍定时器批量回调；`flush()` 强制清空（取消节拍 + 残余
  立即刷出）；`dispose()` 取消定时器。
- chat_page 接线：`_appendText` 改入池；刷盘回调 = 原 setState 写 `TrackText` +
  `_pinToBottom`（两者同一节拍，消除「每 delta 一次 post-frame 跳转」）。
- **尾帧铁律**：`_send` 的 `finally`（覆盖正常收尾 / Abort / 异常三条路径）在
  `_persistConversation()` 之前必须 `flush()`——会话快照与终态渲染都以 `_track` 为准，
  缓冲期内到达的尾帧不得丢失。`dispose` 取消定时器（不刷盘：widget 已销毁）。

## 4. P1 前缀块缓存设计

`StreamingBlockCache` + `StreamingRichText`（`lib/ui/components/streaming_rich_text.dart`）：

- 状态：`_stableBlocks`（已稳定 AST，只增不减）、`_stableLen`（稳定前缀文本长度）、
  `_tailBlocks`（活跃尾部，每次更新重解析）、`_hasRefDefs`（引用定义闩锁）。
- 渲染：稳定前缀包 `RepaintBoundary` + 缓存 widget 实例（跨 build 同一实例 → Element
  复用跳过 layout/paint）；尾块走 `RichTextView` 重建。主题切换无需失效缓存
  （RichTextView 的 Element 自行依赖 Theme 注入，InheritedWidget 变更标记其重建）。
- **安全切点**（切点前后增量 parse 结果拼接 ≡ 全量 parse，正确性核心）：
  切点只取**已完结行**（`\n` 终止）的行边界——末行未完结时其行分类可被后续 delta
  撤销（`---`→`--- |`、` `→`  i`、`$$x`→`$$x y`、分隔线→非分隔线），会把已稳定
  边界回头吞掉（等价性 fuzz 实证的三类分叉，2026-10-14）。幻尾行被此条泛化排除。
  前缀扫描状态须干净（不在未闭合围栏 / 数学块内），且尾行（切点后第一行）满足
  以下之一才可切：空行 / 硬块起始（围栏、分隔线、标题、引用、bullet/ordered
  列表项、整行媒体、数学块开头行）；以下跨行上下文一律禁切：
  - 前缀处于未闭合代码围栏内（围栏内容跨切点）；
  - 前缀处于未闭合数学块内（`$$` 开头行吃到含闭合 `$$` 的行；`_MathBlockSyntax`
    精确镜像：裸 `$$` 行不开闭、`$$x$$` 开闭同行、闭合行须闭合后仅空白）；
  - 尾行是引用行且前缀末行也是引用行（引用块跨行吸收）；
  - 尾行是列表项且前缀末行被列表吸收（列表项 / 缩进续行 / 裸待办）；
  - 尾行是裸待办行（`[ ] x`）——**不是硬块起始**：parser 的 `_isBlockStart`
    不含 `_todo`，开放段落会吸收它，一律禁切（保守）；
  - 尾行含 `|` 且前缀末行含 `|`（开放表格按列数吸收一切含管道行，含被列表/
    引用/数学正则误中的行）；
  - 尾行是表格起始且前瞻分隔行未完结（`--- | -` 可长成 `--- | -x` 撤销资格）。
- **引用定义闩锁**：`parse()` 首遍全文收集 `[id]: url` 定义并剥离定义行、二遍重写
  `[text][id]`——定义可被文中任意位置引用，故全文一旦出现引用定义行即放弃增量
  （退化为全量 parse，正确性优先）。
- 规范化：widget 入口先把 `\r\n?` 归一为 `\n`（与 parser 内部同口径），切点坐标在
  归一化文本上维护。
- **数学块渲染降级**（随共享包 2026-10-14 演进 adopt）：`MathBlock`/`InlineMath`
  在 `rich_text_view.dart` 以 LaTeX 源码 + `$$`/`$` 定界符等宽呈现（不引 KaTeX，
  「样式平不吞内容」）。

## 5. 等价性验证（写死门禁）

- 切点安全性 fuzz：对语料生成器产出的文本（段落/列表/引用/表格/围栏开闭/$$/引用定义
  混排），枚举所有行边界切点，凡扫描器判定安全的切点，断言
  `parse(前缀) + parse(尾部) 逐块 serialize ≡ parse(全文)`。
- 渲染行为：递进喂 delta，终态渲染文本 ≡ `RichTextView(parse(全文))`。

## 6. 预期收益

- setState/parse 频次降 ~25 倍（40ms 节拍 vs 每 delta）；
- 流式期间稳定前缀跳过 layout/paint，渲染开销收敛到尾块；
- 长列表/长代码块流式期间尾部重解析范围限于当前块。
