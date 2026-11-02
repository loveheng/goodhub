---
dev-loop: devlog
format: v1
epic: resource-center
total-merged: 1
last-merge: 2026-10-19
---

（开发过程日志按行追加：[变更]/[验证]/[note]/[SSOT 修正]；≥5 条自动归并进 memory.md——dev-loop §2）

[变更] 2026-11-02 能力中心四 tab（B 方案确认）：资源中心自双 tab 升四 tab = 文件资源 / 端侧模型 / 云端引擎 / 节点与插件；云端引擎（BYOK）与节点/插件/网关/工具目录管理面自设置页**全迁**（消除「两处都能删」双源），设置页瘦身至 外观/CoW/全局 Prompt/跨源/关于。tab 形态 = ui-design §3.4（≤4、纯文字、accent 下划线、keepAlive 内嵌既有 section、禁复制副本）。
[SSOT 修正] 2026-11-02 §3.4 补「容器 / 标签字数」行：能力中心 tab 渲染于全宽 AppBar 段头（非窄 sheet），单标签 ≤5 中文字，四标签均分禁滚动——固化 eval 提出的窄 sheet 拥挤顾虑。
[变更] 2026-11-02 资源中心 + 记忆看板两处 TabBar 落 §3.4 语义色：选中 = l2Accent 文字 + 2dp accent 下划线、未选中 = terminalMuted、标签遥测轨字号（Fsz.telemetry）。原默认 TabBar 用中性种子派生 primary，与规范冲突——现已对齐（goodhub-ui §4「以规范为准改实现」）。
[验证] 2026-11-02 flutter analyze 两文件 0 issue；各 section 已带 AutomaticKeepAliveClientMixin（keepAlive 落实）。
[变更] 2026-11-02 回归网对齐：节点/插件段迁入资源中心后，pin 测试壳 `_PinHarness` 的 `isDefaultPrivate` 仍用旧 `bool` 签名（现 section 要求 `bool Function(String id)`），且 local_plugins 测试缺失该壳定义——抽共享壳 `test/ui/pin_harness.dart`（`PinHarness`，公开类 + 修正签名），server_nodes/local_plugins 两测试改引用并删除重复私有定义；顺手消 `use_key_in_widget_constructors` 与冗余 `dart:async` 导入。
[验证] 2026-11-02 全量 `flutter analyze` 0 issue；`server_nodes_panel_test` + `local_plugins_panel_test` 共 17 用例全绿。
[变更] 2026-11-02 MCP 工具目录折叠化（用户拍板「合并到各自 mcp 服务，可以折叠」）：`McpToolsCatalogSection` 每服务卡改为 `ExpansionTile`，工具列表**默认收起、点开看工具**（subtitle 显 共享/共数），减长列表视觉负担；段仍置于「节点与插件」tab，未另开 tab（守 §3.4 ≤4）。同步更新单测：展开各卡后再断言组内排序 + 三态 pill。
[验证] 2026-11-02 全量 `flutter analyze` 0 issue；`mcp_tools_catalog_section_test` + `resource_center_section_test` 共 16 用例全绿。
[变更] 2026-11-02 IA 二次归位（用户拍板：配置归设置、资产归资源中心）：端侧模型段自 `OnDeviceModelSection` 拆为「资产面」（留资源中心「端侧模型」tab：导入/选择/删除）+「配置面」`OnDeviceConfigSection`（回设置页：启用偏好 / GenieX 增配运行库 / 电池白名单）；`GatewaySection`（PC 远程网关）自资源中心「节点与插件」tab 搬回设置页。新建 `lib/ui/sections/on_device_config_section.dart`；`OnDeviceModelSection` 瘦身为纯资产面；`resource_center_page` 移除网关、`settings_page` 加回 `OnDeviceConfigSection` + `GatewaySection`。
[验证] 2026-11-02 全量 `flutter analyze` 0 issue；`settings_page_test`(本就断言网关在设置、此前因瘦身失配而红，现恢复) + `gateway_section_test` + `on_device_battery_exempt_test`(改打 OnDeviceConfigSection) + `resource_center_section_test` + `mcp_tools_catalog_section_test` + `settings_sections_keepalive_test` 全绿（共 39+ 用例）。
[note] 文档滞后：`docs/project/index.md` 仍写资源中心「双 Tab」（实为四 tab）、`docs/design/resource-center.md` 段落点未含本次拆分；`settings_page.dart` 顶部 scope doc 已同步更新，业务文档待归并。云端引擎（BYOK）本次未动——用户未提及，按「不替用户拍板」留待其裁决。
[变更] 2026-11-02 MCP 工具目录拆解归并（用户拍板「彻底拆解嵌卡内」）：删除独立 `McpToolsCatalogSection`，新建可复用 `lib/ui/components/server_tools_list.dart`（单服务工具列表：ExpansionTile 折叠 + 三态 pill + 组内排序 + 空态/错误态，经注入 `McpCatalog` 取数）；`NodesSection` / `LocalPluginsSection` 各加 `catalog` 注入，把服务工具列表**直接嵌进对应 Server 节点卡（= ep.id）与本地插件卡（= p.serverId）**——按 serverId 一一对应，段数收敛（跨服务排序维度取消，每卡只列自身工具）。页面级 `McpCatalog` 单例注入两端；本地插件卡经 `widget.changes` 订阅包变更热刷新。测试迁移：`mcp_tools_catalog_section_test` 删、`server_tools_list_test` 新（三态/组内排序/折叠/空态/错误态）；`pin_harness` 加共享 `FakeCatalog`，三处测试补 `catalog` 注入。
[验证] 2026-11-02 flutter analyze 改动四文件 0 issue；server_tools_list_test + server_nodes_panel_test + local_plugins_panel_test + settings_sections_keepalive_test 共 21 用例全绿。
[SSOT 修正] 2026-11-02 同步 `docs/project/index.md`（资源中心页/工具目录落点行）+ `docs/design/resource-center.md` §7 至「拆解归并」形态。
[变更] 2026-11-02 修复本地插件卡「工具」展开项点不开：`ServerToolsList`（ExpansionTile）原嵌在 `_item` 的 `Expanded > Column > Row` 内，展开区高度被压成 0/裁切，表现为点不开（节点卡因工具列表未进 Expanded 故正常）。将工具列表移出 Expanded，置于标题 Row 之下作兄弟节点，与节点卡结构一致；顺手给 `PageStorageKey` 加来源前缀（`source.name-`）防同 serverId 折叠态串台。
[验证] 2026-11-02 flutter analyze 0 issue；`local_plugins_panel_test` 加回归用例（直泵 LocalPluginsSection + 自定义假目录返回工具，点开 ExpansionTile 断言工具可见），四测试文件共 22 用例全绿。
[变更] 2026-11-02（续）修复「工具」展开项**点开示意不可见**：根因是深色 console 主题下 `ExpansionTile` 默认箭头为低对比灰、几乎看不见，用户感知「没有点开的示意」；若真实插件又未加载出工具，展开后空白 → 像「点不开」。给 `ServerToolsList` 的 `ExpansionTile` 显式设 `iconColor/collapsedIconColor = l1Info`（高对比青）、`textColor = dataRef`、`backgroundColor/collapsedBackgroundColor = codeBg`（微深可点底）、圆角 shape；标题带工具数（共 N）、副标题明确「点击展开/点击重试」。实证诊断确认组件箭头本就渲染（24×24），问题与布局无关，纯属低对比 + 弱示意。
[验证] 2026-11-02（续）flutter analyze 0 issue；server_tools_list / local_plugins / server_nodes 共 21 用例全绿（修正错误态副标题断言）。
[验证] 2026-11-02（终）**真机实证**（PLQ110 / Android 17，flutter run 装最新代码）：资源中心→节点与插件 tab，三个本地插件（拾光/GoodTools/GoodShare）的「工具（共 14/4/43）」行均清晰可见（青色箭头 + 本地 pill + 「点击展开」副标题）；点 GoodTools 成功展开，geo/math_utility/system_pim/weather 四工具带共享 pill 完整渲染无裁切，箭头翻转向上的展开态正常。用户此前「还是点不开」判定为设备上跑的是旧构建（无高对比箭头改动）；最新构建已装入设备，功能确认可用。
[变更] 2026-11-02（三）**卡头合并改版**（用户点名美学/人机诉求：别要独立「工具」区块，展开钮放钉选后、本地标识右上角、共享计数并入卡头）：`server_tools_list` 退化为**纯工具体** + `onSummary` 概要上抛（`ServerToolsSummary` loading/error/done(total,shared)），并导出卡头复用件 `serverSourcePill` / `serverToolsMetaText` / `serverExpandChevron`；`local_plugins_section._item` 与 `nodes_section._nodeItem` 重构为**整行卡头 = 展开器**（InkWell 涟漪 + `AnimatedCrossFade` 收展，折叠也装载保卡头计数）——右上角簇 = 来源 pill → 钉选 → 展开箭头（节点卡再后接挂载开关，保持最右）；工具概要「共享 x / 共 y 个工具 · 点击展开」并入卡头信息行；节点卡编辑表单移入展开区且**点编辑自动展开**。展开态收口段级 `Set`（keepAlive 覆盖跨 tab；PageStorage 双保险随 ExpansionTile 退役）。坑：组件 `initState` 同步段 `_report` 会触发父段 build 期 setState → `Future.microtask` 延后一拍；`AnimatedCrossFade` 隐藏子树仍在 element 树（opacity 0 + IgnorePointer、不占布局——默认 layoutBuilder 两子级皆 Positioned、Stack 尺寸只取顶层），折叠态断言用 `crossFadeState` 不能用 `findsNothing`。
[验证] 2026-11-02（三）flutter analyze 0 issue；全量 `test/ui` 266 用例全绿（组件单测重写为纯工具体口径 + 概要上抛；本地插件展开回归改点卡头 + crossFadeState/位置断言）。
