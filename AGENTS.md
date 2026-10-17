# AGENTS.md

goodhub —— AI 宿主 App（master / 交互式 MCP 客户端）：认领 goodshare 远程 AI 任务（claim→推理→apply）。Flutter，Android 首发。

本仓库的 AI 协作体系在 `.agents/skills/`（随仓库版本化），**按需读取对应 SKILL.md**，不要凭记忆猜项目约定：

- **工作流事实源（构建/测试/运行命令唯一出处）**：`.agents/skills/goodhub-workflow/SKILL.md`
- **工程编码规范（写码规则 SSOT：分层/落点纪律/质量门禁）**：`docs/project/coding-standards.md`
- **功能落点索引（改前先定位）**：数据 = `docs/project/index.md`（代码落点/文档落点/架构债三表）；登记规约 = `.agents/skills/goodhub-index/SKILL.md`
- **UI 规范落点（改 UI 前先读）**：`.agents/skills/goodhub-ui/SKILL.md`（正文 SSOT：`docs/project/ui-design.md`）
- **文档规范落点（改 docs/ 前先读）**：`.agents/skills/goodhub-docs/SKILL.md`（机制 SSOT：全局 `docs-spec`；域表/lint 路径/例外在本表）
- **记忆与日志体系（dev-loop）**：`context/`——会话开始先读 `context/CURRENT`，再只读对应 epic 的 memory.md 恢复上下文；代码变更须按协议追加 devlog
- **MCP 接缝契约 SSOT（跨仓只读）**：goodshare 仓 `docs/design/ai-app-split.md`——改接缝须同轮修该文档
- **MCP 对 AI 接口契约立法源（跨仓只读）**：goodshare 仓 `docs/engineering/ai-dev-spec.md` §4——goodhub 采纳条款见本仓 `docs/project/coding-standards.md` §7

## 会话初始化（新窗口开场执行一次）

- 开场含「继续/开工/初始化」或首次指令时：先跑 `toolbox run-hooks bootstrap --quiet`（非 0 仅附一行 ⚠，不阻塞；无 toolbox 跳过）→ 跑 `toolbox run panel`（无 toolbox 则读 context/CURRENT → 绑定 epic 的 memory.md 断点）→ 输出会话绑定卡 → 按断点开工或等指令
- CURRENT 缺失/none → 列 context/epics/ 候选请用户选，严禁自选开工；无 context/ → 提示走 dev-init 接入

## 冲突裁决链

`context/epics/<epic>/memory.md` 显式决策 ＞ 项目 skill ＞ 通用规约（详见全局 dev-loop skill）。
