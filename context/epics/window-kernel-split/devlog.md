---
dev-loop: devlog
format: v1
epic: window-kernel-split
total-merged: 0
last-merge: none
---

（开发过程日志按行追加：[变更]/[验证]/[note]/[SSOT 修正]；≥5 条自动归并进 memory.md——dev-loop §2）

[SSOT 修正] 2026-10-16 二轮：`docs/design/window-kernel-split.md` 回写六项裁决（§8.1 台账）——① 写回方法 `replaceTranscript`（全量替换，非 append）/ `bindPrivateServer` 三态 + `unbindToPublic`；② headless = `gateDelegate` 传 `null`，复用 `PermissionGateway:146-148` 既有 fail-closed，**不建 HeadlessGate**（`ToolPendingConfirmation` 无只读判据；L1 只读 137-140 已先于 delegate 放行）；③ 出参 `Future<McpAssembly>`（loop/router/abort/close，装配须受 `clientFactory` 注入）；④ `SamplingQuota` 实例独立入参（非 token、非 bool），归 Session 后切会话重置 = 行为变更入步 3 验收；⑤ §7.2 落盘勘误属 Archive 持久态、本轮不迁；⑥ 补铁律 4（生命周期单向依赖，变更经快照+端口）+ 其余 8 内核 Deferred。
[变更] 同轮文档改动：§3.1 认领状态、§5 增铁律 4、§7.1 `gateDelegate` 可空、§7.2 勘误、§7.5 步 0/1/3 契约与验收、§8 重组为 8.1 台账 + 8.2 待确认（5 项 → 2 项）。
[验证] 本轮为纯文档变更，未跑 `flutter analyze` / 测试；契约条款均对照代码实证（`permission_gateway.dart` / `sampling.dart` / `chat_page.dart` / `server_probe.dart`），无代码改动。

[SSOT 修正] 2026-10-16 三轮（并发 / 会话恢复 / 端口取消 / 目录热更新 / 测试可替代 / ephemeral 六项评估）：`docs/design/window-kernel-split.md` 增 §8.1 裁决 7-9 —— 7 `close()` **幂等 + 两段**（`abort()` 仅中断不释放 / `close()` 释放；关到哪一层写死 = `stop()` + `client.close()`），**并发踩踏无路径**（单飞守卫 `chat_page:607` + 池 per-Run 独立 + §9 不做全局池），**不做 RunContextId**；8 端口分类（挂起 `Future<T>` = gate/fence/block/consent/majorJump，三个 delegate 现已 Future；广播 `void` = onNote/onProgress/connectionReport）+ **Abort 兜底**（`approved:false, reason:'aborted'` 完成所有 pending 卡，防 `TrackConfirm.completer` 永挂）；9 ephemeral 不进 Directory 列表 / 不参与 `save()`，记忆 scope 强制任务上下文。
[变更] 同轮：§7.5 步 0（端口分类表 + Abort 兜底、`McpAssembly` 代码块补幂等/两段/关到哪一层/clientFactory 默认值、写回契约加 `toJson/fromJson` 只立签名）、步 2 第 3 项加 ephemeral 约束；新增 §8.3「已评估·不入本轮」表；新建 `context/epics/window-kernel-split/todos.md` 记 3 条技术债（quota 落盘 / Directory 通知通道 / `client.close()` 未调）。
[验证] 三轮为纯文档变更；`scripts/agent-tools/docs-lint.sh` 通过。评估中**推翻**两项：并发 Run 踩踏（无路径）、Composer 菜单陈旧（菜单每次打开重读 `chat_page:490`）；**推翻**切会话写冲突（`_guardRunning` + `_persistIfAny` 已挡）。

[SSOT 修正] 2026-10-16 四轮：`docs/design/window-kernel-split.md` —— ① **§7.4 勘误**：`lib/mcp/tool_router.dart` **非死件**，是 F1.9（P0）海关过滤唯一实现 + SA-Q6 已拍板「保留待接线」+ 有 `test/tool_router_test.dart:9` 引用，**不删、不脱索引**（原提案「步 0 物理删除 + 清 SKILL.md 索引」**驳回**）；生产装配仍不得引它（走 `coordinator/tool_router.dart`）。② §7.5 步 0 `McpAssembly` 改为**内部持有 `List<McpToolFace>`**、`abort()` **同步遍历**取消在途（消除 `chat_page:972`「faces.first」的偶然性，消除窗口 `_activeFace` 残留），并钉死两处实现约束：`cancelActiveRequest` 返回 void 不可 await（`mcp_tool_face.dart:203`）、`AgentLoop.abort()` 无参（`agent_loop.dart:193`）。③ 步 0 基线加**私有域三态往返断言**（`null`/`''`/`serverId`）——契约本就无损（`conversation_store.dart:61-63`），断言专为防日后被优化成二态致「显式公共」回跳。
[变更] 同轮：§8.1 增裁决 **10（铁律 2 降级，接受）/ 11（联调页：保留挂载原语、拒绝 `isFakeDebug` 特权分支，fake 走 `clientFactory`）/ 12（tool_router 不删）**；**§8.2 待确认清空**（2 项 → 0 项，冻结解除）；头部状态行改为「十二项 / 步 0 可开工」。
[验证] 四轮为纯文档变更；`scripts/agent-tools/docs-lint.sh` 通过；无代码改动。

