---
dev-loop: devlog
format: v1
epic: chatmessage
total-merged: 2
last-merge: 2026-10-16
---

（开发过程日志按行追加：[变更]/[验证]/[note]/[SSOT 修正]；≥5 条自动归并进 memory.md——dev-loop §2）
- [2026-10-16] [变更]: 上下文归因展示条（展示 only）——新增 TrackContextAttribution（lib/ui/components/dual_track_stream.dart）：收起态等宽遥测 pill（数据指针色 dataRef + hairline 边框，ui-design §1/§4.3），点击 BottomSheet 详情（记忆按 scope 标签 + 已挂载服务快照 + 超预算丢弃注记 l2Warn）；onItemExclude 为预留钩子（null 不渲染排除位，当前页面不接线）；codec 增 'context' 类型往返（恢复态 onItemExclude=null 锁定，同 TrackMemoryCapsule 口径）；chat_page._send 装配点原「✓ 已载入宿主记忆 N 条」TrackNote 替换为归因条（memView.entries + router.serverIds + serverSummaries 快照）；新增 track_codec_test 往返用例 1 例
- [2026-10-16] [验证]: flutter analyze → 0 issue；flutter test 全量 → 638 例全绿（基线 637 只增不减）；真机冒烟 → 未执行: 待用户
- [2026-10-16] [变更]: 修复「工具轮后记忆胶囊不出现」——WorkspaceStreamFilter.cancelCommit 置位的提交禁令在多轮 Run 中永不解除（仅 abort 的 discard 复位），首个 tool-call 轮之后所有自然结算轮的合法 <workspace_update_v1> 段被 _tryCommit 静默丢弃（胶囊不渲染、记忆不落盘）。修复：feed 中新段（startTag 完全匹配）开启即解除禁令——禁令只压结算时已清空的本段残留，不株连后续轮次新段；新增 filter 回归测试（禁令不株连新段）
- [2026-10-16] [验证]: flutter analyze → 0 issue；flutter test 全量 → 639 例全绿（基线 638 只增不减）；真机端到端（含工具轮场景胶囊回归）→ 未执行: 待用户
- [2026-10-16] [变更]: 悬浮记忆入口（≡ FAB，chat_page）——与「回到最新」同款 small FAB（Stack 右下 bottom:8，返回键共存时回底钮上移 72）；仅当轨道存在 TrackMemoryCapsule 时显示（_hasMemoryCapsules）；点击弹 BottomSheet 汇总列表（l1Ok 状态点 + 等宽 key=value，已撤销条目灰阶删除线终态锁定，ui-design §3.2），纯展示不做修改入口（undo 仍走内联胶囊通道）
- [2026-10-16] [验证]: flutter analyze → 0 issue；flutter test 全量 → 639 例全绿（基线 639 持平，纯视图新增零行为变更）；真机冒烟 → 未执行: 待用户
- [2026-10-16] [变更]: 空提交可观测——_tryCommit 尾部 kDebugMode debugPrint '[workspace-filter] commit facts=N'（release 静默）：区分「纯闲聊空 {} 提交（0 条，无胶囊属预期）」与「模型未输出标签/禁令丢弃」，供真机排障口
- [2026-10-16] [验证]: flutter analyze → 0 issue；flutter test 全量 → 643 例全绿（memory_kernel_test 首轮全量跑偶发失败，复跑复绿确认为 discarded_futures 时序抖动，非本次引入）
- [2026-10-16] [变更]: 提取协议口径扩展（promptInstructions，静态区不变护前缀缓存）——从「仅硬性约束/关键决策/业务实体」扩为对话要点默会提取：①用户目标 ②陈述事实与关键细节 ③选择/决定 ④决定理由；scope 默认一律 session（本会话域落 wsStates），仅用户明确跨会话意图才升 user/srv；新增铁律④默默提取不在正文提及协议。用户诉求对齐：会话内隐式记忆（做什么/说了什么/选择/理由/细节），显式「记住 X」才进全局
- [2026-10-16] [验证]: flutter analyze → 0 issue；flutter test 全量 → 643 例全绿；真机端到端（闲聊轮验证默会提取出胶囊）→ 未执行: 待用户
- [2026-10-16] [变更]: 四域默会提取协议定稿合入（promptInstructions）——评审修正四细节：①占位符 <n>→<主题>（防端侧小模型误解为数字编号导致同 Key 覆盖失效）②action=remove 显式触发规则（用户明确推翻/撤销才设 remove，废案解禁通路）③空态改为「严禁输出本标签」（省 token 防闲聊污染，FSM 对无标签正文天然放行；解析器保留 {} 容错）④协议文本压缩 ~250 token（端侧遵循度）。协议形态：四域白名单 task.goal / env·fact / decision(结论+原因原子单 key) / constraint.avoid_*，抑制清单（过程细节/假想推演/寒暄），同 Key 覆盖禁 v1/v2 副本，示例修正为 facts 包裹 schema（评审草案原为裸数组会被 _tryCommit 静默丢弃）
- [2026-10-16] [验证]: flutter analyze → 0 issue；flutter test 全量 → 645 例全绿（新增 2 例：promptInstructions 四域/schema 文本锚点；FSM 管道新格式——三 facts 收集+remove 透传+标签剥离+session 归一）；真机端到端（闲聊轮无标签/决策轮出四域胶囊）→ 未执行: 待用户
- [2026-10-16] [变更]: 上下文阶梯截断 + 归档摘要落地（设计稿 docs/design/context-stepped-pruning.md，status: draft；README 已登记）——context_governor 新增 steppedWindow 纯函数（高低水位 6~12 双缓冲，纯追加吃满前缀缓存，触线一次剪 6 轮；裁剪点 Assistant 边界 + 回退越过紧贴 UserMessage 防保留轮失提问）；agent_loop 接线：summarizer!=null 时阶梯替代朴素滑动，Run 级 archivedSummary 滚动（旧摘要+新裁轮次重摘），摘要块 UserMessage 插装前导之后/保留区之前；降级：summarizer=null 走朴素滑动契约不变，摘要失败 E1 弃归档 DEGRADE 留痕。行为变更①窗口 6→6~12②发送区含归档块——均登记设计稿 §3
- [2026-10-16] [验证]: flutter analyze → 0 issue；flutter test 全量 → 654 例全绿（基线 645 只增不减：steppedWindow 水位边界 5 例 + agent_loop 归档行为 4 例）；真机长会话冒烟（阶梯触线 + 缓存命中观察）→ 未执行: 待用户
- [2026-10-16] [变更]: 记忆冷热分层与增量压实落地（设计稿 §6，CQRS 两视图分离）——新建 lib/coordinator/memory_journal.dart（frozenBase 字节冻结 + pendingDeltas Append-Only；squash last-wins 首现序折叠、非 DEL 终态归并 SET；compact=Tick 压实）；MemoryKernel.onCapsule 扩为 (key,value,action,scope,undo)（action/scope 供 delta 判 SET/OVERRIDE/DEL，undo 走 DEL——撤销也 append-only）；chat_page._send Tick 同频判定（滑窗高水位 12 / TTL≥5min 机会主义 / transcript 体量 >8k 突发兜底）+ systemTail=frozenBase；agent_loop.run 新增 contextFooter 参数（Delta 后置沉底：插 history 后、提问前，escapeUserTag 消毒——防增量区推移其后窗口原文的前缀缓存粉碎）；单向栅栏：_send 组装读快照、Run 内 onCapsule 只写 pending 池；session 域不注入 prompt（现状缺口已记设计稿 §6.1，journal 覆盖 user/srv 域）；切会话 compact('') 重置
- [2026-10-16] [验证]: flutter analyze → 0 issue；flutter test 全量 → 661 例全绿（基线 654 只增不减：journal 语义 5 例 + kernel delta 通道 1 例 + contextFooter 沉底/消毒 2 例；实现期修 squash 首现序 bug——reversed 收集误得末现序，改 Map 插入序实现）；真机端到端（连续覆写同 key + 胶囊 undo 的 Override/DEL 识别）→ 未执行: 待用户
- [2026-10-16] [变更]: 记忆治理模块分离（window-kernel-split 落点纪律）——新建 lib/coordinator/memory_governor.dart（MemoryGovernor：journal/TTL 时间戳/Tick 判定/水位常量全部收编，纯 Dart 零 Flutter，clock 可注入）；chat_page 残留策略清零（_memJournal/_lastRunEndedAt/_kTick* 四字段 → 单一 _memGovernor，窗口只测 transcript 轮数/体量并投影 systemTail+footer）；实现期修 _anchored 锚点 bug——空 store 合法渲染空串快照后 frozenBase.isEmpty 恒真，会把「未建锚」与「锚为空」混同导致每 Run 重压实，加显式锚定标志（reset 归零）
- [2026-10-16] [验证]: flutter analyze → 0 issue；flutter test 全量 → 706 例全绿（governor Tick 矩阵/单向栅栏时序/reset 3 例；装配时序用例暴露并修掉 _anchored bug）；真机端到端 → 未执行: 待用户
