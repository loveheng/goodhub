---
name: goodhub-docs
description: goodhub 文档体系路由与门禁：docs/ 各域职责定位、docs-lint 触发命令与操作纪律（新建/移动/废弃）。新增、修改、移动或废弃文档前必读。规范机制一律指针到全局 docs-spec，严禁复制正文。
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

## 4. 本仓例外（存量与 docs-spec 的冲突；不静默改写存量）

- 暂无。

## 维护协议

- 域路由表只随**域级变迁**更新（`docs-spec §2`），逐篇文档增删不回改本 skill；表内禁记文档数、文件清单等易腐数据，禁写过程叙事（何时新增/迁入/「原没有 X」）——见 `docs-spec §7` 反模式。
- 规范机制变更不回改本 skill；全局 docs-spec 升级时本文件无需改（指针即同步）。
