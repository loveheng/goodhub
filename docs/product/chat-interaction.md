---
status: active
updated: 2026-10-17
---

> **名词映射（2026-10-16）**：本文件中的「服务大厅」= 现**设置页**（`lib/ui/settings_page.dart`）——聊天页 ⚙ 设置弹层已并入服务大厅并统一改名「设置」。历史决策/施工原文**保留不替换**，代码与现行文档以新名为准（合并记录见 [page-revamp.md](page-revamp.md)）。

# GoodHub 交互设计 · 双轨消息流（聊天主页）

> 本文是宿主聊天交互的 **SSOT**（信息架构 / 交互流 / 轨道语义）；视觉语言 SSOT = [ui-design.md](../project/ui-design.md)（tokens 落点 `.agents/skills/goodhub-ui`），本文不重复视觉规格。来源：F5.1 / U1（requirements.md）+ architecture §5/§10/§15 + M4-T3（[../design/m4.md](../design/m4.md)）。工程实现 = `lib/ui/chat_page.dart`（M4-T3）。
> 立项：2026-10-11，自 M4-T2 收官移交。**D9/D10/D11 已拍板（2026-10-11）**：D9 = 聊天页接管应用首页（M1 任务循环页降 debug 入口，服务大厅/联调入口移聊天页工具栏）；D10 = 对话历史**落盘可恢复**（T3 先落内存态，持久化拆 T3b：ConversationStore + 会话列表 + 恢复装配）；D11 = 同页多轮上下文共享（messages 跨 run 累积，§15 对齐；AgentLoop run 增 history 入参 + LoopFinished 回 transcript）。

## 1. 信息架构

- **三段式**：中部双轨消息流（阅读轨 + 操作轨**同轴混排**，ui-design §3.2）｜底部输入栏（多行自适应 + 内嵌发送钮）｜**状态内嵌输入条**（2026-10-14 拍板：thinking/failed 等相位从顶部独立胶囊行收敛进输入条左位，顶部不再常驻「空闲」行；右位 `[ABORT]` 仅运行态出现）。
- **输入区触达与运行态形变（page-beautify B3/B4/C3，2026-10-17）**：`+` 上下文钮触达区 48dp（视觉不变）；发送↔中止单槽形变 = 底色 180ms 过渡 + 图标交叉缩放淡入（ui-design §4.2），运行态 Crimson 实底白图标不变；上下文胶囊点击附轻触觉确认（受状态带 30px 高度约束，chip 不追 48dp 全触达）；输入框聚焦时药丸边框 hairline→l1Info 180ms 过渡、失焦即回（原恒 hairline 无 focus 反馈）。
- **Enter 键平台语义（page-beautify B1，2026-10-17）**：输入框多行自适应（maxLines 4）下，Enter 键按平台分化——**移动端软键盘 Enter=换行**（多段任务可输入；SDK 语义：multiline 字段 newline 动作由平台直接插入换行字符、不触发 onSubmitted，editable_text.dart:3740），**桌面端 Enter=发送**（肌肉记忆保留）；发送统一走输入条右下主钮（运行态形变为中止键）。**沿革**：2026-10-14 page-revamp 曾因**单行输入**「action=newline 触发 onSubmitted 发送」的矛盾改 `TextInputAction.send`——多行化后该矛盾不复存在，本次为语义重定而非翻案；hint 文案随平台显示「Enter 换行」/「Enter 发送」。
- **运行中**：输入栏保持可预输入，但发送/新会话/切换会话/设置等动作触发时给 SnackBar 说明「任务运行中，需等待结束」（M 阶段不排队——一次一个 Run，§15 前台会话语义；禁止静默禁用）；胶囊常驻 + `[ABORT]` 高反差入口（运行态主操作槽形变为 Crimson 实底停止键，ux-hardening P1-4）；状态带运行态显示已耗时（mm:ss）；**工具结束胶囊回「思考中」而非「空闲」**——工具完成 ≠ Run 完成，防用户中途误判（P1-4）。
- **冷启动引导（ux-hardening P0-1，2026-10-16）**：未配置服务端点且无本地插件时，发送**不整页跳转**——轨道内插引导卡（说明 +「去配置」按钮），输入内容保留、返回即可续发；用户从设置返回后按配置状态摘除/保留引导卡。引导卡为**瞬态条目**（动作回调不可序列化）：不持久化、不出现在恢复会话，由页面按当前配置状态重插。
- **首页接管（D9）**：`main.dart` home = ChatPage；服务大厅入口移聊天页 AppBar；联调页与 M1 任务循环页降 kDebugMode 入口。
- 联调页（gateway_loop_debug_page）降级为纯 debug 工具，正式面由本页承接。

