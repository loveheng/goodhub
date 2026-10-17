---
dev-loop: memory
format: v1
epic: window-slim
total-merged: 0
last-merge: none
---

# window-slim

- [挂载] docs/design/window-slim.md

## 断点
- [断点] 下一步：**P1-B 调试页收敛（第一轮·双件消除）已完结**——① 双 BYOK 表单：联调页自研表单删 → 复用 sections/byok_section.dart（同源 ByokStore）；② 双 Run 装配：联调页 300 行内联装配下沉 lib/coordinator/debug_run_orchestrator.dart（纯编排零 UI，_FaultInjector/_ScriptedEngine 随迁；五 UI 端口 + 状态带 + 目录解析器 + clientFactory 全注入位），页面降至 852 行，事件流→轨道映射留在窗口；准入裁决=**不并回 McpRuntime.assemble**（生产多 Server 前缀路由 + JIT 发现 vs 联调单 Server 裸名 + 静态 tools 语义不兼容）。下一步 = §3.5 P1-B 续：调试页非生产面体量收敛——grammar_spike_page(350)/claim_loop_page(230) 是否归档至 archive/（仍可从 debug 菜单进入，非真死件；需确认是否保留探针价值）；备选=P1-A chat_page 二轮下沉（1185 行/setState 24 处）。本仓 main 领先 origin 8 笔未推送，CI 三步（analyze/test/arch-deps）本地已绿

- [断点] 更新（2026-10-17）：P1-B 续两动作已落地——① 两 Spike 调试页归档 archive/ 并摘除 about_section debug 菜单 M1 入口（提交 532eb52）；② chat_page 二轮下沉·**切片 A** 已落地（提交 aa85034）：状态带「已耗时」mm:ss 由新公开组件 ElapsedText 自持 1s 定时器局部刷新，删 ChatPage._elapsedTimer 每秒整页 setState（含 TextField 重建反模式），时间源 now 做成可注入端口。**剩余切片**（chat_page 仍约 24 处 setState / 1185 行）按用户三支柱拆：B=状态流转/UI 分离（抽 ChatStatusController 收纳 pill/running/elapsed，ChatComposer 经 ListenableBuilder 局部刷；track 列表增量刷新）；C=细粒度局部刷新（流式文本 TrackText 经 ValueNotifier 自管、工具卡 TrackCall 相位自管，消 40ms 整页 setState）；D=副作用收敛（滚动锚定/键盘遮挡/会话切换生命周期归拢到 Controller）。每切片单独立项+widget 测试。main 现领先 origin 10 笔，CI 三步本地绿
