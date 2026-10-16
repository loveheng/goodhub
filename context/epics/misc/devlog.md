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
- [2026-10-16] [变更]: 设置页方案 A 落地（用户拍板）：撤销「默认私有服务」独立 radio 面板——HCI 评估判定该面板无独立数据源、候选集是 ②③ 的二次渲染（同屏双份+四层作用域过载）；默认钉选降级为 Server 节点卡/本地插件卡行内图钉按钮 + 默认私有 pill（L1 就绪语义，复用生效中/已信任字形）；候选资格与撤销前 _defaultPrivateCandidates 同口径（节点须 enabled 且 private tier，本地插件须 serverId 非空）；存储键 default.private.server 与聊天页回退链不变（MO8 持久默认放设置页决策不推翻，仅展示层重构）；_DefaultPrivateItem/_loadingDefault/radio 面板代码一并退役，settings_page 头部 scope 注释同步
- [2026-10-16] [验证]: flutter analyze（settings_page + 2 测试文件）0 issue；flutter test --timeout 120s 全量 643 例全绿（含新增默认钉选 4 例）
