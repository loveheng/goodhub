---
dev-loop: memory
format: v1
epic: stream-perf
total-merged: 1
last-merge: 2026-10-14
---

# stream-perf

- [挂载] docs/design/stream-perf.md

## 结论与决策

- [立项] 2026-10-14 用户拍板：主流 AI 客户端四维分层防御（流控/虚拟闭合/渲染隔离/高开销降级）在 goodhub 裁为两维——P0 流控 + P1 前缀块缓存；虚拟闭合由纯函数 parser 的 EOF 语义天然满足（未闭合围栏吃到文末产 CodeBlock），高亮降级当前无对象（无语法高亮）
- [结论] P0 流控层：`StreamTextBuffer`（`lib/ui/components/stream_text_buffer.dart`）40ms 节拍 Token 缓冲池（delta 入池、批量刷盘、单定时器搭车）；chat_page `_appendText` 改入池，`_onStreamFlush` 同一节拍落地 setState + `_pinToBottom`；`_send` 的 finally 覆盖正常收尾/Abort/异常三路径强制 `flush()`（尾帧不丢，快照前清空）；dispose 为终态（add/flush 静默 no-op）
- [结论] P1 前缀块缓存：`StreamingBlockCache` + `StreamingRichText`（`lib/ui/components/streaming_rich_text.dart`）——稳定前缀 AST 只增不减 + 活跃尾块重解析；稳定前缀包 `RepaintBoundary` + 缓存 widget 实例跨 build 复用（Element 复用跳 layout、边界图层跳 paint）；parser 零改动（共享包 `../rich_text` 纯函数，不造增量状态机）
- [结论] 安全切点规则（fuzz 实证修正后定稿，stream-perf.md §4 SSOT）：只切**已完结行**边界（末行未完结时行分类可被 delta 撤销，会回头吞掉已稳定边界）；前缀扫描状态干净（不在未闭合围栏/数学块内）；尾行须为 空行/硬块起始；禁切跨行上下文——引用续行、列表续行（列表项/缩进续行/裸待办）、裸待办行（parser `_isBlockStart` 不含 `_todo`，开放段落吸收之）、开放表格含管道行（管道规则前置全分类裁决）、表格起始的前瞻分隔行未完结、引用定义全文闩锁（定义可被任意位置引用）。fuzz 曾实证三类分叉推动定型：末行分类撤销 / 裸待办被段落吸收 / 表格分隔线资格撤销
- [结论] 共享包 `../rich_text` 演进 adopt（2026-10-14）：新增 `MathBlock`/`InlineMath`（`_MathBlockSyntax` 注册表第 3 位，`$$` 开头行跨行吃到闭合 `$$`，未闭合降级段落；`_isBlockStart` 含 `$$` 开头行）；goodhub `rich_text_view` 降级等宽呈现（LaTeX 源码 + 定界符，不引 KaTeX，「样式平不吞内容」）；切点扫描精确镜像数学块语义；goodshare 侧 adopt 仍待协同
- [note] `dual_track_stream` 的 TrackText 渲染改走 `StreamingRichText`（parse 从 `renderEntry` 收编）；既有 `dual_track_stream_test`「阅读轨」断言随架构改为 findsNWidgets(2)（稳定+尾块双渲染器）

## 近期验证状态

- flutter analyze 0 新增（存量 2 info 不变）；flutter test --timeout 120s 全量 **442 绿**（409 基线 + 33 新增）；docs-lint 通过；streaming_rich_text_test 27/27（切点逐规则 + 禁切分叉反证 + fuzz A/B/C/D 等价性门禁 + widget 行为）；stream_text_buffer_test 6/6

## 断点
- [断点] 下一步：真机流式冒烟(长回答/代码块/表格场景看帧率与尾帧完整性);后续可选=稳定前缀切点扫描 memoize(长段落无切点场景省重复扫描)
