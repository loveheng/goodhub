---
status: active
updated: 2026-10-14
---

# 页面整改(page-revamp)· 底子文档

> 来源:2026-10-14 对现有 UI 的全量评估(chat_page / services_hall / memory_board / claim_loop / 双轨卡片族 / tokens,约 6400 行)。
> 规范 SSOT 仍是 [ui-design.md](../product/ui-design.md)——本文只记整改范围与实施分解,不复制规范正文。

## 1. 评估结论摘要

- **设计语言一致性 ★★★★**:操作卡片状态机(左竖条 + 终态锁定)、色彩语义 token、1px 细边框达标,是骨架资产。
- **核心短板**:①设置职责碎片化(服务端点三个平行入口);②主题系统未接线(各页自拼 ThemeData,恒用 `ConsoleTokens.fallback`);③动效零落地(`fastDuration` 无消费者);④触控目标/确认弹窗不一致等操作细节。
- **距离工业级差距**:信息架构(设置碎片化)+ 主题未接线两大结构债,非视觉问题。

## 2. 整改分解(P0 → P2)

| 级别 | 事项 | 主要落点 |
| --- | --- | --- |
| P0 | 主题注入落地:App 级注入 ConsoleTokens(浅/深双套),删除各页自拼 ThemeData | 各 page 的 `Theme(data: ThemeData(...))`、main.dart |
| P0 | 端点删除加二次确认;Run 进行中离开拦截 | chat_page `_openSettings` / `_buildDrawer` |
| P1 | 设置拆分:服务全生命周期(增删改+探活+挂载)收敛到服务大厅;⚙ 只留导航 | chat_page `_openSettings`、services_hall `_nodesPanel` |
| P1 | ABORT 移胶囊右位(§3.1 右侧);输入框运行中可预输入(排队) | chat_page build、status_capsule |
| P1 | Token 纪律清扫:硬编码 fontSize / `'monospace'` / `inversePrimary` / 魔法边框宽 | claim_loop、chat_page 表单、services_hall |
| P2 | 动效落地:L1 完成 tick、卡片/胶囊过渡(消费 `fastDuration`) | components/*、chat_page `_setPill` |
| P2 | TrackNote 收敛为可折叠 Run 概要条 | dual_track_stream |
| P2 | 错误文本可复制、Markdown 链接可点(url_launcher)、探活自动刷新 | rich_text_view、breaker_card、services_hall |

## 3. 关键拍板记录

(随整改推进用 ::adr 落 decisions.md,此处只留指针。)

## 4. 验收口径

- 各页 `consoleTokens(context)` 从注入主题取值(非 fallback),浅/深双套可切换。
- 破坏性操作(端点删除、会话删除、记忆粉碎)确认弹窗全覆盖。
- Token 扫描无散落魔法值(色值/字体族/动效时长)。