## 2. 事件 → 轨道映射（AgentLoopEvent 为唯一数据源）

| AgentLoop 事件 | 轨道呈现 |
|---|---|
| 用户发送 | **TrackUser**：Indigo 竖条卡（数据指针色 + 「你」等宽标签）——同轴卡片族，拒绝左右气泡 |
| `LoopTextDelta` | 阅读轨流式追加（RichTextView Markdown 渲染，同一 TrackText 重建不碎卡） |
| `LoopToolCallStarted` | 操作轨插 CallCard（Emerald 执行中） |
| `LoopToolProgress` | 卡片微型进度标注（`p/total · message`）+ 胶囊同步 |
| `LoopToolCallFinished` | 卡终态锁定：成功 Emerald / 失败 Rose / 拒绝显示 reason / Abort 灰阶 `⊘ Cancelled`（区别 Failed，§10） |
| `LoopFinished` | 阅读轨收尾（text 非空时）+ 胶囊回 idle + **transcript 落会话历史**（D11 续接口径） |

- **卡片组件全量复用 M2/M3 正式实现，不另造**：L2 确认卡（GateDelegate → ConfirmationCard，含 C7 会话豁免勾选）、熔断排查卡（BlockDelegate → BreakerCard 三操作）、围栏拦截卡（FenceBlockCard 双选项）、跨源授权卡（CrossSourceConsentCard）。
- **决策卡白话层（ux-hardening P1-6）**：卡片选项必须附后果说明——BreakerCard 三操作（单步重试/跳过/人工接管）与步数墙两操作（放宽/终止）、跨源授权双选项（允许/拒绝）均有一句话后果文案；围栏卡正文即后果说明（既有）。状态带相位去黑话：breaker/fence 显示「工具报错，待处理 / 敏感信息，待确认」。
- **运行中菜单语义（page-beautify A5，2026-10-17）**：运行中**可打开**会话上下文菜单查看当前绑定与可用服务（只读零成本）；**切换绑定/清空**才被守卫拦下（sheet 内置灰 + 说明行「任务运行中：可查看，暂不可切换绑定」+ SnackBar 原因）。原一刀切「运行中禁开菜单」已废弃。
- **设置入口（page-beautify A6，2026-10-17）**：AppBar 右侧常驻 ⚙ 直达设置页（服务大厅/端点/BYOK）——抽屉底部入口保留作次要路径。
- **状态带常驻策略（page-beautify B6，2026-10-17）**：输入条内嵌状态带**仅运行态展开**（30px）——idle 期收起（原「空闲+灰点」常驻占黄金垂直空间）；私有绑定的弱感知改由**输入行上下文胶囊**承担（仅私有态显示，公共态 idle 不占位），running 期胶囊回到状态带，两处同组件同源。
- **轮次标识与完成反馈（page-beautify C4/C6，2026-10-17）**：助手文本轮次带极轻「GoodHub」等宽灰标（与用户轮「你」标签对称，长会话轮次边界可辨）；「✓ 任务完成」脱离 Run 概要折叠、单独 Emerald 成行（重要反馈不被遥测通告稀释）。
- **工具名人话化（page-beautify A2，2026-10-17）**：状态带与 CallCard 优先显示服务端 description 首子句（中文人话，至首个句读/左括号或 16 字硬截）——工具执行期胶囊显示「执行中 · <人话动作>」、进度同步人话标签；CallCard 头部等宽遥测轨保留原始 `<serverId>__<tool>` 前缀名，其下灰阶人话行可展开全文（SelectableText）。无 description（宿主本地工具/旧数据）回退裸工具名或零痕迹；描述全文经 codec 持久化，恢复会话人话行不丢。
- **归因条降噪（P1-6）**：本轮上下文归因 pill 仅在**携带记忆注入或超预算丢弃**时出现——「服务 N 个」与输入条状态带的上下文胶囊重复，每轮必出属遥测噪音；详情仍可点开 BottomSheet 查看。
- 错误路径（连接失败/装配失败/流异常）以 Rose **错误行动卡**进轨道（ux-hardening P0-2）：白话标题 + 下一步建议 + 可复制原始异常 + 「重试」入口（重跑上一句，重试后卡片锁定「已重试」）；恢复会话的错误卡锁定为不可重试。不弹裸对话框。
- **工程实现**：`lib/ui/chat_page.dart` + `lib/ui/components/dual_track_stream.dart`（公共组件，T3b 恢复装配复用）；阅读轨渲染 = `RichTextView`（D12 拍板：goodshare 自写 parser 随迁 + 宿主只读渲染器，弃 flutter_markdown 系三方包）。

