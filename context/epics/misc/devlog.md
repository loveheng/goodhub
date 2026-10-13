---
dev-loop: devlog
format: v1
epic: misc
total-merged: 2
last-merge: 2026-10-11
---

（散修/小改动按行追加；≥5 条自动归并进 memory.md）
- [2026-10-13] [变更]: 从 goodshare 移植 scripts/agent-tools 工具池（arch-guard 按本仓 coding-standards §1/§2 重写规则：UI 禁 dart:io/平台分支/MethodChannel，3 个 UI dart:io 历史例外入白名单；build-apk/bump-version 换 com.zzh.goodhub 包名；docs-lint/commit-msg-gate 原样；pre-commit-gate 自测样本改本仓规则）；docs-lint 抓出 5 个孤儿文档已补 docs/README.md 索引
- [2026-10-13] [验证]: toolbox run docs-lint → OK；arch-guard 实扫 lib/ → OK；6 工具 self-test/合规门禁通过（build-apk/bump-version 为 manual 档无 self-test）
- [2026-10-13] [变更]: 补项目侧文档规范 skill goodhub-docs（仅项目数据：3 域目录表 + docs-lint 路径 + 例外，机制指针全局 docs-spec），AGENTS.md 加落点指针
- [2026-10-13] [验证]: 未执行: 纯 skill/文档登记，无代码变更
