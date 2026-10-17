---
dev-loop: memory
format: v1
epic: window-slim
total-merged: 1
last-merge: 2026-10-17
---

# window-slim

- [挂载] docs/design/window-slim.md

## 已闭环（2026-10-17 归并自 devlog 28 条；验证基线 752/752 全绿 + arch-deps 10/10）

- **P1-D 释放卫生四项**：BinderTransport.close 补 `_closed` 防重入守卫（二次调用原抛 StateError）；McpClient.close 收口幂等契约（守卫归 client 层）；释放通道补齐 GoodshareTaskApi.close→TaskLoopService.close→claim_loop_page.dispose（buildApi 所建 client 原无任何释放路径）；ServerEndpointStore.save 接 KeyedWriteQueue（键=配置文件绝对路径，并发 save 不再交错损坏）。新增 test/mcp/release_hygiene_test.dart（幂等计数+透传+12 路并发 save 不损坏）
- **P1-C 降级可见性分级**：MemoryKernel.buildFilter 增 onWriteFailure 回调——数据面事实写失败不再静默（原 unawaited+discarded_futures 零上报），chat_page 接 TrackNote(danger) 用户可见，未接回调时至少 DEGRADE 留痕；fail-closed/非数据面边界成文进 coding-standards §5.3（数据面写失败必须升可观测/裸 discarded_futures 即违例；progress 帧透传为非数据面豁免仅限瞬态帧）；gateway_server 心跳空吞补非数据面声明注释
- **P1-A chat_page Run 编排下沉**：新增 lib/coordinator/chat_run_orchestrator.dart（ChatRunPlan+ChatRunOrchestrator）——记忆内核接线/冷热分层/系统前缀组装/归因数据/maskTool/slot 三态写回/governor 生命周期收口 coordinator，MemoryGovernor 所有权随迁；chat_page._send 400→约 330 行，只留配置收集/信任闸门 UI/事件流→轨道映射/finally 清理；编排核可独立单测（纯编排零 UI）
- **P1-A settings_page 分段拆解收官**（四段成套）：local_plugins_section（扫描/信任白名单/包变更重扫）/ byok_section（store/生效位/安全存储/表单）/ about_section + gateway_section（版本/更新/debug 菜单 + :8766 起停/配对 Token/暴露风险文案）/ nodes+cow+cross_source section（目录读写/探活/增删改/挂载开关/默认私有钉选 + 覆写库 + 纯展示）；2145→**233 行**，只剩页面骨架 + 跨段 owner（toast/错误行口径 + 默认私有钉选持久化）；NodeProbeFn typedef 由页面 export 转出，保持既有测试「零改动」契约
- **[note] ListView(`children:`) 销毁重建坑**：SliverChildListDelegate 把滚出 cacheExtent 的 child 销毁重建——领域态拆到段里即退化为「滚一下编辑一半的表单/错误态消失」；修法=六个有状态段统一混 AutomaticKeepAliveClientMixin，新增 test/ui/settings_sections_keepalive_test.dart 闸住不变式（反向验证：任一段关 keepAlive 立即红）
- **P1-B 调试页收敛第一轮（双件消除）**：① 双 BYOK 表单——联调页自研表单删，内嵌设置页同源 ByokSection（ByokStore 两处互相可见），1145→1063；② 双 Run 装配——联调页 300 行内联装配下沉 lib/coordinator/debug_run_orchestrator.dart（481 行纯编排零 UI）：挂载→能力协商→记忆面→权限网关→注水→引擎→sampling→故障注入→Skills/CoW→AgentLoop→事件流全收口，_FaultInjector/_ScriptedEngine 随迁，五 UI 端口（L2/熔断/围栏/跨源/CoW 跃迁卡）+ 状态带 + 三目录解析器 + clientFactory 全注入位，页面降至 852 行。**准入裁决：不并回 McpRuntime.assemble**——生产多 Server 前缀路由+JIT 发现（tools 空表）与联调单 Server 裸名+静态 tools 语义不兼容。原 300 行零用例（真机唯一验证路径）→ 新增 debug_run_orchestrator_test 4 例（事件流契约/故障注入/释放卫生/异常路径）；踩坑：callWithProgress 假传输 sendStream 须 contentType=application/json 否则报「SSE stream ended without result frame」
- **P1-B 续②+chat_page 二轮下沉切片 A**：git mv claim_loop_page/grammar_spike_page → archive/（532eb52），摘除 about_section debug 菜单 M1 入口；切片 A（aa85034）：状态带已耗时反模式——每秒整页 setState（含 TextField 重建）只为刷 mm:ss → 新增公开组件 ElapsedText 自持 1s 定时器仅自身重建，时间源 now 可注入
- **P1-B/C/D chat_page 二轮下沉收官**：新增 lib/ui/chat_status_controller.dart——状态带（pill/running/已耗时/autoFollow）与轨道列表结构性变更双 ChangeNotifier 切分（statusListenable 仅状态带+输入集群重建，tracksListenable 仅双轨流重建），40ms 文本流不触发整页重建；切片 C：TrackText/TrackCall 改 ChangeNotifier 自管（append/patch 仅自身通知），renderEntry 用 ListenableBuilder 细粒度局部重绘，_RunSummary 加稳定 key 保展开态；切片 D：滚动锚定/键盘遮挡（didChangeMetrics→pinToBottom）/会话切换生命周期 resetForSession 归拢 Controller；ChatPage 剩 9 处 setState（配置缓存/侧栏/记忆撤销），运行态·轨道·流控已不整页重建
- **D 外溢收口（popScope 会话外溢拦截）**：确认离开后先 `_abort()`（触发即停，避免后台泄漏）再显式 `_persistCurrent()` 趁 mounted 落部分进度（循环 finally 幂等补写）；行为由「离开即丢进度」改为「离开即保存可恢复快照」

## 断点
- [断点] 下一步：§3 候选 1~5 已全闭环，仅剩 **6. 测试缺口补齐**（gateway_api/、app/service_directory、update/installer、core/security 零用例；integration_test/ 6 个不进 flutter test 基线）——待 ::next 拆解；若用户判定不再补则走 ::done 收尾（章程其余项已闭）
