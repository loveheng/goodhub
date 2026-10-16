---
dev-loop: devlog
format: v1
epic: window-slim
total-merged: 0
last-merge: none
---

（开发过程日志按行追加：[变更]/[验证]/[note]/[SSOT 修正]；≥5 条自动归并进 memory.md——dev-loop §2）
- [2026-10-17] [变更]: epic 挂载：mount-init 建 docs/design/window-slim.md 首稿 + context 骨架 + CURRENT 切绑；切绑前对 p0-security-correctness 执行归并（devlog 17 条提炼进 memory 已闭环节，total-merged 1）；README design 域同步登记
- [2026-10-17] [验证]: docs-lint → OK 全部通过
- [2026-10-17] [变更]: P1-D 释放卫生四项落地：①BinderTransport.close 补 _closed 防重入守卫（二次调用曾抛 StateError）②McpClient.close 收口幂等契约（守卫归 client 层，新 transport 不必各自实现）③释放通道补齐：GoodshareTaskApi.close→TaskLoopService.close→claim_loop_page.dispose 接线（buildApi 建的 client 此前无任何释放路径）④ServerEndpointStore.save 接 KeyedWriteQueue（键=配置文件绝对路径，并发 save 不再交错损坏）；新增 test/mcp/release_hygiene_test.dart（幂等计数+透传+12 路并发 save 不损坏），既有 FakeApi 补 close 契约
- [2026-10-17] [验证]: flutter analyze → 0 issue；flutter test test/mcp/release_hygiene_test.dart test/task/ → 9/9；flutter test --timeout 180s 全量 → 737/737 全绿
- [2026-10-17] [变更]: P1-C 降级可见性分级落地：①MemoryKernel.buildFilter 增 onWriteFailure 回调，数据面事实写失败不再静默（原 unawaited+discarded_futures 零上报），chat_page 接线 TrackNote(danger) 用户可见，未接回调时至少 DEGRADE 留痕 ②fail-closed/非数据面边界成文：coding-standards 新增 §5.3 降级可见性分级（数据面写失败必须升可观测/裸 discarded_futures 即违例；progress 帧透传为非数据面豁免仅限瞬态帧不得类推结果帧）③gateway_server 心跳空吞补非数据面声明注释（条款锚点）
- [2026-10-17] [验证]: docs-lint → OK；flutter analyze → 0 issue；flutter test --timeout 180s 全量 → 737/737 全绿
- [2026-10-17] [变更]: P1-A chat_page Run 编排下沉：新增 lib/coordinator/chat_run_orchestrator.dart（ChatRunPlan + ChatRunOrchestrator）——记忆内核接线/冷热分层/系统前缀组装/归因数据/maskTool/slot 三态写回/governor 生命周期收口 coordinator，MemoryGovernor 所有权随迁；chat_page._send 400→约 330 行，只留配置收集/信任闸门 UI/事件流→轨道映射/finally 清理，_mountedServicesSection 静态助手一并上收。编排核现可独立单测（纯编排零 UI，不 import ui/）
- [2026-10-17] [验证]: flutter analyze → 0 issue（修 2 处 unused import 后复绿）；flutter test --timeout 180s 全量 → 737/737 全绿
- [2026-10-17] [变更]: P1-A settings_page 分段拆解第一段：本地插件段抽 lib/ui/sections/local_plugins_section.dart（LocalPluginsSection 自持：扫描/信任白名单编排含信任卡与撤销确认/包变更流订阅重扫/卡片渲染，测试锚点 Key 原样保留）；settings_page 删 5 领域态字段（_localScan/_localPlugins/_trustedPackages/_localChangesSub/_localError）+ 3 编排方法 + 2 渲染方法（约 -330 行），页面仅经注入透传 + 钉选回调接线；默认私有钉选逻辑（与节点卡共用）留页面。等价回归网 = 既有 6 用例面板测试零改动通过
- [2026-10-17] [验证]: flutter analyze → 0 issue；flutter test test/ui/local_plugins_panel_test.dart test/ui/byok_panel_test.dart → 11/11（等价回归）；flutter test --timeout 180s 全量 → 737/737 全绿
- [2026-10-17] [变更]: P1-A settings_page 分段拆解第二段：云端引擎（BYOK）段抽 lib/ui/sections/byok_section.dart（ByokSection 自持：store 读写/生效位/密钥安全存储编排/表单与卡片渲染，测试锚点 Key 原样保留）；settings_page 删 9 领域态字段 + 5 表单控制器 + _initByok/_reloadByok/5 编排方法 + 3 渲染方法（约 -410 行，现 1406 行）；页面仅经 _byokPanelSection 透传 store 注入 + flash/错误行回调。等价回归网 = byok_panel_test 5 用例零改动通过
- [2026-10-17] [验证]: flutter analyze → 0 issue；flutter test test/ui/byok_panel_test.dart test/ui/local_plugins_panel_test.dart → 11/11（等价回归）；flutter test --timeout 180s 全量 → 737/737 全绿
