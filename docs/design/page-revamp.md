---
status: active
updated: 2026-10-16
---

# 页面整改(page-revamp)· 底子文档

> 来源:2026-10-14 对现有 UI 的全量评估(chat_page / services_hall / memory_board / claim_loop / 双轨卡片族 / tokens,约 6400 行)。
> 规范 SSOT 仍是 [ui-design.md](../project/ui-design.md)——本文只记整改范围与实施分解,不复制规范正文。

## 1. 评估结论摘要

- **设计语言一致性 ★★★★**:操作卡片状态机(左竖条 + 终态锁定)、色彩语义 token、1px 细边框达标,是骨架资产。
- **核心短板**:①设置职责碎片化(服务端点三个平行入口);②主题系统未接线(各页自拼 ThemeData,恒用 `ConsoleTokens.fallback`);③动效零落地(`fastDuration` 无消费者);④触控目标/确认弹窗不一致等操作细节。
- **距离工业级差距**:信息架构(设置碎片化)+ 主题未接线两大结构债,非视觉问题。

## 2. 整改分解(P0 → P2)

| 级别 | 事项 | 主要落点 | 状态 |
| --- | --- | --- | --- |
| P0 | 主题注入落地:App 级注入 ConsoleTokens(浅/深双套),删除各页自拼 ThemeData | 各 page 的 `Theme(data: ThemeData(...))`、main.dart | ✓ 已完成 |
| P0 | 端点删除加二次确认;Run 进行中离开拦截 | chat_page `_openSettings` / `_buildDrawer` | ✓ 已完成 |
| P1 | 设置拆分:服务全生命周期(增删改+探活+挂载)收敛到服务大厅;⚙ 只留导航 | chat_page `_openSettings`、services_hall `_nodesPanel` | ✓ 已完成（2026-10-16 升级为终态，见下表） |
| P1-终态 | **服务大厅 → 设置页合并**（2026-10-16）：聊天页 ⚙ 弹层(`_openSettings`)整体并入服务大厅并改名「设置」(`settings_page.dart`)；聊天页 ⚙ 与侧边栏直接 push；debug 菜单/侧边栏/⚙/M1 页四入口收敛；**PC 远程网关面板**与**本地插件撤销信任**迁入（唯一净新增 / 真缺口）；六段 scope 声明防膨胀 | `chat_page`（删 243 行 + 网关字段）、`settings_page`（六段重排 + 两面板）、4 测试改名 + 2 新用例 | ✓ 已完成 2026-10-16 |
| P1-终态 | **聊天页 AppBar 清空**（2026-10-16）：⚙ 设置按钮移除（设置只在侧边栏入口）；debug 入口收进设置页新增「关于」段——**检查更新常驻可见**（正式功能不藏），**长按「关于」标题**唤出 debug 联调菜单（kDebugMode：网关/熔断联调 + M1 任务循环） | `chat_page`（删 2 个 AppBar IconButton + `_openSettings` 残件 + 3 import）、`settings_page`（+关于面板 +`_openDebugMenu`） | ✓ 已完成 2026-10-16 |
| P1 | ABORT 移胶囊右位(§3.1 右侧);输入框运行中可预输入(排队) | chat_page build、status_capsule | ✓ 已完成 |
| P1 | Token 纪律清扫:硬编码 fontSize / `'monospace'` / `inversePrimary` / 魔法边框宽 | claim_loop、chat_page 表单、services_hall | ✓ 已完成 |
| P2 | 动效落地:L1 完成 tick、卡片/胶囊过渡(消费 `fastDuration`) | components/*、chat_page `_setPill` | ✓ 已完成 |
| P2 | TrackNote 收敛为可折叠 Run 概要条 | dual_track_stream | ✓ 已完成 |
| P2 | 错误文本可复制、Markdown 链接可点(url_launcher)、探活自动刷新 | rich_text_view、breaker_card、services_hall | ✓ 已完成（不引 url_launcher，链接改 WidgetSpan 长按复制） |

> **名词映射（2026-10-16）**：本文件与历史决策中的「服务大厅」= 现**设置页**（`lib/ui/settings_page.dart`）。改名只扩名字不扩职责——**设置 = 服务与引擎配置**，记忆看板 / 应用更新 / 会话历史仍是独立页，入口**只在聊天页侧边栏**——2026-10-16 起聊天页 AppBar 不再持有设置/调试按钮（检查更新常驻设置页「关于」，debug 联调长按「关于」进入）。

> **实施状态（2026-10-15 对账补标）**：九轮改动 P0/P1/P2 + 低优（console_tokens `Fsz` 字号 token 全仓 ~140 处替换、rich_text_view 长按复制 Toast）**全部清零**；flutter analyze 0 新增、test/ui + widget_test 55 例全绿；设备端 UI 冒烟交用户。细节见 `context/epics/page-revamp/memory.md`。

## 3. 关键拍板记录

(随整改推进用 ::adr 落 decisions.md,此处只留指针。)

## 4. 验收口径

- 各页 `consoleTokens(context)` 从注入主题取值(非 fallback),浅/深双套可切换。
- 破坏性操作(端点删除、会话删除、记忆粉碎)确认弹窗全覆盖。
- Token 扫描无散落魔法值(色值/字体族/动效时长)。
