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
- [2026-10-17] [变更]: P1-A settings_page 分段拆解第三段：关于段 + PC 远程网关段抽 lib/ui/sections/about_section.dart / gateway_section.dart（AboutSection 自持版本号读取 + 检查更新入口 + debug 联调菜单；GatewaySection 自持 :8766 起停编排 + 配对 Token 读写 + 局域网暴露风险文案，测试锚点 Key 原样保留）；settings_page 删 5 领域态字段（_appVersion/_gwRunning/_gwLanAddrs/_gwTokenCtrl/_gwBusy）+ _reloadGateway/_toggleGateway/_openDebugMenu/_aboutPanel/_gatewayPanel（约 -200 行，现 1202 行），并清掉 shared_preferences/package_info_plus/gateway_api/claim_loop_page/update_page 五个死 import（gateway_loop_debug_page 因跨源授权段 debug 入口仍在页内，保留）；页面仅经 GatewaySection(onFlash) + AboutSection() 接线
- [2026-10-17] [验证]: flutter analyze → 0 issue（先报 1 处 unnecessary_import：gateway_section 的 foundation.dart 已被 material 覆盖，删后复绿）；flutter test test/ui/{settings_page,byok_panel,local_plugins_panel,server_nodes_panel}_test.dart → 29/29（含网关面板/关于面板 2 例等价回归，零改动）；flutter test --timeout 180s 全量 → 737/737 全绿
- [2026-10-17] [变更]: P1-A settings_page 分段拆解收官（第四~六段一次性成套）：新增 lib/ui/sections/{nodes,cow,cross_source}_section.dart（NodesSection 自持：端点目录读写/令牌存况/探活编排/增删改表单/挂载开关/默认私有 pill+图钉渲染；CowSection 自持：覆写库读取/编辑保存/一键重置/新建表单/损坏备份警示；CrossSourceSection 纯展示段）。settings_page 降至 **233 行**（原 2145 行），只剩两类职责：页面骨架（ListView 顺序/间距/AppBar）+ 跨段 owner（toast/错误行口径 + 默认私有钉选持久化，②③ 共用同一默认键故钉选 owner 留页面）；`NodeProbeFn` typedef 随段迁出后由页面 `export` 转出，保持既有测试「零改动」契约
- [2026-10-17] [note]: 拆段踩到的真语义坑——ListView(`children:`) 经 SliverChildListDelegate 会把滚出视口且在 cacheExtent 外的 child **销毁重建**，拆前这些领域态住在页面层天然存活，拆到段里即退化成「滚一下，编辑一半的表单/面板错误态消失」（settings_page_test 错误隔离用例首当其冲变红）。修法=六个有状态段统一混入 AutomaticKeepAliveClientMixin（wantKeepAlive=true）；新增 test/ui/settings_sections_keepalive_test.dart 闸住该不变式（反向验证：任一段关掉 keepAlive 立即红），并同步 goodhub-index 三行落点
- [2026-10-17] [验证]: flutter analyze → 0 issue（修 4 处：2 处冗余 foundation import + 2 处测试 unnecessary_underscores）；flutter test test/ui/{settings_page,byok_panel,local_plugins_panel,server_nodes_panel,debug_hall,settings_sections_keepalive}_test.dart → 31/31；flutter test --timeout 180s 全量 → 738/738 全绿