[变更] 2026-10-16 五轮（实施计划立）：新建 `context/epics/window-kernel-split/plan.md`（WBS + 全局门禁 + 每步 DoD + 回滚点 + 风险熔断表），把设计稿 §7.5 路线图展开为可执行任务；`memory.md` 增 `[实施]` 指针并刷新断点。
[SSOT 修正] 计划 §0.1 **不锁测试总数**——设计稿记 583 / system-assessment memory 记 529 / workflow skill 记 491，**三口径不一致**；改为「开工前实测填基线表，门禁以不劣于实测基线为准」，避免拿错误数字当门禁。
[变更] 计划新增两项（源自同日全局迁就设计审视，落 `context/todos.md`）：① 步 0-T7 的 `ServiceDirectory` 单一入口**落点改由新建 `lib/app/`（或 `lib/core/di.dart`）装配容器承载**，兼作 `coding-standards.md` §1 拓扑自锁与三处 `dart:io` 豁免死锁的**唯一 seed**，零额外工作量（Directory 契约化本就要做）；② 步 0-T8 同轮给 `ChatPage` 加 `storeOverride`/`engineOverride` 注入位，解「构造无参 → 只能冒烟」的可测性债。
[验证] 五轮为纯文档变更（新增 plan.md + memory 指针 + 断点），无代码改动；未跑 analyze/test（基线实测列为 plan.md §0.1 开工前置动作）。

