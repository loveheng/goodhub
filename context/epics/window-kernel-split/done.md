---
memo: todos
format: v3
epic: window-kernel-split
---

# window-kernel-split · 域内完成

- [x] [2026-10-16] (清理) [short] `McpConnection` 底层传输未显式释放 → 已随步 1 搬迁修正：`McpRuntime.close()` 内 `client.close()`（`mcp_runtime.dart:263` DEGRADE 留痕），幂等两段式（§8.1-7 拍板） (src: agent, 二轮评估)
- [x] [2026-10-16] (测试) 步 3 解耦可证伪门禁 → 已达成：`grep ServerEndpointStore( lib/ui/chat_page.dart` 零命中（2026-10-16 ::done 审计实测）；三项行为变更验收亦已代码级闭环（①配额重置单测 ②headless L2 已有 permission_gateway_test:175 覆盖 ③transcript 单测） (src: ai, window-kernel-split 改造评估)
