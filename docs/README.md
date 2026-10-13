---
status: active
updated: 2026-10-13
---
# docs

- `project/` — 项目接入与工程事实
  - [project/init.md](project/init.md) — goodhub 项目 AI 协作体系接入定稿
  - [project/coding-standards.md](project/coding-standards.md) — 工程编码基准规则（分层拓扑/硬规则/质量门禁 SSOT）
- `product/` — 产品设计
  - [product/architecture.md](product/architecture.md) — 双角色 MCP 中枢产品架构（ADR-001~005 已归档）
  - [product/requirements.md](product/requirements.md) — 客户端需求清单
  - [product/future-considerations.md](product/future-considerations.md) — 未来演进考量（FC1-FC5 扩展卡点锚点）
  - [product/ui-design.md](product/ui-design.md) — 运行时控制台风格 UI 设计规范 SSOT
  - [product/chat-interaction.md](product/chat-interaction.md) — 聊天页双轨消息流交互 SSOT（m4/T3 立）
- `design/` — 大功能设计稿
  - [design/m2-5-skill-refstore.md](design/m2-5-skill-refstore.md) — M2.5 技能引用存储设计
  - [design/m3-ui-subs-sampling.md](design/m3-ui-subs-sampling.md) — M3 UI 订阅与采样设计
  - [design/m4.md](design/m4.md) — M4 记忆/聊天/服务发现设计 SSOT（T1~T6 分解与 D1~D12 拍板）
  - [design/thirdconnect.md](design/thirdconnect.md) — 第三方连接设计
  - [design/goodshare-local-plugin-eval.md](design/goodshare-local-plugin-eval.md) — goodshare 接入本地插件机制评估（宿主侧契约对照）：现状 HTTP MCP server vs 目标本地 Binder 插件、goodshare 必须实现清单（对照 thirdconnect §1.2）
  - [design/goodhub-goodshare-binder-eval.md](design/goodhub-goodshare-binder-eval.md) — goodshare 本地 Binder 插件 PoC 阶段一评估报告（2026-10-13 真机联调后）：TC1~TC14 逐条合规核对、5 项真机必修 bug 清单
  - [design/goodshare-binder-poc-fix-request.md](design/goodshare-binder-poc-fix-request.md) — goodshare 侧 Binder PoC 修复请求（含真机联调前置步骤与 R1 双连接争写锁风险验证记录）