[note] 2026-10-16 六轮（**改造目标达成度评估**）：结论**分层**——窗口↔内核解耦与接口连接**达标**（值对象下行 + 8 端口上行 + 内核纯 Dart，headless 可复用同一 Runtime）；**内核↔内核不达标**：横向走**具体类型 + 快照、无接口**，实证 `hybrid_assembly.dart:36` 内部硬 new `ByokStore()` 无注入位 → 步 1 后 McpRuntime 对 Directory/Memory/SkillSupply 是具体类直连，只有「装配选项参数化」、无替换实现接缝。该缺口属 memory.md 二轮已定性并接受的**显式取舍**（非 Clean/Hexagonal 完整形态、接口爆炸收益低），**不是疏漏**。
[变更] 同轮落 6 条耦合残留待办 → `context/epics/window-kernel-split/todos.md`：① 事件循环 991-1105 留窗口含两处写内核态（transcript 全量回写 `chat_page:1067-1069`、私有域绑定捕获 1079-1085），铁律 3 局部未达成——裁决 1 只把耦合**显式化**未消除；② `_persistConversation`（`chat_page:1103`，finally 内）不迁 → ChatPage 仍是 Archive 事实 owner；③ 内核↔内核无接口接缝（同上实证）；④ `RuntimeDelegates` 是 8 端口**聚合类**，不可部分替换/继承扩展；⑤ 铁律 2 降级后「窗口间不共享可变引用」**无编译期或静态检查兜底**；⑥ (测试) 步 3 加可证伪门禁：`chat_page.dart` grep 无 `ServerEndpointStore(` 构造。
[SSOT 修正] 同轮改 `docs/project/coding-standards.md` **七处**（防后续按旧规范错做）：① §1 收敛纪律增 **`lib/app/` 唯一例外白名单** + 收敛 owner/触发条件（解 M4-D4「统一收敛拍板」无 owner 与 `platform/interfaces` 触发条件自锁的双重死锁）；② **新增 §1.1 窗口层/内核层分层纪律**（架构形态 + 五条硬规则：内核禁 import Flutter / 单一 owner 禁就地构造 / 生命周期单向依赖禁事件总线 / 视图态不下沉·领域态不上浮 / 内核命名须登记）；③ §1.1 增**三条形态判据**（新消费点不得就地构造 / 新窗口不得持领域态 / 新内核须先定生命周期层级，未定层级不得开工）——按用户取舍**只放判据、不放内核清单与终态描述**，避免 8 个 Catalog Only 内核被误读为承诺；④ 规则 1 豁免行号漂移修正（`settings_page.dart:19` → **:35**，实测）+ 整改触发条件扩到「`lib/app/` 装配容器建立」，二者先到为准；⑤ §3 补「领域态与视图态**不得同居一个 State**」+ Run 级句柄 `close()` 幂等、窗口不得缓存 Run 焚后引用；⑥ §6.1 补「内核须带**注入位** + 装配产物等价性单测，不得只靠真机冒烟」；⑦ §1 现状对照 `features/session` 补注由 `ConversationSession` 承接。
[变更] 机械件适配：`context/epics/window-kernel-split/todos.md` 头部 `format: v2` → `v3`、补 `epic:` 字段、标题改 `# window-kernel-split · 域内待办`（`toolbox run todos` 标题校验要求），存量 4 条条目内容未动。另立**全局 misc** 待办 1 条：`coding-standards.md` §2 规则 2 的 `SessionManager` 残留（规范仍按其存在编写，而仲裁已关闭、无具名类）——跨域（规范 + architecture §15），不属本 epic 域内。
[验证] 六轮为纯文档/台账变更，无代码改动；`toolbox run docs-lint` 通过（提示 0 项）；行号与耦合点均经源码实证（`chat_page.dart:1067-1103`、`settings_page.dart:35`、`hybrid_assembly.dart:36`、`permission_gateway.dart:66`）。
- [2026-10-16] [变更]: 步0-T7：ServiceDirectory 单一入口（新建 lib/app/service_directory.dart）收敛 chat_page/settings_page/gateway_controller 三处 ServerEndpointStore 拼装；修 gateway_controller:148 漏 prefs 迁移活 bug（旧单端点配置网关侧现可读）
- [2026-10-16] [验证]: flutter analyze → 0 issue；flutter test --timeout 120s → 588 全绿（基线持平）
- [2026-10-16] [变更]: 步0-T1~T6：新建 lib/coordinator/mcp_runtime.dart 立契约——SessionContext（纯不可变快照、不含配额）/ RuntimeDelegates 八端口（gate 可空、挂起 Future vs 广播 void）/ McpAssembly（abort 同步遍历 + close 幂等两段，client.close() 释放传输）/ McpRuntime.assemble 立签名（quota 独立入参 + clientFactory 注入位）/ ConversationSession 写回契约（replaceTranscript 全量替换、bindPrivateServer 三态、toJson·fromJson 只立签名）/ resolveBinding 回退链纯函数；B1 归档不重写，B2 新增回退链测试 7 例，B3 三态往返断言 1 例（含 null 显式往返）
- [2026-10-16] [验证]: grep package:flutter lib/coordinator/mcp_runtime.dart → 无（C1 纯 Dart）；flutter analyze → 0 issue；flutter test --timeout 120s → 596 全绿（基线 588 + 新增 B2×7 + B3×1）
- [2026-10-16] [变更]: 步1-T1~T5：装配内核搬迁完成——chat_page._send 装配段（原 658-970）+ _startConnection + _GuardedExecutor + try-finally 资源段整体迁入 mcp_runtime.dart（McpRuntime.assemble 实现 + GuardedExecutor 公有化）；chat_page 变调用方（收集 SessionContext + 实现端口，保留 workspaceFilter/loop.run 事件循环/视图态 finally）；信任闸门留窗口先裁；发现并补第 9 广播端口 onNotice（L1 通告，已回写设计稿 §7.1）；装配中途失败回收路径（partialConns/clients/refStore）补齐——原 _send try-finally 保护的内核化；测试注入面：engine/tempDirResolver/documentsDirResolver/clientFactory
- [2026-10-16] [验证]: flutter analyze → 0 issue；flutter test --timeout 120s → 600 全绿（596 + 装配新增 4：等价性/显式公共/close 幂等/装配异常回收）；真机端到端冒烟 → 未执行（无模拟器/真机，DoD 挂起项）
- [2026-10-16] [验证]: 真机端到端冒烟 → 用户验收通过（聊天正常）
- [2026-10-16] [变更]: 步2-T1~T3：三调用点收敛——内核补挂载原语 mount()/mountEndpoint()（client→negotiate→face→listTools 三处重复胶水；mountEndpoint 拥有所建 client，失败自清理）；gateway_controller._assemble 两块接入（HTTP 端点走 mountEndpoint + apiKeyReader，本地插件走 mount）；gateway_loop_debug_page._run 复用 mount（拒绝特权分支 §8.1-11，caps/ schemas 由原语返回、无重复 RPC）；task_loop_service.buildApi 适配 ServerEndpoint.ephemeral（ephemeralKey 只入内存不序列化，不进 Directory/不参与 save；调度模型不动）+ 隔离断言测试
- [2026-10-16] [验证]: flutter analyze → 0 issue；flutter test --timeout 120s → 601 全绿（600 + ephemeral 隔离断言 1）；gateway 生产路径真机冒烟 → 未执行（无网关侧真机验证环境，挂起项）
