---
dev-loop: devlog
format: v1
epic: resource-center
total-merged: 0
last-merge: none
---

（开发过程日志按行追加：[变更]/[验证]/[note]/[SSOT 修正]；≥5 条自动归并进 memory.md——dev-loop §2）
- [2026-10-18] [变更]: 准入评估收口 + 设计稿落地：docs/design/resource-center.md（draft）立稿——本地文件库一期定位（A）、ResourceStore 内核域 + $ref 句柄注入 + read_local_resource 工具、M1~M3 分期与验收、§6 三个待拍板点；docs/README.md 已登记，docs-lint 通过
- [2026-10-18] [验证]: toolbox run docs-lint
- [2026-10-18] [变更]: 设计稿 §6 三点拍板并回填：RC1=10MB 上限 / RC2=侧边栏设置区直达入口 / RC3=M1 整读+上限兜底（分段读登记二期候选）；pending-confirm.md 三项已结；断点推进至 M1 拆解
- [2026-10-18] [变更]: M1-T1 落地：lib/resources/resource_store.dart 内核（导入 text-only+10MB / 清单原子写 / 读全文 / 改名 / 删除幂等 / 损坏返空库 DEGRADE；ResourceStoreException code+hint）；新域三处同步（kGoodhubDomains + standards §1.0 矩阵/mermaid + index.md 落点行）；单测 11 例
- [2026-10-18] [验证]: flutter analyze → 0 issue；flutter test --timeout 180s → 819 全绿；toolbox run arch-guard → 通过
- [2026-10-18] [变更]: 外评审评估与修订轮：4 裂缝裁定（悬垂句柄简化采纳=两段式删除容错；headPreview 静态截取采纳；文本嗅探=Isolate.run 解码采纳、扩展名白名单不采纳；64KB 读窗口成立=RC4）+ 3 漏洞（并发写已被路径级互斥覆盖、改名已实现、配额=RC5 仅展示占用）。落地：内核补 headPreview/Isolate 解码/delete 容错，单测 15 例，设计稿 §2/§4/§5/§6 同步
- [2026-10-18] [验证]: flutter analyze → 0 issue；flutter test --timeout 180s → 823 全绿
- [2026-10-18] [变更]: 外评审二轮修订：3 边界全采纳（64KB 截断多字节边界回退=readContentWindow + allowMalformed 末防线；headPreview BOM 剥离 + (empty) 兜底；reconcileOrphans 孤儿对账 >1h 静默清理）+ 3 缺口（重名去重 (n) 后缀采纳；导出 cacheDir 防护/附件退回仅焚句柄落设计稿 §4，content-hash 去重登记二期候选）。单测 23 例，接线（启动对账/导出动作）登记 T2
- [2026-10-18] [验证]: flutter analyze → 0 issue；flutter test --timeout 180s → 831 全绿
- [2026-10-18] [变更]: 外评审三轮修订：4 项裁定（cacheDir/external 临时副本堆积=成立，reconcileOrphans 扩 extraDirs 24h 清理；外部打开同名锁死=成立，导出路径改唯一随机前缀，落 T2；截断无限重调死循环=成立最关键，工具 description/TrackNote 硬约束落设计稿 T3 实现；导入竞态误删=无实际 bug，1h 阈值已远大于毫秒级竞态窗口，顺手升 2h）。内核 24 例，全量 832 绿
- [2026-10-18] [验证]: flutter analyze → 0 issue；flutter test --timeout 180s → 832 全绿；docs-lint → 通过
- [2026-10-18] [变更]: 外评审四轮修订：一致性两条（评审前提失实——「永久不做内建查看」从未拍板，§1/§6 系新拍板 RC6 而非纠偏补登）+ NUL 探测采纳（首 1KB 含 \x00 → not_text，utf8 对空字节判合法须显式查）+ models/ 拆分不采纳（~460 行远低于 800 红线）。RC6 拍板 = 纯外部唤起。内核 25 例，全量 833 绿
- [2026-10-18] [验证]: flutter analyze → 0 issue；flutter test --timeout 180s → 833 全绿；docs-lint → 通过
- [2026-10-18] [变更]: M1-T2 落地：resource_center_section 段（导入 file_picker（新依赖用户确认）/改名/删除/外部打开/RC5 占用展示；注入位四件 §8.1；keepAlive 闸第 7 段；reconcileOrphans 进入段触发含 cache external 24h 清理）+ settings_page 挂载 + lib/app/external_open.dart 平台收敛件（open_filex 先例口径）+ ui→resources 直连白名单登记。修内核真 bug：load() 重入不清内存致清单条目重复（重复 ValueKey build 崩）。段单测 7 例，全量 843 绿
- [2026-10-18] [验证]: flutter analyze → 0 issue；flutter test --timeout 180s → 843 全绿；arch-guard → 通过；docs-lint → 通过
- [2026-10-19] [变更]: M1-T3 落地：对话注入链闭环——composer 附件药丸行（B6 三件式不破，入口在药丸行内）+ showResourcePickerSheet（resource_center_section 导出，白名单内零新边，chat_page 只持 record）+ McpRuntime.assemble(resourceAttachments/resourceStore 注入位) 装配期全文落 run 级 $ref 池（ResourceAttachmentBinder，句柄仅合流记账）+ LocalResourceToolExecutor（Gateway 内侧 L2 首读确认 / readContentWindow 64KB / description+TrackNote 防死循环双处硬约束）。矩阵同步：coordinator→resources 开闸（§1.0+mermaid+R1）。实现定稿：工具入参=resource_id 防注水击穿窗口（设计稿 §2 已回填）。工具/binder 单测 9 例，全量 852 绿
- [2026-10-19] [验证]: flutter analyze → 0 issue；flutter test --timeout 180s → 852 全绿；docs-lint → 通过
- [2026-10-19] [变更]: IA 归位·资源中心拆出为独立页：新建 lib/ui/resource_center_page.dart（Scaffold+AppBar「资源中心」+ListView 承载 ResourceCenterSection）；settings_page 移除原第七段与 import；入口改由会话侧边栏底部直达（conversation_drawer 加 ListTile，紧随「设置」，对齐 TaskLedgerPage 2026-10-18 同款迁移先例）。理由：设置=配置面、资源中心=用户资产数据面，二者同居致高频管理动作沉在二级配置页，并倒逼 composer 另开常驻资源行（输入条堆到 3 行）
- [2026-10-19] [变更]: 面板级错误行口径收敛：抽出 lib/ui/components/panel_error_row.dart 为唯一实现，settings_page._panelError 改为委托（零行为变更），新独立页复用同一 builder——避免两宿主各抄一份
- [2026-10-19] [变更]: settings_page 文件头 scope 边界声明同步（段数「六段」→「八段」表述统一 + 补登 2026-10-19 资源中心迁出沿革）；原编号 ①~⑦ 与实际 ListView 顺序/数量漂移属存量文档债，随本次迁出清理
- [2026-10-19] [变更]: keepalive 闸同步：ResourceCenterSection 已不处于设置页 ListView 滚动复用场景，从 settings_sections_keepalive_test 断言列表移除（段行为仍由 test/ui/resource_center_section_test.dart 覆盖，7 例）
- [2026-10-19] [验证]: flutter analyze → 0 issue；flutter test --timeout 180s → 852 全绿；toolbox run arch-guard → 通过
- [2026-10-19] [变更]: IA 归位二步·**选择即收集**：`showResourcePickerSheet` 加首项「从系统选择…」→ file_picker → 经 `ResourceStore.import` 闸门入库 → 返回 `collected=true`；库列表项返回 `collected=false`。**消除「先导入才能用」硬门槛**（原空库文案「请先在设置导入」作废）——使用面（run 级）与管理面（持久）不再互为前置
- [2026-10-19] [变更]: 入库副作用明示 + 可撤销：chat_page `_pickResource` 接住 collected → SnackBar「已收入资源中心：<name>」+「撤销」（撤销 = 移出待发项 + 删本次收集条目；**collected=false 只移待发项，不得删库**）。复用记忆胶囊「已记录 · 撤销」既有交互语法（page-beautify B2 先例）
- [2026-10-19] [变更]: **闸门不旁路**落为显式约束：直选结果必须经 `import`（存在性 / 10MB / utf8 严格解码 / NUL 探测 / tmp+rename 复制入库），拒收文案在 sheet 内明示（`pick-error` 键）；禁为「快捷」直持原路径注入——否则原文件改删致会话引用漂移
- [2026-10-19] [变更]: **store 单实例收敛**：ServiceDirectory 增 `resourceStore()`（应用级单实例 + `resourceStoreOverride` 测试注入位），picker sheet 与管理页段共用；原 sheet 每次调用 `underSupportDir` 新建实例并 `load()` 读盘一遍（规格 §4 并发纪律「不新造」）
- [2026-10-19] [变更]: 运行守卫改走 `_guardRunning('附加资源')`：原 `if (_status.running) return;` 属静默禁用——入口常驻却点了没反应（交互 SSOT §1 明令禁止）
- [2026-10-19] [变更]: 面板级错误行口径收敛至 `components/panel_error_row.dart`（设置页 `_panelError` 改为委托，零行为变更），拆出的资源中心页复用同一 builder——避免两宿主各抄一份
- [2026-10-19] [变更]: IA 归位三步·**附件行改按需展开**：仅 `pendingResources` 非空时展开 44dp（`AnimatedContainer` 0→44，复用状态带 idle 收 0 手法）；空态入口收进 composer 左端「+」统一挂载菜单；撤掉常驻说明文案（与 TextField hint 构成双 hint）。药丸默认 1 行——B6「输入行只保留 + + 文本 + 发送」的拍板实质至此落地，新增能力不再持续挤占输入区
- [2026-10-19] [变更]: 会话上下文 sheet 加「附加资源… / 管理资源中心…」两项：资源与服务绑定同属**本次会话挂载物**，收口到「+」单一入口；热区 48×44 对齐 ui-design §4.4（原附件钮 40×36 低于红线）
- [2026-10-19] [变更]: 直选入库后 `await store.ioDrained` 再 pop——消除「已返回但清单未落盘」的窗口（管理页/下次 picker 必然可见）；测试端轮询预算 30→60 轮，防全量并发跑时 IO 排队致 flaky（首次全量曾偶发红）
- [2026-10-19] [变更]: **美学一致性一轮**（#7 + #8 + #12 合并）：① 附件药丸弃 Material 默认 `InputChip`（自带 delete 皮与默认间距，与控制台件族不同源），改自绘 `_ResourceChip`——hairline 边框 + `cardRadius` + `codeBg` 微深底 + `dataRef` 文件图标，与 `StatusCapsule` / `ContextChip` 同族；② 资源段右上导入钮 `Icons.add` → `Icons.upload_file_outlined`（原与 composer 左端「+」挂载菜单同形异义）；③ composer attach 钮 tooltip 改准「附加资源…（资源中心 / 本地文件）」——面板确有系统选择路径，回形针语义成立，图标不改
- [2026-10-19] [变更]: **规范内部冲突消解**：`ui-design.md` §5 补登「底部输入条（胶囊形）24dp」为独立档位，并注明与总纲③的关系（③针对装饰性卡片/面板；输入条大圆角承担「此处可输入」的形状识别，属功能形状而非装饰）——消除「全局禁 >16dp」与既有药丸实现长期打架，实现不动
- [2026-10-19] [修复]: `_bootstrap` 缓存路径**求值顺序**：原 else 分支无条件 `await getTemporaryDirectory()`，即便已传 `cachePathOverride` 仍触平台通道（纯 Dart 环境抛 MissingPluginException → 面板误落错误态）；改为先判注入位再取平台路径。同时 `ResourceCenterPage` 补 `cachePathOverride` 注入位，使新页可在无插件环境验证
- [2026-10-19] [变更]: **生命周期文档（#11）**：`chat-interaction.md` §1 补两条——① 挂载入口收口（composer「+」= 本次会话统一挂载菜单，新增挂载类能力一律先进菜单、禁再开常驻行）；② 挂载物生命周期三档须在 UI 可辨（session 级绑定 / run 级附件 / 应用级持久库，合流不合并），禁让用户凭「都是输入框上面一条」自行推断
- [2026-10-19] [变更]: **#2 入库内容判重**（原二期候选，因直选路径提前落地）：`ResourceEntry` 增 `contentHash`（sha256 字节级）+ 内核 `entryByContentHash()`；`import()` 改返回 `ResourceImportResult` record（`{entry, reused}`）——同内容命中即**复用既有条目、不落副本**。判重两级：同名加 `(n)` 序号（改名产生的同名不同内容走此路）／同内容复用。**空哈希永不参与复用**——早于判重特性落库的历史条目不得互判为同内容
- [2026-10-19] [变更]: **判重接线与撤销语义边界**：picker sheet 直选命中复用 → `collected=false`，宿主给「已选用资源」回执、**不给撤销**（撤销 = 删本次收集；复选既有条目不属收集）；管理段导入命中复用 → 提示「内容已在资源中心」，不新增副本
- [2026-10-19] [变更]: 导入路径**解码与哈希一次 Isolate 内算完**（>1MB 时，§3.1 纪律）——既防主 isolate 掉帧，也避免为算哈希再扫一遍字节
- [2026-10-19] [验证]: flutter analyze → 0 issue；flutter test --timeout 180s → 859 全绿（本轮新增：资源中心页 smoke 1 例 + 同内容复用 1 例 + 美学一致性轮断言跟随）；toolbox run arch-guard → 通过；docs-lint → 通过
