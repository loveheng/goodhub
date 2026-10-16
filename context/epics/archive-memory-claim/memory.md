---
dev-loop: memory
format: v1
epic: archive-memory-claim
total-merged: 0
last-merge: none
---

# archive-memory-claim

- [挂载] docs/design/archive-memory-claim.md
- [SSOT 修正] 旧 设计稿§3步3 tool_router 本 epic 内接线 ➔ 新 移出本 epic：goodshare 侧 SDK 下发 annotations 未落地（thirdconnect 后续项①），现在启用=未打标工具全被过滤生产归零；维持保留待接线，接线点（assemble 建 face 后 + mcp_gateway_handler.toolsList）条件齐备直接接，不造 speculative 基建
- [SSOT 修正] 旧 设计稿§3步4/§5 瘦身目标 ~600-700 行 ➔ 新 目标 ~850（Archive−130、Memory−60、视图件外提后剩投影本职）；行数当症状不当门禁，可证伪门禁=grep 无就地构造/落盘调用/memoryFilter 残留
- [决策] 步0 等价性断言走持久化真实路径（encodeMessages+save → load+decodeMessages）；ConversationSession.toJson/fromJson 维持只立签名，不做全量 session 持久化（激活集跨会话重开 §15）
- [决策] AM1（2026-10-16 用户确认 a）：SamplingQuota 落盘防篡改 = HMAC-SHA256（密钥入 SecureKeyValue，定长比较），篡改/换密钥检出按重置；落盘只恢复命中记录，maxPerWindow/window 为应用级常量不随落盘；恢复时机=进程启动注入初始 session，切会话仍重置（行为变更①不变）
- [决策] 步1 内核 API 落定：ConversationArchive（lib/coordinator/，不 import Flutter）——saveCurrent(trackJson, session) 组装收内核（transcript 编码不经窗口）、ensureCurrent(prompt) 懒建+标题截取、adoptSnapshot/load/list/delete 门面、失败 DEGRADE 返 false 不抛穿（finally 安全）；ConversationStore 降为存储实现细节

## 断点
- [断点] 下一步：步 2 Memory 内核认领 memoryFilter——提取面（WorkspaceStreamFilter 构造 + fact 路由 + undo 闭包 + onCapsule 回传）从 ConversationSession 迁入 Memory 内核 facade 新文件，_send 构造块与内存注入段一并瘦身；只调 MemoryStore 公共 API（upsertFacts/removeFacts）可与 chatmessage 并行；依据 docs/design/archive-memory-claim.md §3 步 2
