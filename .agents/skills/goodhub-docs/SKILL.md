---
name: goodhub-docs
description: goodhub 文档体系路由与门禁：docs/ 各域职责定位、docs-lint 触发命令与操作纪律（新建/移动/废弃）、文档评估方法论（依赖分级）。新增、修改、移动或废弃文档前必读；评估文档可信度定依赖深度时必读。规范机制一律指针到全局 docs-spec，严禁复制正文。
---

# goodhub 文档体系

本 skill 是 `docs/` 的**项目数据**登记处（域路由表 / lint 命令 / 例外），不是规范机制。
规范机制（frontmatter、根目录平铺、移动与引用修复、墓碑协议、README 双向覆盖）一律指针到全局 skill **`docs-spec` §1–§7**，本文件不复制其正文（防双源漂移）。

## 1. docs/ 域路由表（以存量结构为准，不臆造新域）

| 域 | 路径 | 内容定位 |
|---|---|---|
| project（项目接入/工程事实） | `docs/project/` | 接入定稿 + 编码规范 + 索引三表 + UI 规范 SSOT |
| product（产品设计） | `docs/product/` | 产品架构、需求、FC 锚点、聊天交互 SSOT |
| design（大功能设计稿） | `docs/design/` | 各 epic 设计 SSOT（m2-5 / m3 / m4 / thirdconnect / page-revamp / self-update / stream-perf / window-kernel-split / ux-hardening 等） |

> 各域下**全量文档明细**以 `docs/README.md` 为唯一事实源（防双源，本表不枚举文档、不记文档数）。

## 2. 机械校验与快速自测

修改任何 `docs/` 内容后，提交前单行触发：

```sh
toolbox run docs-lint   # 项目 toolbox 工具（别名 dl），pre-commit-gate 亦自动分派
```

- 脚本本体：`scripts/agent-tools/docs-lint.sh`（无 toolbox 直跑它）。
- 校验项：frontmatter 四项、根目录平铺、README 双向覆盖（链接存在性 + 孤儿检测）。细则 = `docs-spec §6`。

## 3. 操作纪律（正文机制指针 docs-spec，此处只列本项目动作）

- **新建**：frontmatter（`status` + `updated`）+ 同轮在 `docs/README.md` 加条目——**仅此一处**，不动本 skill、不动 `index.md`。
- **移动/重命名**：按 `docs-spec §5` 同步 README 索引并**全仓 grep 精确文件名修引用**（含各 skill 与代码注释）；断链事故教训 → lessons「docs/终态纪律」。
- **废弃**：按 `docs-spec §4` 墓碑协议（翻 `status: deprecated` + 墓碑行），禁静默删除。
- **域级变迁（新增域/拆分/合并/整体迁移）**：按 `docs-spec §2` 三处同步——`docs/README.md` + `docs/project/index.md` 文档落点表 + 本 skill 域路由表。逐篇文档操作**不触发**本条。

**写后自检（AI 落笔三问，任一命中即删/移；判据正文 = `docs-spec §7` 反模式）**：

1. 这句是**现行事实**，还是**关于事实的历史**（何时新增/迁入/谁拍板）？——历史移交 devlog，正文删。
2. 是否写了「原没有 X」「此前缺失」「暂无 + 解释正常流程」类自证句？——删，只留结论。
3. 是否在复述另一事实源（文档数/文件清单/状态列）？——删，留指针指向唯一事实源（README / frontmatter / index）。

## 4. 文档评估方法论（项目实例；通用骨架由 scaffold 预填）

评估目的不是判断文档好坏，而是决定**依赖深度**。六维判据：

| 维度 | 判据 | 本仓实证 |
|---|---|---|
| D1 时效性 | frontmatter `updated`/`last-merge` 是否落后于代码实际变更；devlog 后续 `[变更]` 是否未回填 | self-update 10-14 两条验证账本靠 10-19 专项补记才暴露缺失 |
| D2 账实一致性 | 可机械定位断言（类名/路径/行号/阈值/开关）对代码实证，三态 ✅/❌/❓ | mcp-orchestration 阶段一：memory.md 声称「toolsList 已实现」与代码不符；`settings_page.dart:19 → :35` 行号漂移实测 |
| D3 单源状态 | 同主题有无矛盾表述（新旧并存）；指针能否 grep 定位 | page-revamp 归并：两条 SSOT 修正记录按最高归纳优先级写入、严禁新旧并存 |
| D4 决策状态 | 结论「已拍板/待裁决/已废弃」是否显式；评估与实施是否分开陈述 | mcp-orchestration「阶段二·评估设计（待裁决，未实施）」与「落地」严格分条 |
| D5 验证账本 | 变更是否有成对 `[验证]`；「未执行」是否带原因+自证条件 | ai-app-split「未执行」补记行注明验证发生在对方仓、本仓无代码变更 |
| D6 信息密度 | 每条陈述是否携带可行动信息；有无遥测式重复 | ux-hardening 归因条降噪：无记忆注入且无超预算丢弃时不渲染 |

依赖分级（评估输出）：**L3 可直接依赖**（六维全过，作设计前提）｜**L2 抽查依赖**（关键断言动手前实证——读码纪律第③步）｜**L1 仅线索**（过期/缺验证/状态不明任一命中，一切以代码为准）。

使用时机：① 依赖前——文档建图时顺带分级（读码纪律配套，非额外动作）；② 变更后——触及断言同轮 SSOT 回填；③ 收尾时——`::audit` 机械项覆盖 D2/D3（::verify 三态、指针抽查），本方法论补 D1/D4/D5/D6 人判口径。

## 5. 本仓例外（存量与 docs-spec 的冲突；不静默改写存量）

- 暂无。

## 维护协议

- 域路由表只随**域级变迁**更新（`docs-spec §2`），逐篇文档增删不回改本 skill；表内禁记文档数、文件清单等易腐数据，禁写过程叙事（何时新增/迁入/「原没有 X」）——见 `docs-spec §7` 反模式。
- 规范机制变更不回改本 skill；全局 docs-spec 升级时本文件无需改（指针即同步）。
