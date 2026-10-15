---
memo: todos
format: v3
epic: window-kernel-split
---

# window-kernel-split · 域内待办
- [ ] [2026-10-16] (测试) 步 3 解耦验收补一条可证伪门禁:chat_page.dart grep 不到 ServerEndpointStore( 构造——比行数瘦到 600-700 更能证明耦合真断在接口上;与三项行为变更(配额切会话即重置/headless L2 恒 user_rejected/transcript 不翻倍)一并验 (src: ai, window-kernel-split 改造评估)
- [ ] [2026-10-16] (风险) [long] 铁律 2 降级后(§8.1 裁决 10:维持 Navigator.push、不引 App Shell Router)窗口间不共享可变引用无编译期或静态检查兜底,纯靠 code review 纪律。收敛条件:补窗口层 import 白名单断言(lint 或测试),或明确接受人工审视 (src: ai, window-kernel-split 改造评估)
- [ ] [2026-10-16] (风险) [long] RuntimeDelegates 是 8 端口聚合类,打包传入不可部分替换或继承扩展,新增端口必改此类(计划 §7 已登记端口蔓延熔断)。收敛条件:端口数从 8 涨到 10+ 时回设计稿复议边界(可能误搬了执行期事件),不得静默加字段 (src: ai, window-kernel-split 改造评估)
- [ ] [2026-10-16] (风险) [long] 内核↔内核无接口接缝:横向读内核走具体类型+快照(memory.md 二轮评估定性),实证 hybrid_assembly.dart:36 内部硬 new ByokStore() 无注入位 → 步 1 后 McpRuntime 对 Directory/Memory/SkillSupply 仍是具体类直连,只有装配选项参数化、无替换实现扩展点。收敛条件:出现第二个 Directory 或 Memory 实现需求时再抽 abstract interface class(现裁决=接口爆炸收益低) (src: ai, window-kernel-split 改造评估)
- [ ] [2026-10-16] (风险) [long] _persistConversation(chat_page:1103,位于 finally)本轮不迁(§8.1 裁决 5) → ChatPage 仍是 ConversationArchive 事实 owner,持久态留在窗口。收敛条件:Archive epic 立项时首条迁出,含 Cancelled 终态落盘语义不变 (src: ai, window-kernel-split 改造评估)
- [ ] [2026-10-16] (风险) [long] 事件循环(chat_page 991-1105)留窗口且含两处写内核态:transcript 全量回写 1067-1069、私有域绑定捕获 1079-1085 → 窗口仍是领域态写回触发者,§5 铁律 3 局部未达成;§8.1 裁决 1 只把耦合显式化未消除。收敛条件:步 3 后评估把写回收口为 Session 自订阅执行事件或内核回调(代价=执行期事件流进内核,与先抽纯壳边界冲突,须重开裁决) (src: ai, window-kernel-split 改造评估)

- [ ] [2026-10-16] (风险) [long] `SamplingQuota` 落盘防「杀进程冷启动刷新额度」：现为纯内存滑动窗口（20 次/60 分钟，按 serverKey 分桶，`sampling.dart:14-32`）；进程被 OS 杀后归零，可绕过本地 token 额度。属**本地额度**非服务端配额，严重度中低；落盘须存时间戳并防篡改，工程量不小，且归属 `ConversationArchive`（本轮 Deferred）。步 3 收口后随 Archive epic 一并做 (src: agent, 二轮评估)
- [ ] [2026-10-16] (风险) ServiceDirectory 变更通知通道（若日后需要）：现状 Composer 菜单打开时已 `await _loadEndpoints()`（`chat_page:490`）→ 菜单恒新；陈旧者仅页面内 `_endpoints` 缓存字段，影响面小。故**本轮不做**。若日后跨页一致性出问题，用纯 Dart `revision` 计数比对，**不引 ChangeNotifier**（Flutter 依赖，违反内核纯 Dart）、不引事件总线（§3.4） (src: agent, 二轮评估)
- [ ] [2026-10-16] (清理) [short] `McpConnection` 底层传输未显式释放：`chat_page` finally 仅调 `c.stop()`（cancel 订阅 + 停健康探活），未调 `client.close()`。随步 1 搬迁到 `McpRuntime.close()` 时一并修正，不单独立项 (src: agent, 二轮评估)
- [ ] [2026-10-16] (风险) [long] **步 0 的 ServiceDirectory 单一入口应兼作「拓扑收敛 seed」**：步 0 收敛 3 处拼装（§2.1）时，**落点不要塞进现有扁平域**，改由新建 `lib/app/`（或 `lib/core/di.dart`）装配容器承载——这是解除 `coding-standards.md` §1 目标拓扑自锁（「统一收敛拍板」无 owner/无触发条件）与三处 `dart:io` 豁免死锁（整改条件 = `platform/` 建立）的**唯一单点**，且**零额外工作量**（Directory 契约化本就要做，只是换个落点）。同轮给 `ChatPage` 加 `storeOverride` / `engineOverride` 注入位（范式同 `settings_page` 的 `endpointStoreOverride` / `probeOverride`），解「构造无参无注入位 → `chat_page_smoke_test` 只能冒烟」的可测性债——补测价值已由 B3 实证（补测咬出 3 个真缺陷）。**不改其余文件落点，不构成拓扑双轨** (src: agent, 全局迁就设计审视)
