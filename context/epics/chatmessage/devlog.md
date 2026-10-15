---
dev-loop: devlog
format: v1
epic: chatmessage
total-merged: 1
last-merge: 2026-10-15
---

（开发过程日志按行追加：[变更]/[验证]/[note]/[SSOT 修正]；≥5 条自动归并进 memory.md——dev-loop §2）

- [变更] 会话绑定 MCP 服务 · 输入一半切换痛点：状态带上下文胶囊改为**常驻可点**（已绑定→`[服务名]`；公共态有端点→`[公共]`），且状态带高度条件加入 `_endpoints.isNotEmpty`，故输入中「+」隐藏时胶囊仍在、点一下即开上下文菜单切换；输入内容不丢。保留「+」空输入显/有字隐（用户既定）。
- [验证] `flutter analyze` No issues；`flutter test`（排除 hybrid_cloud_engine_test）564/0 全绿。`flutter run` 四项手验（默认锁 private / 「+」显隐 / 切服务沿用 / 全局默认继承）需在真机或模拟器确认（本环境无法驱动 emulator）。
- [缺陷修复] 点击「+」弹层显示「无可用私有服务」但确有两个私有服务：根因为 `ChatPage` 仅在 `initState` 跑一次 `_loadEndpoints()`，`_endpoints` 缓存易因「先开聊天→大厅加服务→返回」而过时。修复：① `_openComposerMenu` 开菜单前先 `await _loadEndpoints()` 重读目录；② `_loadEndpoints` 加载后即完成「新会话默认锁定」（未显式绑定时按 `isDefault`→首个 private 锁定，已绑定/纯公共 '' 沿用）；③ 补 `mounted` 守卫过 `use_build_context_synchronously` lint。
- [缺陷修复·续] 用户确认 2 个服务是「本地插件面板」自动发现（Binder，`LocalPluginInfo`），**不进 `mcp_servers.json`**，故原菜单（只读节点卡端点）恒空。改为：① `_loadEndpoints` 同时 `localPluginDiscovery.scan()` 填充 `_localPlugins`；② 菜单新增「本地插件（自动挂载·零配置）」分区，逐条列服务名/包名+「始终挂载」尾标（系统托管、无需绑定选择）；③ 状态带胶囊 `showChip` 纳入 `hasLocal`，本地插件场景显示 `本地×N`（auto_awesome 图标）；④ 空态提示改为「无可用私有服务（私有端点请在 ⚙ 设置/服务大厅添加）」。语义：本地插件始终参与任务，绑定仅适用于手动 HTTP 端点。
- [修正·私有呈现] 用户指出本地插件是**私有**服务，不能当公有处理。上版状态带用了 `terminalMuted`（公有色）+ `auto_awesome` 图标，视觉上像公有。改为：① 状态带 `isPrivate = hasCtx || hasLocal`，本地插件按私有呈现（锁形 `lock_outline` + `l1Info` 色），仅纯公共才用 `public`/`terminalMuted`；② 菜单本地插件分区标题改「本地私有插件」，条目图标改 `lock_outline`、尾标改「私有 · 始终挂载」（`l1Info` 色），叙述加「私有 ·」前缀。
- [修正·加号常显] 用户要求输入框「+」（会话上下文绑定）**固定显示、不再隐藏**。原逻辑 `_composerVisible` 跟随输入空态（空输入显示、有输入隐藏，对齐 Gemini 习惯），有输入时「+」消失。改为：移除 `_composerVisible` 字段、`_inputCtrl` 的 `_onInputChanged` 监听与 `_onInputChanged` 方法、`if (_composerVisible)` 条件渲染，IconButton 始终渲染（有/无输入都可点开上下文菜单）。
- [修正·流内间隙无上限+计时] 用户指出流内间隙固定 300s 上限不合理：长思考/慢推理不应被掐断，应让人类判断。改为：① `DegradationController` 移除 `maxThinkingGap` 上限字段；`HybridCloudEngine.computeBudget` 改为**无上限**（随请求已耗时放宽、下限 `interEventGapTimeout`=120s）——活体连接（含 SSE 心跳字节）永不误杀，仅真死连接（持续无字节）被下限兜底下判超时；带工具请求无端侧兜底时也不再因长思考 rethrow 中断。② 聊天页状态带新增运行计时 `mm:ss`（右侧等宽显示），`_send` 起 `_runStartedAt`+1s 周期 `Timer` 刷新、`finally` 清；人类据此自行决定是否按「中止」。
