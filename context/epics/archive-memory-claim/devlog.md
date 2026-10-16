---
dev-loop: devlog
format: v1
epic: archive-memory-claim
total-merged: 0
last-merge: none
---

（开发过程日志按行追加：[变更]/[验证]/[note]/[SSOT 修正]；≥5 条自动归并进 memory.md——dev-loop §2）
- [2026-10-16] [变更]: 步0单测前移：新建 test/coordinator/conversation_session_archive_test.dart 4例——session经ConversationStore落盘回读逐字段等价/绑定三态往返/空会话/恢复侧跳过防御编码；ConversationSession.toJson-fromJson维持只立签名不实现（评估裁决：落盘格式由ConversationStore定义，不做全量session持久化）
- [2026-10-16] [验证]: flutter analyze → 0 issue；flutter test conversation_session_archive_test.dart --timeout 60s → 4例全绿；全量未跑（纯新增测试无lib变更）
- [2026-10-16] [SSOT修正]: 旧 设计稿步3 tool_router 本 epic 内接线 ➔ 新 移出本 epic（上游 annotations 未落地，维持保留待接线）；旧 瘦身目标 600-700 行 ➔ 新 ~850、行数不当门禁
- [2026-10-16] [变更]: 步1 ConversationArchive 立核完成：①新建 lib/coordinator/conversation_archive.dart——saveCurrent 组装（transcript 编码收内核、窗口只传 trackJson）/ensureCurrent 懒建+标题截取策略/adoptSnapshot/load/list/delete 门面/失败 DEGRADE 返 false 不抛穿；②chat_page 删 _persistConversation+四字段改调用方（-17 行，_persistCurrent 薄封装保留视图态提示）；③SamplingQuota 落盘（AM1 拍板 a：HMAC-SHA256 签名，密钥入 SecureKeyValue，篡改检出按重置）——SamplingQuota 增 snapshotHits/restoreHits 纯原语，chat_page Run 收尾随快照落盘、启动时恢复（切会话仍重置=行为变更①不变）；④新增测试 11 例（archive 6+quota 5）+ 步0 4 例
- [2026-10-16] [验证]: flutter analyze → 0 issue；flutter test 全量 → 620 例全绿（基线 601 只增不减）；grep 门禁：chat_page 无 _convStore/_conversationId/_conversationTitle/_persistConversation/_titleFrom/ConversationStore.underSupportDir 残留，conversation_archive.dart 无 package:flutter 引用
- [2026-10-16] [变更]: 步2 Memory 内核认领完成：①新建 lib/coordinator/memory_kernel.dart——MemoryKernel.buildFilter(wsStates, conversationId, onCapsule) 收口 In-band 提取面（session 域落 wsStates 所有权仍归 Session 按调用传入/user-srv 域走 MemoryStore keyed 映射 G1/remove 幂等/幻觉 scope 丢弃 G4/undo 闭包含落盘回滚/onCapsule 胶囊通道不变），只调公共 API 可与 chatmessage 并行；②ConversationSession.memoryFilter 替身删除（mcp_runtime.dart -44 行，Session 回归纯会话态），清理未用 import 两个；③chat_page._send 改调 MemoryKernel().buildFilter；④新增 memory_kernel_test 5 例（域路由/srv keyed 覆盖/幻觉丢弃/remove 幂等/undo 回滚）
- [2026-10-16] [验证]: flutter analyze → 0 issue；flutter test 全量 → 625 例全绿（基线 620 只增不减）；grep 门禁：lib/ 与 test/ 无 memoryFilter 调用残留（仅 memory_kernel.dart 与其测试文档注释引用旧名）