## 3. 会话生命周期（§15 会话模型对齐）

- **页面 = 一个会话**：AgentLoop 实例 + SkillRegistry 激活集（+ RefStore 会话粒度）随页面建立；发送 = 一次 `run()`，**同页多轮上下文共享**（D11：上轮 transcript 作下轮 history 传入——滑动窗口在发送边界裁剪，本地历史不裁，§12/T6 既有口径）。
- **Abort**：胶囊 `[ABORT]` → `loop.abort()` + `face.cancelActiveRequest()`（§10 级联，M3-T2 已落语义）→ 卡片 Cancelled 终态。
- **页面退出 = 会话焚**（激活集/RefStore 即清，§9/§15）；记忆沙盒（T2）跨会话持久。
- **历史持久化（D10）**：T3 落内存态（页面退出焚）；**T3b 落 ConversationStore**（`lib/sandbox/`，每会话一 JSON：轨道条目 + CloudChatMessage 序列化——assistant/tool 结果配对完整是恢复前提，拆对即协议 400）+ 会话列表页 + 恢复装配。
- **会话管理（ux-hardening P1-5）**：侧边栏支持标题搜索（本地过滤）、重命名（只改标题不动 transcript，updatedAt 保留不打乱列表序；当前会话重命名时内核同步 `_currentTitle` 防覆盖）、删除（确认对话框）；列表元信息 = 更新时间 · 消息条数。
- **会话记忆入口（page-beautify B2，2026-10-17）**：本会话提取的记忆胶囊（⚡ 已记录）汇总列表入口 = **AppBar 右侧 Bolt 图标**（仅存在胶囊时出现，首颗入轨即亮；点击弹 BottomSheet 纯展示列表，撤销仍走流内胶囊通道）；「回到最新」为消息流**唯一悬浮钮**（离底淡入 180ms，ui-design §4.2）。原右下双 FAB 堆叠（主次不分 + reorder 表意弱且与归因 ≡ 撞车）已废弃。

## 4. 连接配置（M 阶段过渡态）

- 服务端点 + API Key：页内设置弹层（SharedPreferences 持久化）；M4-T5 服务大厅 Server 节点/BYOK 面板落地后迁移收编。

## 5. 边界（不在 T3）

- 胶囊系统化（应用内胶囊 → 系统通知/悬浮）——M3-D2 拍板独立评估不纳入；
- 会话历史持久化 → **T3b**（D10 拍板拆分）；语音/多模态输入；@提及与工具补全；iOS Live Activity；
- 装配线与联调页暂各自持有（chat 页生产子集：无故障注入/脚本引擎）；T5 大厅余项落地时统一装配线收编。

## 6. 验收口径

- widget 测试：事件流→轨道映射（五类事件）、Abort 终态灰阶 `Cancelled`、L2 卡经 GateDelegate 拒绝回填 `user_rejected`；AgentLoop history/transcript 单测（多轮上下文）。
- 真机联调第三批（T5 收官）：自然语言 → 工具环 → L2 卡 → 回显全链；update_memory 经聊天页 L2 卡可视；Abort 半程明示。
