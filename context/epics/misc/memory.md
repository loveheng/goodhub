---
dev-loop: memory
format: v1
epic: misc
total-merged: 5
last-merge: 2026-10-22
---

# misc

## 要点
- 项目接入定型（2026-10-10 dev-init 全流程）：scaffold 骨架 + goodhub-workflow / goodhub-index skill + AGENTS.md；MCP 接缝契约 SSOT 留 goodshare 仓 `docs/design/ai-app-split.md` 本仓只读引用；**纯本地项目不推远端**（用户拍板）。
- 工具链池（自 goodshare 移植、按本仓 coding-standards 重写）：`arch-guard`（UI 禁 dart:io / 平台分支，R1 白名单已清零、只减不增）、`docs-lint`、`commit-msg-gate`、`pre-commit-gate`、`build-apk` / `bump-version`（PKG=com.zzh.goodhub）、`release-r2` 薄包装入 toolbox（deploy 类）。发布链 = bump-version → `release-r2 --json` 预检 → dry-run → `--commit`；Flutter 3.47.5 registrant 坑（release 构建须 analyze 后剔除 integration_test 注册块 + `--no-pub`）已修入 build-apk / release-r2。
- 规范结构定型：工程事实住 `docs/project/`（coding-standards §1~§9 + index.md 五节数据），skill 只放规约、零业务数据；workflow skill 终态 = 分工表 + 阶段锚定 + 触发器 + 命令环境 + lessons 指针；触发器只维护 standards，index/代码枚举归 goodhub-index；经验教训四段式显式标签单行落 lessons（归并门禁 = 四段齐备）。
- 交互 SSOT 当前口径：输入行只留「+ + 文本 + 发送」三件式（选中/本地工具信息在输入框上方状态带）；主操作槽 = 无容器图标钮融于药丸与「+」对称（48×48 热区），三态换色（空输入 terminalMuted / 有输入 l1Info / 运行 dangerDeep）；会话绑定 = 单选列表恒有一项选中、「公共」常驻首项不可取消，新会话有钉选默认则跟随、无则公共；CallCard 终态默认压缩单行、头部整行可点展开/收回。
- 传输与状态机修复范式：EventChannel 频道名全局 handler 踩踏（多实例 close 互相杀死投递）→ Binder 事件全量收敛 MethodChannel 推挽合一 + 进程级静态路由表；心跳忙时免判探活 + 失败分级；「无会话静默早退」口径服务层与 archive owner 对齐（无当前会话/无 archive = 无需落盘 = true）。
- 全局存量债专项（2026-10-19 挂 misc，QC1~QC6 全部裁决并执行完毕）：QC1 修 context-lint 挂载行整行当路径的假阳性（MOUNT 4→0）；QC2 新工具 `ctx-fix` 入全局池（reclaim/hdr/checkpoint 确定性修复，默认干跑、--apply 落盘、自动备份、幂等、金丝雀）并全量执行，另修 devlog bp「有断点行但缺 `## 断点` 章节时永远补不上」bug；QC3 严守跨窗口纪律（七域语义债登记触发型待办）；QC4 台账去重（4 条同类快照并为 1 条专项总账）；QC5 授权代归并——5 个 epic 共 83 条 devlog 归并（thirdconnect 20 / system-assessment 20 / chatmessage 18 / page-revamp 14 / m4 11），MERGE 与 SSOT 全清；QC6 GROOM 洗盘（4 条真机验收同类并为 1 条总账，45→42；无 [long]/[once] 过期项可重评）。**全仓结论：29 违规 24 告警 → 0 违规；仅存告警 = GROOM 42>30 + MOUNT 3 提示级（无本仓设计稿可挂）**。
- 方法论落位（2026-10-19，新项目初始化即得、均带 self-test 断言）：① 读码纪律三段式（文档建图→定向读码→关键断言实证）——goodhub-workflow 增专节（项目实例+实证锚点），project-scaffold.sh 的 <repo>-workflow 模板预填，dev-init §1 第 3 步补枚举；方法住项目 skill，不进全局 dev-loop。② 文档评估方法论（六维判据 + 三级依赖分级）——project-scaffold.sh 的 <repo>-docs 模板预填，goodhub-docs 增 §4 项目实例（原 §4 顺延 §5）；两者配套：读码纪律管怎么读，文档评估方法论管读到的东西能信几分。
- context-lint.sh 三处修复（2026-10-19 根治）：① $ROOT/$R 分裂 bug——lint_mounts/lint_pointers 用原始 $ROOT 拼路径（不传 --root 时为空串致绝对路径假报），两处改 $R + self-test 增「cd 进夹具无 --root 不假报」回归断言；假告警 20→5。② lessons 归并口径——原 count `^- \[` 把正文四段式条目当待归并（归并后恒 ≥5 永误报），改为只数「## 待归并」节。③ devlog lesson 落点——原裸 append 落进上一主题节内致漏计，改入 inbox 节。伴随 [SSOT 修正]：lessons.md 工具链条目根因由「QC1 误判 toolbox cwd 错位」更正为「$ROOT/$R 分裂」，处置从绕行（一律显式传 --root）改为根治。
- prompt-mgmt 透明面两轮（看板第 4 Tab「提示词」只读总览；提示词 Tab「都是空」双根因修复——CoW keptLocal 覆写正文进注册表 + 看板改 eager build，全量 903 绿）已借道本 devlog、事实落 prompt-mgmt/memory.md，此处留指针不双写。
- **聊天页 P0+P1 降噪/信息架构两批（2026-10-22，用户逐批拍板；SSOT 已回填 `docs/product/chat-interaction.md`，updated 2026-10-22）**：
  - **P0（省面积 + 降噪）**：① 删 `chat_page` 输入区外层重复布局（SafeArea/Center/ConstrainedBox/Padding 已由 `ChatComposer` 自持），回收横 24dp + 底 16dp；② 状态带展开条件甩掉 `hasEndpoints`（它是「配置过端点」而非「有启用端点」，曾让多数用户恒挂一行「空闲 · 公共」白占 30dp），收紧为 `running||hasContext`；③ 每轮必出通告降噪——卸载服务数 / 全局 Prompt 跳过项经 `ChatStatusController.claimSessionNotice` 会话级去重（键随内容变、随会话焚），「✓ 任务完成」仅本轮零正文才补行；④ `CallCard` 折叠摘要经 `StatusStrip.plainToolName` 剥 `<serverId>__` 前缀（与状态带同口径，**禁各自现写 indexOf**），失败/中止摘要取相位色补第二通道（成功仍灰阶）；⑤ 折叠标题去黑话「Run 概要」→「N 条系统通告（点开查看）」。
  - **P1（信息架构）**：⑥ 挂载弹层改标题「挂载」并三级分组（会话绑定 session / 本次发送附件 run / 资源中心 应用级），组名 + 期限说明肉眼可辨；⑦ 记忆只留一处可管理位（AppBar 本轮记忆）——归因 BottomSheet 只给计数 + 直达（历史恢复态保旧样）；⑧ 运行中**只锁会话绑定**（它改写会话 slot 会扰动在途装配），资源类入口不跟着置灰、`_pickResource` 去运行守卫；⑨ 空输入发送给一次性 SnackBar（桌面端 Enter 曾零反馈 = 死控件）；⑩ 「回到最新」浮钮两态：`missedSinceDetach > 0` 挂计数徽标 + tooltip 明说条数，纯翻页态保持低调。
  - **验证**：全仓 analyze 0 issue；`flutter test --timeout 180s` 985 绿（基线 972 + P0 7 + P1 6）；arch-guard / docs-lint OK。**未执行**：真机走查（输入法弹起后输入区实占高、多轮轨道密度、徽标深浅底对比）。

## 断点
- [断点] 下一步：QC1~QC7 全部裁决并执行完毕，专项收口：全仓 0 违规、仅存 GROOM 42>30 + MOUNT 3 提示级（QC7 裁决长期接受）；GROOM 进一步收敛需用户对具体条目存废做价值判断（非机械范畴）
