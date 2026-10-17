---
description: goodhub UI 开发与规范落点：Design Tokens 引用标准（ConsoleTokens）、双轨控制台视觉纪律、UI 架构红线指针与验收要求。改页面、加组件前必读。
---

# goodhub-ui · UI 规范与开发纪律

> **规范正文 SSOT**：[`docs/project/ui-design.md`](../../../docs/project/ui-design.md)（运行时控制台风格；正文零外引，外部一律单向指入它）。本 Skill 只负责**代码落地纪律与防腐化门禁**，不复制设计正文；工程规则正文（分层/平台边界/门禁）在 `docs/project/coding-standards.md`，命令唯一出处 = goodhub-workflow skill——三者均只留指针，防双源。

## 1. 查阅指引（按改动范围定向查阅）

| 准备修改的内容 | 规范正文查阅位置 | 核心实现/落点 |
|---|---|---|
| 色彩语义（L1/L2、危险态、数据指针） | `ui-design.md` §1 | `lib/ui/tokens/console_tokens.dart`（色彩 token） |
| 字体排印（阅读轨文本 vs 等宽遥测/代码） | `ui-design.md` §2 | 同上（typography token） |
| 控件与交互（状态胶囊、双轨卡片流、设置段） | `ui-design.md` §3 | `lib/ui/components/` 与 `lib/ui/sections/`（逐一落点查 `docs/project/index.md` 代码落点表） |
| 体感参数（触觉震动、动效曲线、圆角/边框） | `ui-design.md` §4 | 同上（duration/radius token） |
| 布局标尺（网格/间距阶梯/圆角分级/限宽） | `ui-design.md` §5 | 同上 + 组件内 EdgeInsets |
| 无障碍兜底（对比度红线/双通道状态） | `ui-design.md` §6 | 语义色 token + 图标/文字标签 |

> tokens 为**单文件**（`console_tokens.dart`，`ThemeExtension<ConsoleTokens>`），色彩/字体/圆角/边框/动效时长全在其内，无分文件。

## 2. 编码纪律与高压红线

### A. 零魔法值（本 skill 专属执行细则）

- **tokens 取用唯一范式**：`Theme.of(context).extension<ConsoleTokens>() ?? ConsoleTokens.fallback`。严禁裸写 `Color(0xFF...)`、内联 `TextStyle(...)`、硬编码数值边框/圆角/动效时长。
- **等宽与阅读轨严格分立**：Trace-ID、端口、参数 JSON、Token 计数、引擎名等遥测/代码内容一律取 token 的 Monospace 样式；用户对话与长文一律取 Reading 样式（语义定义见 `ui-design.md` §2，本条只管怎么取）。

### B. 架构红线（指针——规则正文在 coding-standards，本 skill 不复制）

- **平台隔离**：`lib/ui/` 禁 `import 'dart:io'`、禁 `Platform.isX`、禁 `MethodChannel(` 直连；特权能力一律抽象接口 + 装配期注入——规则与处置 = `coding-standards.md` §1.3（N1），机械闸 = `arch-guard` R1~R3，**红灯修结构，不申请白名单**。
- **分层依赖**：`ui` 域允许出向查 `coding-standards.md` §1.0 分层矩阵（禁 `gateway` 反向引 `ui` 等矩阵项为准）。
- **视图态与领域态解耦**：UI 仅持临时交互态，禁就地持有领域核心态/共享单例；跨窗口状态走既有装配口径（注入位范式查 §1.3，现状落点查 `index.md`）。
- **长列表保活**：设置页有状态段必须混 `AutomaticKeepAliveClientMixin`（防 ListView 滚动复用丢态）——规则 = `coding-standards.md` §8.1，闸 = `test/ui/settings_sections_keepalive_test.dart`。

### C. 组件登记（指针——登记规约在 goodhub-index skill）

- 新增通用业务组件（`lib/ui/components/`）**同轮**登记 `docs/project/index.md` 代码落点表；表结构与登记纪律见 goodhub-index skill，不在本 skill 重复。

## 3. UI 验收闭环（顺序要求；命令行唯一出处 = goodhub-workflow skill）

改 UI 后按序三重自证，**命令原文（含 SDK 环境变量前缀、`--timeout 180s`）以 workflow §1 质检流水线为准**，本 skill 只锁顺序与口径：

1. **架构护栏**：`arch-guard` 秒过（R1~R3 平台隔离 + 依赖方向）——红灯即修结构。
2. **静态与闸门**：`flutter analyze` 0 issue + KeepAlive 闸门测试（`test/ui/settings_sections_keepalive_test.dart`）全绿。
3. **视觉验证**：环境无可用模拟器，唯一途径 = 真机侧载（命令与装机纪律查 workflow §2；工具链踩坑查 `context/lessons.md`）。

## 4. 维护与扩展纪律（程序归本 skill，规范正文不自带管理程序）

`ui-design.md` 是**即成规范**（现行规则的终态陈述），自身不承载维护/扩展程序——一切「怎么扩、冲突听谁的」在本节执行，原则 **规范先行**：

| 场景 | 程序 |
|---|---|
| 新增界面 / 组件 | 先归入 `ui-design.md` §3 既有模式之一（状态带 / 双轨卡片族 / 面板卡片）或 §4 细则组合；无先例形态**先扩 §1~§6 再实现** |
| 新增状态 / 语义 | 先映射 §1 既有语义色；确需新语义色，先扩 §1 表并同步 `console_tokens.dart` token，禁直取任意色值 |
| 新增尺寸 / 字号 / 时长 | 落 §2 / §4 / §5 既有阶梯；阶梯外先扩表（并同步 token）再使用 |
| 规范与实现冲突 | 以 `ui-design.md` 为准改实现；确需突破（新形态 / 新档位）先修订规范——禁实现单方面领先规范 |
| 功能清单 | 页面级「有哪些件 / 做什么」不入规范——归各功能设计稿与 `docs/project/index.md` 代码落点表 |

- **零外引**：`ui-design.md` 是终态规范，正文不挂钩任何外部文档；映射关系由本 skill 侧登记——需求来源 = `docs/product/requirements.md` F5，模块归属 = `docs/product/architecture.md` §5。
- **规范移动/改名**：按 docs-spec §5 三处同步（`docs/README.md` + `docs/project/index.md` 文档落点表 + goodhub-docs 域表），并全仓 grep 文件名修引用。
