---
dev-loop: memory
format: v1
epic: ai-app-split
total-merged: 0
last-merge: none
---

# ai-app-split

> 本 epic 的 MCP 接缝契约 SSOT 在 **goodshare 仓 `docs/design/ai-app-split.md`（跨仓只读）**，本仓不存副本；改接缝须同轮修该文档（AGENTS.md 接缝契约条款）。因 SSOT 跨仓，本仓 memory 不设 `- [挂载]` 行（dev-loop §3 挂载行须指向本仓存在路径；缺挂载属提示级，不强制补）。

## 要点
- 2026-10-11 M3 接缝扩展已落地：`resources.subscribe` GET SSE 下行（ResourceSubscriptionHub，server 级全局订阅 + updated 广播）；sampling 反向推理（SSE 流内 `srv_` 帧 + 宿主 POST 回程）；`ai_suggest_tags` 消费工具（工具总数 38）；`bufferOutput` 帧即时性修复；契约 §3.10 / §3.11 新增、§3.6 / §3.8 修订。

## 断点
- [断点] 下一步：待该 epic 真正恢复活动时从 devlog 与 goodshare 仓契约现状重锚——当前为专项清理重建的占位骨架（2026-10-19），正文仅含唯一一条已落地结论
