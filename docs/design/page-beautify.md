---
status: draft
updated: 2026-10-17
---

# page-beautify：聊天页美学与交互美化

> 来源：2026-10-17 聊天页（`lib/ui/chat_page.dart` 及子组件群）全量走查评估——代码级审读对照 `docs/project/ui-design.md` 与 `docs/product/chat-interaction.md` 两份 SSOT，输出三组问题（困惑/不顺手/视觉）与 P0~P3 优先级。
> 定位：page-revamp（信息结构/同轴卡片族，已归档清零）与 ux-hardening（出错后用户之路/冷启动/术语白话框架，已归档清零）之后的**第三批：美学细节与交互顺手度打磨**。
> 域界：视觉规范 SSOT 仍是 `docs/project/ui-design.md`（token 唯一出处 `lib/ui/tokens/`，落点纪律见 `.agents/skills/goodhub-ui/SKILL.md`）；交互 SSOT = `docs/product/chat-interaction.md`。本 epic 只做组件层打磨，**不改规范本身**——确需改规范先走 pending-confirm 拍板。

## 1. 评估结论（三组问题）

### A. 会造成困惑（心智模型/信息）

| # | 问题 | 代码落点 |
|---|---|---|
| A1 | 空态零引导：仅一行灰字「下达自然语言任务，宿主调度已挂载服务完成」，无示例任务入口，新用户不知能干什么 | `chat_page.dart:1120` |
| A2 | 遥测黑话直出：工具名（`goodshare::list_items`）原名透传状态带；「宿主」「Run 概要」等内部术语上轨 | `status_strip.dart:47`、`dual_track_stream.dart:848` |
| A3 | 右下「≡」记忆 FAB（`Icons.reorder`）表意弱（心智=排序/菜单），且与归因条「≡」前缀撞车 | `chat_page.dart:1145`、`dual_track_stream.dart:694` |
| A4 | 记忆写入是突发事件：「⚡ 已记录 key=value」无事前预期、无显著事后管理入口 | `dual_track_stream.dart:506` |
| A5 | 运行中「查看」类操作也被一刀切禁掉：开上下文菜单（只读查看绑定）走 `_guardRunning` 弹「需等待」 | `chat_page.dart:586` |
| A6 | 会话与设置发现成本：AppBar 仅标题，会话列表（抽屉）与设置（抽屉底部）均藏 | `chat_page.dart:1090`、`conversation_drawer.dart:233` |
| A7 | 两套「记忆」命名易混：「记忆看板」（全局管理）vs「会话记忆」（本轮提取） | `conversation_drawer.dart:246` |

### B. 不顺手（交互）

| # | 问题 | 代码落点 |
|---|---|---|
| B1 | Enter=发送与 maxLines=4 自相矛盾：软键盘 send 动作替换换行键，移动端打不出多段任务 | `chat_composer.dart:104` |
| B2 | 右下双 FAB（回到最新/会话记忆）同尺寸垂直堆叠，主次不分、瞬时出现无动效；与 40dp 发送钮三者视觉竞争 | `chat_page.dart:1122` |
| B3 | 触达目标偏小：`+` 钮 36×36、上下文 chip 高约 22dp，均低于 48dp 推荐 | `chat_composer.dart:95`、`status_strip.dart:93` |
| B4 | 发送→中止形变无过渡：图标与底色瞬时切换，「任务已启动」无明确感知 | `chat_composer.dart:127` |
| B5 | 守卫 SnackBar 用默认样式，长句 2s 一闪而过读不完，且默认 inverseSurface 与控制台风格不搭 | `chat_page.dart:442` |
| B6 | 状态带 30px 对已配置用户常驻（`hasEndpoints` 即展开），低频信息长期占黄金垂直空间 | `chat_composer.dart:70` |
| B7 | 长会话 ListView(`children:`) 全量构建，几百轮历史一次性构建所有条目 | `dual_track_stream.dart:295` |

### C. 视觉/美学

| # | 问题 | 代码落点 |
|---|---|---|
| C1 | 等宽字体实为系统 `monospace`（JetBrains Mono 资产未落地），与正文 Roboto 混排基线发飘，遥测轨「廉价终端感」 | `console_tokens.dart:79` |
| C2 | 默认 Material seed（indigo）与控制台 token 双色彩源并存；indigo 种子色与 dataRef Indigo 400 过近，用户卡被误读为选中态 | `main.dart:96` |
| C3 | 输入框 focus 无任何反馈（边框恒 hairline） | `chat_composer.dart:59` |
| C4 | 助手回复无轮次标识，长会话多轮回看时轮次边界融化 | `dual_track_stream.dart:305` |
| C5 | 阅读轨未限宽（输入区有 720 限宽、消息流全宽），宽屏中文行宽 60+ 字阅读疲劳 | `chat_page.dart:1163` |
| C6 | 「✓ 任务完成」与遥测通告一起被折叠进「Run 概要」，完成反馈被降权 | `dual_track_stream.dart:266` |
| C7 | 文案一致性：半角括号/逗号混入全角中文（离开确认弹窗）、「✕撤销」无空格 vs「✕ 已撤销」有、「$action需等待」缺空格、「有 N 项服务」量词生硬 | `chat_page.dart:1052/452/640`、`dual_track_stream.dart:539` |

