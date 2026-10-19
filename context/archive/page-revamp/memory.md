---
dev-loop: memory
format: v1
epic: page-revamp
total-merged: 1
last-merge: 2026-10-14
---

# page-revamp

- [挂载] docs/design/page-revamp.md

## 结论与决策

- **主题注入（P0）**：console_tokens 增 light/dark 双套静态 token（浅套语义色降档 600 提对比、深套 hairline/codeBg 白基）；main.dart App 级注入 theme+darkTheme（随系统），chat/services_hall/memory_board/gateway_debug 四页删自拼 ThemeData 壳
- **破坏性操作防护（P0）**：端点删除二次确认弹窗（连带清令牌，与删会话/BYOK 同口径）；ChatPage PopScope——Run 进行中系统返回先弹确认再 abort 退出；await 后 State.context + mounted 守卫
- **设置拆分（P1）**：端点表单迁出为 components/server_endpoint_forms.dart（走 console tokens）；服务大厅节点卡接全生命周期（行内编辑/删除+添加入口+空态引导）；chat_page ⚙ 设置瘦身，端点 CRUD 删除换服务大厅导航
- **交互优化（P1）**：ABORT 移至状态胶囊右侧（§3.1 红色文本，Key capsule-abort，仅运行态）+ 触发重度确认震动（§4.1）；输入框运行中可预输入，发送按钮禁用态（_send 自挡 running）
- **Token 纪律**：'monospace' 硬编码 ×12 全量替换 t.monoFamily；inversePrimary AppBar ×2 去除走默认主题；trust_plugin_dialog 改块体接 t
- **动效（P2）**：StatusCapsule 状态点 / CallCard 状态竖条改 AnimatedContainer 颜色过渡；L1 药丸收尾 selectionClick 轻微 tick；均消费 fastDuration token（180ms 禁 Spring）
- **P2 收口**：DualTrackStream 灰阶通告收敛为可折叠 Run 概要条（危险 Rose 独立凸显）；TrackNote/BreakerCard 错误摘要改 SelectableText；ServicesHallPage 进页自动探活（autoProbe 参数，测试注 false）
- **拍板：不引 url_launcher**：RichTextView 行内链接/媒体降级行改 WidgetSpan+GestureDetector 长按复制 URL（零新依赖），semanticsLabel 保留
- **低优清零**：console_tokens 新增 Fsz 字号 token 表（ui-design §2 双轨），全仓 16 文件 ~140 处 fontSize 字面量机械替换；rich_text_view 长按复制加「✓ 已复制链接」Toast（1500ms）

## 近期验证状态

- 全部九轮均复跑 flutter analyze（0 新增，存量 1 info 不变）+ flutter test test/ui + widget_test 共 55 例全绿

## 归并补充（2026-10-19 · 自 devlog 14 条提炼，含 2 条 SSOT 修正归纳）

