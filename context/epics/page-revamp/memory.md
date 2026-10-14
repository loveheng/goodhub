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

## 断点
- [断点] 下一步：page-revamp 评估报告整改项全部清零(P0/P1/P2+低优,九轮改动未提交);下一步:建议 git 提交,后续=设备端 UI 冒烟(交用户)或新需求开工
