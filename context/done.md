---
memo: done
format: v2
---

# 完成列表
- [2026-10-15] P1-2 `CloudToolSchema` 键序归一（G5 / §8.2）：规范 `toJson` 一级键序 `name→description→input_schema` + `parametersSchema` 递归字典序 + `annotations` 不进云端序列化 (域: chatmessage)
- [2026-10-15] P1-4 工具三段式确定序（§1.6 / §8.2）：`ToolRouter` 装配 `[public 排序]→[active private]→[meta/skill/memory]`，切私有域只动尾部块 (域: chatmessage)
- [2026-10-15] P1-3b cacheControl B1 落位接线（§8.1 改动点 4）：System 拆为 `[静态角色+skills(cacheControl: ephemeral)]` + `[记忆]` 两块——落点 `chat_page.dart` 装配处与 `agent_loop` SystemMessage 构造（两文件均有未提交用户改动，接线时注意 rebase）(src: ai) (域: chatmessage)
- [2026-10-15] P2-1 `workspace_states` 表（G3 / §9.5）：DDL（`conversation_id, state_key` 主键）+ `INSERT OR REPLACE` + `DELETE`，仅承 `session` 域（无 `scope` 列） (域: chatmessage)
- [2026-10-15] P2-2 `WorkspaceStreamFilter` FSM（G2 / G6）：跨 chunk 安全缓冲（上限 ≈18 字符）+ 闭环原子提交 + `_aborted` 挂 `fsm.discard()` 清空缓冲 (域: chatmessage)
- [2026-10-15] P2-3 接线 `agent_loop`（§3.7 / §3.3）：`:265` 包 `emit(LoopTextDelta)` 实时分流；`calls.isEmpty` 剥离标签段再入历史；`calls.isNotEmpty` 调 `cancelCommit()` 禁止提交 (域: chatmessage)
- [2026-10-15] P2-4 In-band 提示词（§3.2 / §3.7 / §9.3）：尾部 `<workspace_update_v1>` 铁律（含「tool-call 轮严禁输出」）+ 用户输入 `<` 转义 `&lt;` (域: chatmessage)
- [2026-10-15] P2-5 G4 scope 扩展：`_scopeRegExp` 含 `session` / `ws:`，JSON `"public"` 映射本会话域 (域: chatmessage)
- [2026-10-15] P2-6 记忆胶囊 UI（§3.6 / L4）：气泡底嵌「⚡ 已记录 key=value [✕撤销]」胶囊（按 scope 落 store 后触发），撤销接线对应 store 的 remove（session→`workspace_states` DELETE、user/srv→`MemoryStore.remove`）；右侧栏/抽屉事实列表可后置 (域: chatmessage)
- [2026-10-15] P2-1b `MemoryStore` 语义 key 映射（G1 / §3.5）：`user`/`srv:` 域 keyed upsert/remove（按 key 查重覆盖，替代纯追加），否则同 key 多次变更膨胀多条被预算淘汰；`session` 域由 P2-1 天然 keyed 覆盖 (域: chatmessage)
- [2026-10-15] P3-1 多 Tool 并发回填（D-J / §10.2）：`Future.wait` 并发派发 + 任一失败包装为合法错误 `ToolResult` 全量回填，绝不向上抛异常 (域: chatmessage)
- [2026-10-15] P3-3 2000 token 输出物理截断（D-I / §10.4）：`_governedContent` 入口硬截断 `kToolResultHardCap≈8KB` + Head 50 / Tail 20 折叠，摘要失败也不回退原文 (域: chatmessage)
