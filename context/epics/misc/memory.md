---
dev-loop: memory
format: v1
epic: misc
total-merged: 2
last-merge: 2026-10-11
---

# misc

## 要点
- 2026-10-10 goodhub 项目接入完成（dev-init 全流程）：scaffold 骨架 + goodhub-workflow/goodhub-index skill + AGENTS.md 落盘；自 goodshare 迁移 build-apk.sh/bump-version.sh（PKG=com.zzh.goodhub 待首次构建核对），mcp-bridge 不迁（goodhub 自身即 MCP 客户端）；ctx-audit --init 8✓1⚠（skill-verify ⚠ 属空壳预期：lib/ 未建）。
- [决策] 纯本地项目不推远端（用户拍板）；MCP 接缝契约 SSOT 留 goodshare 仓 docs/design/ai-app-split.md，本仓只读引用。
- 2026-10-11 仓库首次提交入库（M1~M3 全量 + context 记忆体系 + docs/.agents，147 文件）；goodshare M3 契约扩展提交 2524da5；清理 epics/m2-5 僵尸副本（::done 已于当日 11:07 归档、副本经 diff 证实零独有内容，备份 /tmp/goodhub-zombie-bak）；M3 归档断点补录提交号。

## 断点
- [断点] 下一步：下一步：回底按钮位置拍板（右下 FAB vs 输入框上方居中）与 B1 移动端 Enter 语义拍板；均待用户，未拍板不动
