---
name: goodhub-docs
description: goodhub 的文档体系归属索引——只登记三项项目数据：docs/ 域目录表、本仓 docs-lint 脚本路径、存量与 docs-spec 的例外。规范机制一律指针到全局 docs-spec，严禁复制正文。改/增/移动/废弃文档前先查本表与 docs/README.md。
---

# goodhub 文档体系

本 skill 是 `docs/` 的**项目数据**登记处（域目录表 / lint 脚本路径 / 例外），不是规范机制。
规范机制（frontmatter 四字段、根目录平铺、updated 软自查、三层索引、墓碑与引用修复）一律指针到全局 skill **`docs-spec` §1–§7**，本文件不复制其正文（防双源漂移）。

## 1. 域目录表（以存量结构为准，不臆造新域）

`docs/` 现状域（与 `docs/README.md` 结构索引同源，后者为唯一事实源）：

| 域 | 路径 | 内容定位 | 文档数 |
|---|---|---|---|
| project（项目接入/工程事实） | `docs/project/` | 接入定稿、coding-standards | 2 |
| product（产品设计） | `docs/product/` | 产品架构、需求、FC 锚点、UI 规范 SSOT、聊天交互 SSOT | 5 |
| design（大功能设计稿） | `docs/design/` | 各 epic 设计 SSOT（m2-5 / m3 / m4 / thirdconnect） | 4 |

## 2. 本仓 lint 脚本路径

- 机械校验：`scripts/agent-tools/docs-lint.sh`（项目 toolbox 工具 `docs-lint`，pre-commit-gate 分派）
- 校验项：frontmatter `status`/`updated` 四项、根目录平铺、README 双向覆盖（链接存在性 + 孤儿检测）。细则见 `docs-spec §6`。

## 3. 本仓例外（存量与 docs-spec 的冲突；不静默改写存量）

- 暂无。`docs/design/` 各 epic 设计稿随实现推进翻 `status: active`，draft 态属正常生命周期（lint 不报错）。

## 维护协议

- 域表禁止一次性铺满（project-index「表格式规范」「维护协议」）；新增域/大文档时同步更新 `docs/README.md` 与 `goodhub-index` 的「文档落点」列（三处同步）。
- 规范机制变更不回改本 skill；全局 docs-spec 升级时本文件无需改（指针即同步）。
