# goodhub-ui · GoodHub UI 规范落点索引

> **规范正文 SSOT 在 [docs/product/ui-design.md](../../../docs/product/ui-design.md)（运行时控制台风格），本 skill 只登记落点与纪律指针，严禁复制规范正文**（防双源，同 docs-spec 机制）。

## 改 UI 前必读

| 要改什么 | 先读哪里 |
|---|---|
| 色彩语义（L1/L2/危险/数据指针） | ui-design.md §1 |
| 字体排印（阅读轨 / 等宽遥测轨） | ui-design.md §2 |
| 状态胶囊 / 双轨消息流卡片 / 设置页 | ui-design.md §3 |
| 触觉反馈 / 动效时长 / 边框 Token | ui-design.md §4 |

## 代码落点纪律

- **Design tokens 唯一出处**：`lib/ui/tokens/`（Flutter `ThemeExtension`）——色彩、字体、圆角、边框、动效时长一律 token 化，组件内禁止散落魔法值。
- 组件目录随 M1 骨架建立后登记到 `goodhub-index` SKILL.md 代码落点表。
- 模块归属与需求映射：architecture.md §5 + requirements.md F5。