## 2. 优先级（评估输出，开工时按 ::next 收敛）

| 优先级 | 项 | 理由 |
|---|---|---|
| ~~P0~~ | ~~A1 空态示例 chips~~ | **2026-10-17 用户裁决：暂缓**——示例任务提示预填方案不通用（各用户任务域差异大），待后续激活信号 |
| ~~P0~~ | ~~C1 JetBrains Mono 落地~~ | **2026-10-17 用户裁决：关闭**——维持系统等宽字体，不引字体二进制资产（monoFamily 保持 `monospace`） |
| ~~P1~~ | ~~B1 换行问题~~ | ✅ **2026-10-17 落地**（754/754）：Enter 键平台语义分化——移动 Enter=换行 / 桌面 Enter=发送，口径与沿革记 chat-interaction.md §1 |
| ~~P1~~ | ~~A2 工具名人话化~~ | ✅ **2026-10-17 落地**：状态带「执行中 · 人话动作」+ CallCard 灰阶人话行（首子句/可展开全文）+ 原名留遥测轨；description 全文经 codec 持久化 |
| ~~P1~~ | ~~B2 双 FAB 重构~~ | ✅ **2026-10-17 落地**（761/761）：记忆入口上收 AppBar Bolt 图标（条件渲染，与 ⚡ 胶囊同符号，A3 表意半题同收敛）；「回到最新」为唯一悬浮钮，AnimatedSwitcher 180ms 淡入；P1 层清零 |
| ~~P2~~ | ~~B3 触达区 + B4 形变动效~~ | ✅ **2026-10-17 落地**（763/763）：+ 钮 36→48dp 触达；上下文 chip 垂直 padding 2→6 + 轻触觉（30px 状态带高度硬约束，不追 48dp 全触达——与 B6 收缩方向自洽）；发送↔中止钮改 TweenAnimationBuilder 底色过渡 + 图标 AnimatedSwitcher 缩放淡入（180ms，视觉对齐 M3 filledTonal 默认 Stadium/secondaryContainer） |
| ~~P2~~ | ~~C2 统一色彩源 + C3 focus 反馈~~ | ✅ **2026-10-17 落地**（764/764）：C2=main.dart seed indigo→Zinc 500 中性 + surface 家族显式贴 ui-design §1（浅 Slate 50/100、深 Zinc 900/950），消除「两个 indigo」（primary 与 dataRef 过近致用户卡被误读为选中态）；C3=药丸边框 AnimatedContainer hairline→l1Info 180ms（ChatComposer 转 Stateful 持 FocusNode） |
| ~~P3~~ | ~~A3~A7、C4~C7、B5~B7~~ | ✅ **2026-10-17 整批落地**（766/766）：A3 随 B2 闭环（reorder/≡ 撞车已废）；A4 首颗记忆胶囊事前说明（幂等 note，kMemoryFirstNotice）；A5 运行中菜单可查看不可切绑定（sheet 置灰 + 回调守卫双保险）；A6 AppBar 常驻 ⚙ 设置直达；A7 记忆命名区分（抽屉「记忆库」/AppBar「本轮记忆」）；B5 SnackBar token 化（floating + codeBg + 4s + 清栈）；B6 状态带 idle 收起、ContextChip 融输入行（抽自 StatusStrip，双处同源）；C4 助手轮「GoodHub」轻标（与用户轮「你」对称）；C5 阅读轨 720 限宽（空态 560）；C6「✓ 任务完成」脱离 Run 概要折叠、独立 Emerald 行（kTaskDoneNote 共享常量）；C7 文案一致性（全角括号/空格/量词/「✕ 撤销」）；B7 ListView children→builder（element 懒化，分组语义不变） |

## 3. 施工原则

1. **token 化优先**：色彩/字体/圆角/边框/动效时长一律走 `lib/ui/tokens/`，组件内禁散落魔法值（goodhub-ui skill 纪律）；动效遵守 ui-design §4.2（150~200ms 紧凑减速，禁 Spring）。
2. **交互改动同轮更文档**：凡改交互口径，同轮更新 `chat-interaction.md`（docs-spec 纪律）；改视觉口径先 pending-confirm。
3. **不翻归档案**：page-revamp 已闭环的信息结构（同轴卡片族/双轨/去气泡）与 ux-hardening 已闭环项（错误行动卡/引导卡/术语白话框架/决策卡后果文案）沿用不重开；本 epic 只收两者残余。
4. **新依赖先确认**：字体资产（JetBrains Mono）走 pubspec assets，属新资源引入，须用户拍板后落。
5. **验收**：每项 flutter analyze 0 issue + 相关 widget 测试（新增锚点或既有零改动通过）；视觉项真机走查由用户执行后记 devlog。

## 4. 验收口径

- `flutter analyze` → 0 issue；`flutter test --timeout 180s` 全量绿（当前基线 752/752）。
- docs-lint → OK（本文档 + chat-interaction.md 若改）。
- 视觉/动效项：真机走查留档（用户执行），记 devlog [验证]。

## 断点

（待 ::next 拆解首个子任务）
