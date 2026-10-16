---
dev-loop: memory
format: v1
epic: archive-memory-claim
total-merged: 1
last-merge: 2026-10-16
---

# archive-memory-claim（已收尾 2026-10-16）

- **交付**：ConversationArchive + MemoryKernel 两个应用级内核立核，窗口两个临时替身（`_persistConversation`/`memoryFilter`）清零（grep 可证）；`SamplingQuota` 落盘随步 1 实现
- **AM1**（用户拍板 a）：配额防篡改 = HMAC-SHA256（密钥入 SecureKeyValue，定长比较），篡改/换密钥检出按重置；落盘只恢复命中记录，maxPerWindow/window 为应用级常量；启动恢复注入初始 session，切会话仍重置（行为变更①不变）
- **步 3 SSOT 修正**：tool_router 接线移出本 epic——goodshare 侧 SDK annotations 未落地（thirdconnect 后续项①），维持保留待接线（SA-Q6），条件齐备直接接两点（assemble 建 face 后 + mcp_gateway_handler.toolsList），不造 speculative 基建
- **步 4 对账（诚实口径）**：chat_page 1402→1109；原估 ~850 未达——CRUD 对话框/守卫/toast 属视图编排本职留窗；视图件外提（session_context_sheet/conversation_drawer/status_strip → lib/ui/components/，StatefulBuilder+live 快照+回调保语义）
- **落点**：`lib/coordinator/{conversation_archive,memory_kernel}.dart`（均纯 Dart）；测试 +19 例（步 0 等价 4 / archive 6 / quota 5 / memory_kernel 5）；analyze 0 issue；全量 625 绿（基线 601 起 +24）
- **收敛度量**：替身 2/2 清零；窗口仅存三处 underSupportDir 内核装配位（设计允许）；本轮 3 处 DEGRADE 标记合规保留（测试实证），UNCERTAIN 0
- **判据沉淀**：「分离的标尺 = 领域态是否还有 owner 在窗口，非行数」；TrackEntry codec 留 UI 层、Session 只立 toJson/fromJson 签名（激活集跨会话重开 §15）
- **挂起项（移交全局 todos）**：真机冒烟——Archive 新建/切换/删除/恢复/损坏五路径 + 配额杀进程保留 + 胶囊/撤销 + 外提视图件回归（待用户侧载）
