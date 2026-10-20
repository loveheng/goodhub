---
dev-loop: devlog
format: v1
epic: ux-hardening
total-merged: 0
last-merge: none
---

（开发过程日志按行追加：[变更]/[验证]/[note]/[SSOT 修正]；≥5 条自动归并进 memory.md——dev-loop §2）
- [2026-10-16] [变更]: P0-1 冷启动引导落地：新增 TrackGuide 瞬态轨道条目（dual_track_stream：sealed 加法扩展 + 渲染 + 编码兜底）；chat_page 未配置发送改轨道内引导卡+去配置按钮（替代 :591-602 整页 push），_loadEndpoints 尾按配置状态幂等插卡、设置返回后重估摘卡；引导卡不持久化（_persistCurrent 过滤）；空态提示收敛为已配置用户首次指引；交互 SSOT chat-interaction.md §1 增补冷启动引导规则
- [2026-10-16] [验证]: flutter analyze → No issues found；flutter test --timeout 60s 全量 → 663 例全过（含 chat_page_smoke 新增 2 例：未配置入轨引导卡/发送不跳走输入保留；widget_test 空态文案断言同步更新）
- [2026-10-16] [变更]: P0-2 错误路径自救落地：新增 lib/ui/error_copy.dart 白话翻译层（CloudHttpException 状态码分流/传输层/推理族含步数墙两特判/安全管线/MCP 族/兜底，纯函数）；dual_track_stream 新增 TrackError 错误行动卡（共用 _TrackActionCard：Rose 左竖条 + 白话标题/建议 + 可复制原始异常 + 重试钮，重试后锁定「已重试」；编码新增 error 类型，恢复态 onAction=null 锁定不可重试）；chat_page catch-all 改错误卡，_send 增 promptOverride 重试参数（不重复插用户轮卡、不清输入），_lastPrompt 语料；SSOT chat-interaction.md §2 错误路径口径更新
- [2026-10-16] [验证]: flutter analyze → No issues found；flutter test --timeout 60s 全量 → 673 例全过（新增 10 例：error_copy 5 + dual_track_stream 3 + track_codec 2）
- [2026-10-16] [变更]: P0-3 辅助面错误反馈治理：settings_page 面板级错误隔离（cow/byok/nodes/local 四面板初始化失败改面板内 Rose 文案 + 重试；移除 _error 打死整页与 store==null 永显「读取中」两处病；_init 拆 _initCow/_initByok/_initNodes/_initLocalPlugins，重试=方法自身）；update_page _bootstrap try/catch + 错误盒 + 重试（替代 _ready 永假按钮永久灰死无报错），下载取消（update_service.downloadApk 增 isCancelled 每 chunk 轮询 + UpdateCancelled 异常，取消≠失败中性呈现；stall 时等下个 chunk 的局限已注释），安装前确认弹卡（明示版本跃迁/重启/已过 sha256 校验），消息 _MsgTone 四档分色（info/success/warn/error）
- [2026-10-16] [验证]: flutter analyze → No issues found；flutter test --timeout 60s 全量 → 676 例全过（新增 3 例：settings 面板错误隔离+重试恢复闭环 / update_page 初始化失败可见+重试 / update_service 下载取消删半成品；memory_kernel 顺序相关 flake 复跑消失，单跑绿）
- [2026-10-16] [变更]: P1-4 运行中出口：① 运行中回车从静默吞掉改 _guardRunning SnackBar（SSOT §1「禁止静默禁用」合规——旧注释「行业惯例：停止为即时动作」让位于 SSOT）；② Abort 键改 Crimson 实底 + 白图标 + 40×40 高反差（§1 拍板落地，原 36×36 filledTonal tonal 底不够）；③ _runStartedAt/_elapsedTimer 接通（此前定义后从未赋值的死代码）——秒级 tick + 状态带 mm:ss 已耗时；④ LoopToolCallFinished 药丸从 idle 改 thinking（工具结束≠Run 结束，防用户中途误判完成）；SSOT §1 运行中条目同步补记三条
- [2026-10-16] [验证]: flutter analyze → No issues found；flutter test --timeout 60s 全量 → 679 例全过（components_test 新增 StatusStrip 3 例：fmtElapsed mm:ss / 运行态显示已耗时+思考中人话 / 非运行态无计时）
- [2026-10-16] [变更]: P1-5 会话管理：ConversationStore 增 rename（只改标题、updatedAt 保留不打乱列表序、原子重写、缺失/损坏返 false 不抛穿）+ ConversationMeta 增 messageCount（list 现算）；ConversationArchive 增 rename 门面（当前会话同名同步 _currentTitle，防 saveCurrent 覆盖回旧标题）；ConversationDrawer 改 StatefulWidget：标题搜索（本地过滤 + 清空钮 + 无匹配空态）、重命名对话框（预填旧标题、空标题禁存、取消不回抛）、列表元信息（时间 · 条数，0 条旧数据只显时间）；chat_page 接 onRename + _renameConversation（toast 反馈，运行中可重命名——元数据操作无会话态扰动）；SSOT chat-interaction.md §3 增会话管理条目
- [2026-10-16] [验证]: flutter analyze → No issues found；flutter test --timeout 60s 全量 → 687 例全过（新增 8 例：drawer 4 + store rename 2 + archive rename 2；memory_kernel 顺序 flake 第三次复跑即消，单跑恒绿）
- [2026-10-16] [变更]: P1-6 决策卡白话层 + 遥测降噪：BreakerCard 两变体各补一句话后果说明（熔断三操作：单步重试=原地再试/跳过=把出错作为结果告诉模型换条路/人工接管=手填正确结果；步数墙：放宽=再给 10 轮/终止=结束任务不回滚）；CrossSourceConsentCard 补「允许=把数据交给目标工具/拒绝=本次调用中止，仅本次不记忆」；status_strip pillText 去黑话（breaker→工具报错，待处理；fence→敏感信息，待确认）；归因条降噪——无记忆注入且无超预算丢弃时不渲染（服务数与状态带上下文胶囊重复，每轮必出是遥测噪音）；FenceBlockCard 核对后确认已有白话段不重复改；SSOT chat-interaction.md §2 增白话层+降噪两条
- [2026-10-16] [验证]: flutter analyze → No issues found；flutter test --timeout 60s 全量 → 692 例全过（新增 5 例：BreakerCard 两变体后果说明 2 + pillText 去黑话 1 + 归因条降噪/呈现 2）
- [2026-10-16] [变更]: P1-7 术语白话层（辅助面）：settings_page——BYOK 面板标题改「云端引擎（自带 API Key）」、空态去「装配」黑话、覆写面板「模板跃迁」改「官方模板大版本更新」、跨源策略行「禁盲签」改「看不清不放行」、BYOK 描述去「装配模型」与过时的「聊天页 ⚙」引用；memory_board_page——导出 tooltip 改「复制全量到剪贴板（含锚点）」（原「导出全量」误导期待文件/分享面板）、删除/编辑确认框标题改人类指称（不再用 mb_xxx 内部 ID）+ 补「删除后不可恢复」、粉碎确认框「user 级/srv:」改「个人记忆/按服务绑定」、审计 Tab 补筛选（工具/服务名子串 + 仅看失败 + 计数 + 无匹配空态；审计日志只增不清=毁证不提供）、初始化失败补错误盒 + 重试（P0-3 同口径，重试成功清错误态）；trust_plugin_dialog 补指纹比对指引（与发布方公布指纹一致才信任）
- [2026-10-16] [验证]: flutter analyze → No issues found；flutter test --timeout 60s 全量 → 694 例全过（新增 2 例：记忆看板初始化失败重试恢复 / 审计 Tab 筛选；byok 空态文案断言同步更新）
- [2026-10-16] [变更]: P1-8 信任卡权重与后果：TrustPluginDialog 按钮权重反置修正——「信任并挂载」改 OutlinedButton 弱化路径、「拒绝」上 FilledButton 主位（安全默认，主位在右与全仓确认弹卡位序一致）；补「拒绝」后果文案（本次不挂载/工具不可用/之后可在设置页本地插件面板重新信任）；barrierDismissible:false 经核对保留为有意设计（安全裁决须显式，点外部=误触不等于默拒/默准，同跨源授权卡 consentDelegate 口径）并注释说明防再被误判为缺陷；settings 本地插件面板「撤销」入口外包 Tooltip 补后果说明（可发现性=看得见+看得懂）
- [2026-10-16] [验证]: flutter analyze → No issues found；flutter test --timeout 60s 全量 → 697 例全过（新增 trust_plugin_dialog_test 3 例：权重不再反置/双回调可达/拒绝后果明示；local_plugins_panel 既有流不断）
- [2026-10-16] [变更]: P2-1 DEGRADE 用户可见性治理（章程最后项，四站点全处置）：① hybrid_assembly BYOK 读取失败——新增 onNote 通道参数（+byokStoreOverride 测试注入位），mcp_runtime 装配处透传 note，失败以轨道通告告知「本次为什么只有端侧」（历史病：仅 debugPrint，用户自带 key 失效后效果变差无解释）；② hybrid_cloud_engine 门禁探测异常——由放行改为 fail-closed 关闸（原方向偏危险：弱设备跑端侧有 OOM/过热风险；与配额篡改「宁可重置」同哲学），断网探测异常按在线处理的方向取舍经评估保留并注释论证（朝向更丰富路径、其失败经 P0-2 可见）；③ cow_sync 覆写文件损坏——由「按空库直接重写」改为先 rename 备份再起步（用户手改配置不再被无声清空）+ corruptBackupPath 暴露 + settings 覆写面板损坏警示；④ conversation_archive 配额文件损坏/签名不符——备份保留（不被后续 saveQuota 覆盖）+ lastQuotaError 暴露 + chat_page 会话初始化出轨道通告（额度不再静默清零）
- [2026-10-16] [note]: ::done 收尾：§7 审计 12 项本 epic 自身全 ✓（他 epic 存量债务按 todo #18 留账未代改）；6 处 DEGRADE 标记逐条转 (风险) 待办不删标（有意降级+已补可见性/收紧方向）；cow_sync:74 / conversation_archive:122 标记注释刷新至 P2-1 备份后行为；memory 提炼归档 context/archive/ux-hardening/，CURRENT → none
- [2026-10-16] [验证]: flutter analyze → No issues found（收尾仅注释刷新，无逻辑变更）；全量测试基线沿用 P2-1 账本 705 过 1 失败（失败=并发窗口 memory_governor_test，非本 epic）
