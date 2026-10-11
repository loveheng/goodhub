---
status: active
updated: 2026-10-10
---

# init · goodhub 项目接入

goodhub（AI 宿主 App）项目 AI 协作体系的接入定稿：dev-init 全流程产物、关键决策与遗留核对项。

## 接入产物

- scaffold 骨架：`context/` 记忆体系 + 白名单 + toolbox 项目池
- project-local skill：`goodhub-workflow`（构建/测试事实源）、`goodhub-index`（功能落点索引）
- `AGENTS.md`：会话初始化与冲突裁决链
- 自 goodshare 迁移：`build-apk.sh`、`bump-version.sh`（去 goodshare 字样，PKG 改 `com.zzh.goodhub`）
- 不迁移 `mcp-bridge`：goodhub 自身即 MCP 客户端

## 决策

- 纯本地项目，不推远端（用户拍板）
- MCP 接缝契约 SSOT 留 goodshare 仓 `docs/design/ai-app-split.md`，本仓只读引用，不复制

## 遗留核对项

- PKG `com.zzh.goodhub` 待首次构建核对
- ctx-audit --init 为 8✓1⚠：skill-verify ⚠ 属空壳预期（`lib/` 未建），首次构建后复验