- **UI 可用性整改 A~G 全批（2026-10-14，对 ui/ 全页面走查 27 项发现）**：A 交互反馈——运行中发送/新会话/切换/设置/菜单由静默禁用改 SnackBar 说明原因；键盘 action=newline 与 onSubmitted 矛盾改 TextInputAction.send；ClaimLoopPage 输入框跑完一次后永久禁用改 `!_running`。B 流式滚动——`_pinToBottom` 每 40ms 劫持改「用户上翻暂停自动跟随 + 回底 FAB」。C 术语外泄——胶囊英文相位人话化（idle→空闲等）、遥测通告改用户可读措辞、裸异常加「任务中断:」前缀、卡死文案改「响应停滞，可用 [ABORT] 中止」。D 破坏性语义——删会话/服务/模型确认按钮统一 Rose；步数墙/熔断卡按钮语义纠偏（终止=Rose 主按钮，放宽/重试=常规）；网关开关加不鉴权风险提示；跨源授权卡 barrierDismissible=false + 锁态时间戳 ISO→HH:mm。E 用色——BYOK「生效中」Amber→L1 Emerald。F 信息架构——服务大厅面板按频率重排（节点→模型→覆写→授权）、联调入口 kDebugMode 门禁、⚙ tooltip「连接配置」→「设置」+ 弹层加标题、AppBar 显示会话标题。G 卡片——确认卡加「理由仅拒绝时回传」说明、CallCard 终态结果可展开全文、Abort 的 progressNote 进序列化（恢复不丢）、损坏会话提示改 SnackBar（不再串台写进当前会话快照）、update_page 字号魔法值收敛 Fsz。
- **输入条合体 + 状态相位内嵌（2026-10-14 用户拍板）**：输入框+发送钮由「分离两截」合并为单容器药丸输入条（hairline 1px 描边 + cardColor 底，发送钮内嵌右下 36×36 compact）；thinking/failed 等相位由顶部独立胶囊行改输入条左位内嵌（7px 语义点 + 等宽人话相位，maxWidth 132 截断），[ABORT] 随动输入条右侧（仅运行态），顶部常驻「空闲」行整体移除；StatusCapsule 组件保留（联调页 + 单测复用）。**[SSOT]** `chat-interaction.md` §1 三段式 = 「流｜输入条(状态+输入+发送)」；`ui-design.md` §3.1 形态 = 「输入条内嵌」，原顶部胶囊形态标废弃（组件留用）。
- **阅读轨表格错乱修复**：`rich_text_view.dart` TableBlock 根因 = Table 默认 FlexColumnWidth(1) 在横向滚动无限宽约束下塌成 0 宽致单元格重叠；改 `defaultColumnWidth=IntrinsicColumnWidth`（按内容自适应，超宽走横向滚动）+ 接 parser 透传的列对齐 align（左/中/右）；dual_track_stream_test 补表格渲染回归。
- **服务大厅 → 设置页合并（P1 终态，2026-10-16）**：`services_hall_page.dart` → `settings_page.dart`（类 `SettingsPage`）；聊天页 `_openSettings` 弹层（243 行）整体删除，⚙ / 侧边栏 / M1 页直接 push 设置页，debug 菜单重复项删除；六段重排（BYOK → 节点卡 → 本地插件 → PC 远程网关 → Skill 覆写 → 跨源授权）。净新增 = **PC 远程网关面板**（:8766 起停 + 配对 Token + 局域网暴露 ⚠ 文案，自 ⚙ 迁入）；真缺口补齐 = **本地插件撤销信任**（撤销语义 = 仅移出白名单——信任闸门是装配期校验：本机下轮重弹卡、网关侧跳过，不动连接池）。文件头加 scope 声明：设置 = 服务与引擎配置，记忆看板/更新/会话历史不并入。`chat_page` 1980→1734 行（-246）、`settings_page` 1653→1789 行。
- **[SSOT] 命名映射（2026-10-16）**：历史文档（m4/m3/m2-5/chat-interaction）保留「服务大厅」原文 + 加名词映射注；现行文档（architecture/requirements/coding-standards/index）直接改新名「设置页」。
- **聊天页 AppBar 清空（2026-10-16）**：⚙ 设置按钮移除（设置入口只在侧边栏），debug 入口收进设置页新增「关于」段；**检查更新**是 release 正式功能故常驻可见（不藏），网关联调 / M1 任务循环改长按「关于」标题唤出（`kDebugMode` 内自闸，debug 构建给出提示文案）；ChatPage 同步删 `_openDebugMenu` + 3 个失效 import；空态/菜单文案「⚙ 设置页」→「侧边栏 → 设置页」。

## 断点
- [断点] 下一步：page-revamp 评估报告整改项（P0/P1/P2+低优，九轮 + 输入条合体/设置页合并两批）已全部清零；下一步 = 建议 git 提交批次改动，后续 = 设备端 UI 冒烟（交用户）或新需求开工
