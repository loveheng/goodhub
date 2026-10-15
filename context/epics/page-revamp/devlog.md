---
dev-loop: devlog
format: v1
epic: page-revamp
total-merged: 1
last-merge: 2026-10-14
---

（开发过程日志按行追加：[变更]/[验证]/[note]/[SSOT 修正]；≥5 条自动归并进 memory.md——dev-loop §2）
- [2026-10-14] [变更]: UI 可用性整改（对 ui/ 全页面走查，27 项发现，本批落地 A~G 全批）。A 交互反馈:运行中发送/新会话/切换/设置/菜单由静默禁用改为 SnackBar 说明原因;键盘 action=newline 与 onSubmitted 发送矛盾改 TextInputAction.send;ClaimLoopPage 输入框跑完一次后永久禁用改 !_running。B 流式滚动:_pinToBottom 每 40ms 劫持改用户上翻暂停自动跟随+回底 FAB。C 术语外泄:胶囊英文相位人话化(idle→空闲等);「引擎/Tier/记忆注入/收尾 N 轮」等遥测通告改用户可读措辞;裸异常加「任务中断:」前缀;卡死文案「无更新超阈值」改「响应停滞,可用 [ABORT] 中止」。D 破坏性语义:删会话/服务/模型确认按钮统一 Rose;节点卡删除与挂载开关加间距;步数墙/熔断卡按钮语义纠偏(终止=Rose 主按钮,放宽/重试=常规);网关开关加不鉴权风险提示;跨源授权卡 barrierDismissible=false+锁态时间戳 ISO→HH:mm。E 用色:BYOK「生效中」Amber→L1 Emerald。F 信息架构:服务大厅面板按频率重排(节点→模型→覆写→授权);联调入口 kDebugMode 门禁;⚙ tooltip「连接配置」→「设置」+弹层加标题;AppBar 显示会话标题;服务大厅进调试菜单全构建可达。G 卡片:确认卡加「理由仅拒绝时回传」说明;CallCard 终态结果可展开全文(resultText 进 codec);Abort 的 progressNote 进序列化(恢复不丢);损坏会话提示改 SnackBar(不再串台写进当前会话快照);update_page 字号魔法值收敛 Fsz
- [2026-10-14] [验证]: flutter analyze 0 新增(仅存量 gateway_loop_debug deprecation info);flutter test --timeout 60s 全量 443 绿;服务大厅 CoW 测试补 dragUntilVisible 滚动助手适配面板重排;cross_source 锁态时间戳断言同步改 HH:mm
- [2026-10-14] [变更]: 首页输入条合体:输入框+发送钮由「分离两截(独立圆角框+外挂圆形钮)」合并为单容器药丸输入条(hairline 1px 描边+cardColor 底,发送钮内嵌右下,36x36 compact);运行中反馈/Enter 发送语义不变
- [2026-10-14] [验证]: flutter analyze 0 新增;flutter test --timeout 60s 全量 443 绿(widget_test 的发送 tooltip 断言不变)
- [2026-10-14] [变更]: 状态相位收敛进输入条(用户拍板): thinking/failed 等由顶部独立胶囊行改为输入条左位内嵌(7px 语义点+等宽人话相位, maxWidth 132 截断); [ABORT] 随动到输入条右侧(仅运行态); 顶部常驻「空闲」行整体移除, 省一行并消空闲噪音; StatusCapsule 组件保留(联调页+单测复用)
- [2026-10-14] [SSOT 修正]: chat-interaction.md §1 三段式改「流｜输入条(状态+输入+发送)」; ui-design.md §3.1 形态改「输入条内嵌」, 原顶部胶囊形态标废弃(组件留用); analyze/test 复验 443 绿
- [2026-10-14] [变更]: 阅读轨表格错乱修复(rich_text_view.dart TableBlock): 根因 Table 默认 FlexColumnWidth(1) 在横向滚动无限宽约束下塌成 0 宽致单元格重叠; 改 defaultColumnWidth=IntrinsicColumnWidth(按内容自适应, 超宽走横向滚动); 顺手接 parser 透传的列对齐 align(左/中/右)
- [2026-10-14] [验证]: 新增 widget 回归(dual_track_stream_test 表格渲染: 断言 Table.defaultColumnWidth 为 IntrinsicColumnWidth + 3 行 + 对齐); flutter analyze 0 新增(仅存量 gateway_loop_debug deprecation info); flutter test 全量 444 绿
- [变更] 2026-10-16 服务大厅 → 设置页合并（P1 终态）：`services_hall_page.dart` → `settings_page.dart`（类 `SettingsPage`）；聊天页 `_openSettings` 弹层（243 行）整体删除，⚙ / 侧边栏 / M1 页直接 push 设置页，debug 菜单重复项删除；六段重排（BYOK → 节点卡 → 本地插件 → PC 远程网关 → Skill 覆写 → 跨源授权）。
- [变更] 唯一净新增 = **PC 远程网关面板**（:8766 起停 + 配对 Token + 局域网暴露 ⚠ 文案，自 ⚙ 迁入）；真缺口补齐 = **本地插件撤销信任**（原设置弹层有 `trusted.remove`、大厅只有 `_trustPlugin`）。撤销语义=仅移出白名单（信任闸门是装配期校验：本机下轮重弹卡、网关侧跳过），不动连接池。文件头加 scope 声明：设置 = 服务与引擎配置，记忆看板/更新/会话历史不并入。
- [验证] `flutter analyze` No issues；`flutter test` 587 全绿（新增撤销信任 + 网关面板 2 例）。
- [SSOT 修正] 历史文档（m4/m3/m2-5/chat-interaction）保留「服务大厅」原文 + 加名词映射注；现行文档（architecture/requirements/coding-standards/index）直接改新名。`chat_page` 1980 → 1734 行（-246）；`settings_page` 1653 → 1789 行。
- [变更] 2026-10-16 聊天页 AppBar 清空：⚙ 设置按钮移除（设置入口只在侧边栏），debug 入口收进设置页新增「关于」段。**检查更新**是 release 正式功能故**常驻可见**（不藏），网关联调 / M1 任务循环改**长按「关于」标题**唤出（`kDebugMode` 内自闸，debug 构建给出提示文案）。ChatPage 同步删 `_openDebugMenu` + 3 个失效 import；空态/菜单文案「⚙ 设置页」→「侧边栏 → 设置页」。
- [验证] `flutter analyze` No issues；`flutter test` 588 全绿（+1 关于面板/长按联调用例）。
