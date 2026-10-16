---
status: draft
updated: 2026-10-16
---

# Archive-Memory 内核认领

## 1. 背景与目标

window-kernel-split（已归档 `context/archive/window-kernel-split/`）完成「两层 + 端口」核心分离，但两个**应用级内核**未立，窗口侧各留一个临时替身：

| 临时替身 | 归属内核 | 位置 |
|---|---|---|
| `_persistConversation`（会话快照落盘） | ConversationArchive | `chat_page.dart:155` |
| `memoryFilter`（In-band 提取面） | Memory | `ConversationSession.memoryFilter`（mcp_runtime.dart:770，暂寄 session） |

本 epic 目标：**立 ConversationArchive + Memory 两个应用级内核，收口两个替身**；tool_router 接线（SA-Q6 拍板项，步 3 已 SSOT 修正移出），最终 chat_page 瘦身对账（原目标 ~600-700 → 实测口径见 §3 步 4：~1100，行数当症状不当门禁）。

## 2. 继承的裁决（不重开）

- **铁律 4**：生命周期单向依赖 应用级 ← 会话级 ← Run 级；变更经快照 + 端口（window-kernel-split §8.1-6）。
- **架构形态**：两层 + 端口，**不是** Clean/Hexagonal——内核横向具体类型 + 快照，接口爆炸收益低（§8.1-6 同源）。
- **Archive 是 Deferred 的首要认领对象**（§8.1-5 勘误）：`_persistConversation` 属持久态非视图态，铁律 3 不适用。
- **`SamplingQuota` 落盘随 Archive 一并做**（遗留 `(风险)[long]`：防杀进程刷新额度，须存时间戳并防篡改）。
- **tool_router 保留待接线**（SA-Q6 拍板；F1.9 P0 海关过滤唯一实现；装配不得引它的禁令随接线解除）。

## 3. 步骤分解（WBS）

### 步 0 · 单测前移
- 快照序列化等价性：`ConversationStore.encode/decodeMessages` 往返 + `ConversationSession.toJson/fromJson`（window-kernel-split 步 0 已立签名未实现持久化）——先断言后实现，防落盘返工。

### 步 1 · ConversationArchive 立核
- 新建应用级内核（纯 Dart，grep 无 `package:flutter`；建议落点 `lib/coordinator/conversation_archive.dart`，横向依赖走具体类型 + 快照）。
- API：快照落盘（`_persistConversation` 语义原样迁入：原子重写 / Cancelled 终态含内 / DEGRADE 留痕不抛穿）+ 回读（`ConversationStore` 之上的内核门面）+ `SamplingQuota` 持久化（时间戳 + 防篡改口径另记 ADR）。
- 窗口侧删除 `_persistConversation`，Run 收尾经内核调用；`ConversationStore`（`lib/sandbox/`）降为存储实现细节。

### 步 2 · Memory 内核认领 memoryFilter
- In-band 提取面（session 域 → wsStates、user/srv 域 → memoryStore keyed 映射、remove 幂等、幻觉 scope 丢弃）从 ConversationSession 迁入 Memory 内核；UI 胶囊经 onCapsule 回传窗口的通道不变。
- ConversationSession 删除 `memoryFilter` 临时替身，窗口改从内核取提取面。

### 步 3 · tool_router 接线
> **[SSOT 修正]（2026-10-16，评估对账）**：移出本 epic——goodshare 侧 SDK 下发 annotations 未落地（thirdconnect 验收后续项①），现在启用 = 未打标工具全被过滤 = 生产归零；维持保留待接线（SA-Q6 拍板不变），两项接线点（assemble 建 face 后 + `mcp_gateway_handler.toolsList`）条件齐备时直接接，不造 speculative 基建。

### 步 4 · 瘦身对账验收（已对账，2026-10-16）
- **实测**：chat_page 1402 → **1109 行**（Archive/替身收口 −75，视图件外提 −293：session_context_sheet 130 / conversation_drawer 144 / status_strip 161 → `lib/ui/components/`，布局体外提、守卫/对话框/toast 编排留窗口）。原估 ~850 未达：原 ~130 行「持久化编排」里 CRUD 对话框/守卫/toast 属视图编排本职（留窗），实际可迁走的是 save 组装；行数当症状不当门禁（可证伪门禁如下）。
- **可证伪门禁（全部✓）**：窗口 grep 无 `_persistConversation`/`_convStore`/`_conversationId`/`_conversationTitle`/`_titleFrom`/`ConversationStore.underSupportDir(`；无 `memoryFilter` 调用；Archive/MemoryKernel 两内核文件不 import Flutter。窗口仅存三处 `underSupportDir` 内核/存储装配位（Archive 自身 + 按调用传入的 session 级 store，设计裁决口径）。

## 4. 不做（Catalog Only 不变）

EngineSupply / TrustGovernance / SkillSupply / Gateway / TaskLoop / Updater 六内核**无触发不立项**（触发条件已登记全局 todos）。

## 5. DoD

- 两个替身消失（grep 可证）；`SamplingQuota` 杀进程重启后额度保留；tool_router 过滤在生产装配链生效。
- 全量测试绿 + analyze 0 issue；设计稿/规范同步（coding-standards §2 规则 2 回改一并在步 2 结清）。
