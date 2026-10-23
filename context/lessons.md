---
dev-loop: lessons
format: v1
epic: global
total-merged: 6
last-merge: 2026-10-23
---

# lessons

维护协议（使用时机/录入准则/四段格式/清零纪律）SSOT = `.agents/skills/goodhub-workflow/SKILL.md`「经验教训维护协议」节——规则住 skill，本文件只承载数据正文（防双源）

## llm / 模型部署

- 手工 run-as 铺模型文件到 app_flutter 后 App 报模型未下载，run-as ls 却看得到文件 ➔ Context.getDir(name) 自动加 app_ 前缀，真实 documents 路径 = app_app_flutter/llm_models/，按字面名铺必错位 ➔ 铺文件铺到 app_app_flutter；App 视角看不见时在原生桥加逐层 exists/canRead/list 取证日志直证，勿信 run-as 视角 (Ref: init)
- [hybrid_cloud_engine] 流内事件间隙超时(interEventGapTimeout)永不触发，整流误判 healthy ➔ 事件处理器内重装计时器的三元 isFirst ? firstTokenTimeout : interEventGapTimeout 在首个事件到达时(isFirst=true)重装了 firstTokenTimeout——「本事件之前」的预算被错装到「本事件之后」的间隙上 ➔ 双阈值计时器：初始计时与事件后续计时是两个装配点，事件处理器里重装的预算必须是「本事件之后」的预算；代码与自身注释矛盾时先怀疑代码，注释即意图 | 回归：间隙超时类断言须覆盖首事件/间隙两个装配点，撤修复即红 (Ref: chatmessage)

## android-ops

- adb shell 传复杂命令时 sh -c 引号会被 adb 拆散——分步执行（逐条 adb shell / run-as），不拼单行复合命令 (Ref: init)
- goodshare 整包 debug（8066）覆装真机报 INSTALL_FAILED_VERSION_DOWNGRADE ➔ 设备在位的是 --split-per-abi 的 arm64 拆分包，Flutter splits 对拆分产物自动 versionCode=pub+2000（8066+2000=10066），整包数值更低被判降级 ➔ goodshare 真机覆装一律用 --split-per-abi 产物 app-arm64-v8a-debug.apk；装机基线纪律=拆分包进设备、整包不发 (Ref: init)
- adb input text 输入 URL 被设备拼音 IME 全角化（HTTP：／／…全角冒号句号）➔ input text 走 IME 转换层，中文键盘全角模式会变形 ➔ 自驱前先 ime set com.google.android.inputmethod.latin/...LatinIME；uiautomator dump 对 Flutter 页语义树可能残缺（只出 2 个节点）➔ 以 screencap 截图+坐标换算（物理分辨率/截图尺寸）为准 (Ref: init)
- integration_test 跑完后 build/app/outputs/flutter-apk/app-debug.apk 被测试入口构建覆盖（Dart 入口=测试文件而非 lib/main.dart），adb install -r 装回后点图标启动的是测试壳（只注册测试不 runApp）→ 永卡闪屏+黑屏+logcat 零 flutter 日志，与 Impeller 黑屏同表象但根因不同 ➔ 真机装包纪律：integration_test 跑完要装机验证，必须先 `flutter build apk --debug` 重建正式入口再 install；黑屏取证三件套=dumpsys window 查 mTopFullscreenOpaqueWindowState + screencap + logcat 查 flutter: 日志（零 Dart 日志=入口不对，非渲染问题） (Ref: thirdconnect)
- 真机自驱输入 URL：ime set 到 Gboard(LatinIME) 后 input text 仍被中文候选转换（HTTP：／／全角化复现）——Gboard 单实例承载多语言，ime set 只切 IME 不切键盘语言 ➔ 英文/URL 类自驱输入不可靠 ➔ 真机联调遇文本输入面直接交人工手输，AI 侧只做 tap/screencap/坐标换算（截图尺寸=物理分辨率，显示缩放图必错位） | 回归：AI 自驱脚本不含文本输入步骤，输入面列为人工节点 (Ref: m4)

## 持久化 / JSON

- jsonDecode 嵌套段是 Map<String, dynamic>，`is Map<String, Object?>` 恒 false（泛型不变、dynamic 运行时非 Object?）➔ JSON 持久化读路径必须逐层显式转换（for-comprehension 重建），顶层 as cast 穿不透嵌套段，嵌套判断静默返 null (Ref: m2-5-skill-refstore)
- 持久化类读方法若不与写方法同走装载路径，新实例读回恒空（同实例测试路径被写方法的顺带装载掩盖）➔ 读方法首行强制触发 _load；『写→新实例→读回』用例是抓装载体空转的关键，同实例断言测不出这类 bug (Ref: m2-5-skill-refstore)

## coordinator / 执行链装配

- 现象: 同型丢层风险散落多处 ToolExecutor 链装配点，单点钉子覆盖不到（手工包裹处共 4 处） | 根因: 纪律型约束（必须逐层向外包裹）靠人守；各层类各自持有 final inner 字段 → 调用点可自由把新层指向链中段，内层即被整层丢弃 | 处置: 引入唯一装配器 composeToolExecutorChain（层工厂制：层接收已装好的下一层，折叠方向固定逐层向外 → 错误形状不可表达）+ 机械门禁 arch-guard R9（禁 inner 指向执行面实例变量，例外：装配器层工厂形态与内联终端构造）+ flutter-test 镜像 | 回归: test/architecture/executor_chain_rules_test.dart（金丝雀）+ test/coordinator/tool_executor_chain_test.dart（层序/全成员在场/末端兜底）；arch-guard.sh --self-test 含 R9 正反样本 (Ref: host-tools-gateway-export)
- 现象: 宿主虚拟服务工具目录可见但调用全败（get_host_status 返回「未接入执行面」，真机生产路径必现） | 根因: 逐层向外包裹的执行链把新层的 inner 指向了链上任一段而非已装好的整条链——内层 status 层被整层覆盖丢弃，且单测只覆盖 resolver 抛错/返 null，缺「resolver 返回真实 store」的装配等价性用例 | 处置: 新层 inner 必须指向已装好的整条链（inner: executor）；任何多层执行面/装饰器链装配点须附「全成员在场可调」等价性用例，登记项另附「执行面可达」防悬空 | 回归: test/coordinator/host_tool_invoker_test.dart「装配等价性（全成员在场）」+「Allowlist 登记项可达」（撤修复即红）；规则见 docs/project/coding-standards.md §8.1「链式装配等价性」 (Ref: host-tools-gateway-export)

## mcp / 传输

- dart:io HttpResponse.bufferOutput 默认 true——SSE 流内帧（中途 progress/心跳/反向请求）全部缓冲滞留到连接关闭才一次性发出，join 全量断言的测试抓不到（读完再验），只有增量逐帧消费的测试能暴露 ➔ SSE 起始处必须 bufferOutput=false，真机中途帧联调前置依赖此修复；**好仓每一处新写 SSE 承载面都要复查此修复**——G1 gateway_server.dart（晚于 goodshare 修复 1 天新写）就漏了，真网外部客户端实测（progress 4 帧挤压收尾 1ms）才暴露；现已有逐帧计时回归钉子 test/gateway/gateway_server_test.dart「SSE 进度帧即达」（撤修复即红，已验证能咬人） (Ref: m3-ui-subs-sampling, thirdconnect)
- [flutter/event-channel] 现象: 发送信息后卡死——三任务并发 tools/call 全部永久悬挂（卡「执行中…」），占位回包正常、终帧不到 Dart | 根因: Flutter EventChannel.receiveBroadcastStream 的消息处理器按**频道名**全局单例——全部 BinderTransport 实例（goodshare-binder / shiguang-binder / 网关挂载 / 多轮 Run）复用同一频道名，任一实例 close/cancel 即 setMessageHandler(name,null) 置空全局 handler，静默杀死其他实例的事件投递（原生 onEvent deliver sinkNull=false 但 Dart _onNativeEvent 永不被调用；MethodChannel 回包路径不受影响，故「发得出、收不回」） | 处置: 最终全量收敛至 MethodChannel 推挽合一（C 方案）——原生删 EventChannel/StreamHandler，经主线程 invokeMethod 推帧且每帧带 ACK 回执（路由命中 delivered=true，丢件计数留痕），Dart 静态路由表 setMethodCallHandler 只设一次、永不按实例注销，结构性消除整类踩踏；中间态（进程级单流+引用计数）为第一步已被 C 取代 | 判据：平台消息双链（回包+事件）同时不到 Dart 且 VM service getStack  isolate 空闲 = 先查 EventChannel 频道名被多实例共享，勿猜 isolate 同步阻塞 | 回归: 全量 781 绿（5 枚事件路由钉子）+ 真机三场景（正常全流程 / binderDied 自动重连 / 冷启动首轮装配） (Ref: misc)
- [flutter/method-channel] 同频道 FIFO：构造器里「状态对齐」（如 resetAllTransports）若后于 bind 入队，原生按序处理会把刚 bind 的传输清掉（unknown transport 挂载失败，进程首轮装配必现、之后自愈极易漏检）➔ 依赖同频道消息顺序的初始化握手，对齐调用必须先于功能调用入队；真机冷启动首轮装配是这类顺序 bug 的唯一可靠暴露面，单测 mock 不保序抓不到 (Ref: misc)
- [mcp-heartbeat] 现象: 对话窗口并行调用 MCP 服务时全部服务依次中断(「在途 N 个已取消」回告) | 根因: 心跳 ping 不分「server 忙」与「server 死」, 并行负载下 ping 排队超 5s×2 次即误判 offline, D18 级联取消该连接全部在途流式请求 | 处置: ConnectionHealth 增 isAlive 探针(McpToolFace.hasRecentStreamActivity, 进度帧 60s 活跃窗)——忙时超时豁免计数; 连接级错误恒计数, 空闲超时仍计数 | 回归: 真机多任务并发无「在途 N 个已取消」误回告 (Ref: misc)
- 现象: HostTransport.sendStream 只吐 `data: {...}` 一行，SSE 单帧缺末尾空行 | 根因: SSE 以空行分帧，单帧无空行时 `callWithProgress` 的逐行累积永不 flush → 抛「流结束但无 result 帧」，网关 tools/call 返回 isError（PR1-3 端到端用例当场暴露） | 处置: 帧序列写成 `["data: $body", ""]`（同 BinderTransport._emitFrame），任何自造 SSE 传输都要带末尾空行 | 回归: test/mcp/host_transport_test.dart 真实协议层 callWithProgress 用例（撤修复即红） (Ref: host-tools-gateway-export)

## flutter / widget 测试

- ListView 六段重排后 3 个用例「元素不见了」 ➔ 重排让目标落到懒构建视口外，且单向 `dragUntilVisible(Offset(0,-60))` 在目标位于**上方**时永远找不到（只向下滚）并超时 10min ➔ 断言前先 `finder.evaluate()` 判是否已构建：已构建走 `ensureVisible`，未构建先 `drag` 回列表顶部再向下逐屏找；面板顺序是测试隐性依赖，重排必同步修测试滚动 | 回归：widget 测试无 10min 级超时即证滚动判据生效 (Ref: page-revamp)
- `TrustedPlugins` 是进程内单例（缓存 SharedPreferences 句柄）➔ `setMockInitialValues` 重置 mock 但单例仍持旧句柄，上一用例写入的白名单残留到下一用例（单跑绿、全套红）➔ 单例型 store 的用例要么显式幂等清理（用例开头把状态复位），要么换用互不冲突的键；判据「单跑过/全套挂」先怀疑跨用例单例残留 | 回归：全套连跑与单跑结果一致 (Ref: page-revamp)
- MethodChannel 无 mock handler 时 invokeMethod 的 Future 挂起永不完成（不抛 MissingPluginException）➔ 测试二进制信使对未注册通道静默丢弃不回包，异常路径只有显式 mock 抛错时才走 ➔ 依赖平台通道的 initState 异步链（如本地插件发现 scan）在 widget 测试必须 setMockMethodCallHandler 回 null；判据：debugPrint 逐段插桩看断在哪一个 await | 回归：依赖平台通道的 widget 用例不出现静默挂起 (Ref: ux-hardening)

## dart / 语言与结构性编辑

- 闭包在 late final 局部变量声明前引用它编译报错「can't be referenced before it is declared」➔ Dart 禁止 late 局部变量在声明位置之前的闭包中引用（闭包可能早于初始化被调用）➔ 含 late final 局部变量且闭包需引用它时，把声明前置到闭包定义之前（即使赋值在后） | 回归：analyze 通过即证声明序正确 (Ref: chatmessage)
- 大块结构增量 replace 编辑可静默损坏文件（重复 Text(、括号错位），直到 flutter analyze/dart format 才暴露，且报错行号离肇事编辑很远 ➔ 根因未实证（疑半应用状态落盘；本会话两处：memory_board _opsTab、settings BYOK 头部，均靠 analyze 咬住）➔ 多行结构编辑后立即跑 dart format（解析通过=最快结构探针）+ analyze；大块重写优先整段替换（splice/write），勿依赖连续小 replace 拼结构 | 回归：每次多行编辑后 dart format + analyze 双通过 (Ref: ux-hardening)

## 架构 / 信任闸门

- 本地插件「撤销信任」一度被认为要断开连接池 ➔ 实际 `isTrusted` 只在**装配期**校验两处（chat_page 本机弹卡 / gateway_controller 网关跳过），不是长连接状态 ➔ 撤销=移出白名单即为完整语义，无需动 ConnectionManager；先查消费点再定语义，别按直觉估工作量 | 回归：撤销信任不断连接、仅移出白名单，trusted_plugins 断言不变 (Ref: page-revamp)

## docs / 文档纪律

- [docs/终态纪律] AI 生成文档混入过程数据——goodhub-docs 域表曾硬编码文档数（3/4/14）、迁入时间线备注（「ui-design 于 2026-10-17 自 product 迁入」）、「暂无 + 解释正常流程」伪例外段，lessons.md 自身也有整段重复的待归并块 | 根因：AI 写文档倾向自证过程（何时新增/原来没有/为什么不冲突），未区分「现行事实」与「关于事实的历史」 | 处置：终态文档只写现行事实，过程/时间线/变更叙事一律归 devlog；docs-spec §7 反模式立法 + goodhub-docs 域表重写落地 | 回归：docs-lint 属机械校验抓不住语义级过程数据，依赖评审抽查 (Ref: misc)

## 构建 / 发布

- [release-r2.sh] flutter analyze 含 issue 即 exit 1（存量 info 也算）➔ release-r2.sh set -e 被 1 条 deprecated info 中止构建 ➔ 发布脚本 analyze 降为告警不阻断，交付门槛由日常 analyze/test 把守 | 回归：release-r2 构建链对存量 info 放行、对新增 error 仍阻断 (Ref: self-update)

## 工具链 / toolbox

- `toolbox run todos add` 的事项文本经 shell 传递，禁用反引号与 `$`——反引号被 bash 当命令替换执行（实测落盘后开头被吞），`$` 被变量展开 ➔ 带这两种字符的条目改用 Edit 直接写文件，勿走 shell（事后补回易漏且留双源） (Ref: misc)
- `todos add --src` 必须以 `ai` 或 `用户` 起头（可带 `, 说明` 后缀）——写 `agent` 被拒（exit 1，误以为落盘失败） (Ref: misc)
- 域内 `todos.md` 机械件格式：标题须为 `# <epic名> · 域内待办`、frontmatter 须 `format: v3` + `epic: <名>`，否则 `todos add` 报「缺标题行」拒绝写入——存量 v2 域文件首次写入前先改头部 (Ref: misc)
- 现象: `write_to_file` 大 content / `replace_in_file` 长 old_str 多次触发 IDE 参数丢失（写入内容被截断或丢失） | 根因: 工具入参长度上限 + IDE 传参链路对超长/多行入参不稳（非项目代码问题） | 处置: 改用 `cat >> file <<EOF` 分块落盘 + python 精确替换绕过；heredoc 命令有 8000 字节上限，超出再分块 | 回归: 机械规则——写入类操作入参超 8000 字节即分块（无自动化钉子，属操作纪律） (Ref: host-tools-gateway-export)
- LiteRT-LM 迁移：R8 混淆致 JNI SIGABRT ➔ proguard 必须 keep `-keep class com.google.ai.edge.** { *; }` (Ref: init)
- release 构建踩坑（Flutter 3.47.5）：`dev_dependencies` 的 `integration_test` 会被 `flutter pub get`/`flutter analyze` 以非 release 语义反复写入 `android GeneratedPluginRegistrant.java`，但其原生类不进 release classpath ➔ `compileReleaseJavaWithJavac` 报「程序包 dev.flutter.plugins.integration_test 不存在」构建失败 ➔ `release-r2.sh` 在 analyze 之后用 python 剔除 registrant 中该 try/catch 注册块 + 构建带 `--no-pub`（patch 早于 analyze 会被覆盖；build 阶段 pub get 会再写脏）；上游修复后可删脚本中该段 (Ref: self-update)
- [工具链/toolbox] 现象: toolbox run cl 裸跑（不传 --root）时 15 个 epic 伪报「挂载失效：docs/design/*.md 不存在」（文件实际存在），带 --root 跑仅 3 条真实告警 | 根因: context-lint.sh 的 lint_mounts/lint_pointers 用原始 $ROOT 拼路径（不传 --root 时为空串 → tp=/docs/... 绝对路径必不存在），而非 lint_data 解析后的 $R（含 pwd 回退）；toolbox 的 cwd 继承正常——QC1 曾误判为「工具库目录 exec 致基准错位」，「一律显式传 --root」绕行治标未治本 | 处置: 2026-10-19 根治——两处 $ROOT 改 $R + self-test 增「cd 进夹具无 --root 不假报」断言；显式传 --root 仍是良好习惯但不再必需 | 回归: context-lint.sh --self-test 含无 --root 断言（toolbox run cl 与 --root 直跑结论一致：0 违规 5 告警） (Ref: misc)

## 待归并（inbox）

- [架构/契约面漂移] 现象: 单轴化改名（D1）后漏检 7 处契约面漂移（PC 文案旧键 3 + SSOT 文档矛盾 4），全靠人工评估轮发现 | 根因: 契约面变更需同时改「代码 / 面向下游文案 / SSOT 文档」三面，人工扫漏检率高且随项目数放大（框架级病害，非单项目问题） | 处置: 机械件化——引擎全局共用（零项目知识）+ 规则数据留各项目 registry（只加数据行不改代码）+ Dart 镜像进 CI；散文级集合描述一致性机械不可靠，明确不做扫描归人判 | 回归: drift-guard（BANNED/CONST/OVERSIZE 三类）+ test/architecture/drift_rules_test.dart 镜像；rules 文档 docs/design/meta-upgrade.md (Ref: meta-upgrade)

- [工具链/grep] 现象: 扫描器逐文件 grep 后按 path:lineno:code 解析路径，取到的是行号当路径（如 FAIL 119: ...），且整行注释未被剔除（误报本仓两处 /// 注释） | 根因: GNU grep 单文件操作数时 -n 只输出 lineno:code（不输出文件名；多文件/目录操作数才输出），解析器按多文件形态假设取值即错 | 处置: 扫描器一律加 -H 强制文件名输出（单/多操作数一致），并按扩展名分派行级过滤（.dart 整行注释 // 与 * 起头剔除） | 回归: drift-guard --self-test 金丝雀（坏样本含 // 注释与代码两种形态）+ 真实仓变异探针（注入即红/还原即绿） (Ref: meta-upgrade)

（空——2026-10-23 归并：coordinator/装配 ×2 →「coordinator / 执行链装配」节；工具链 ×1 →「工具链 / toolbox」节；mcp/传输 ×1 →「mcp / 传输」节）
- [工具链/release] 现象: release-r2 构建报「GeneratedPluginRegistrant.java 找不到符号 PackageInfoPlugin」，单跑子项目 :package_info_plus:assembleRelease 成功但 :app javac 仍失败 | 根因: 插件 release 变体 Kotlin 增量编译产物脏——intermediates/runtime_library_classes_jar/release/classes.jar 里只有目录项+kotlin_module 无 class（debug 变体正常），`:app:compileReleaseJavaWithJavac` 因符号缺失失败；与 §74 integration_test registrant 污染是同位置不同根因（该坑是增量产物脏，非 registrant 内容错） | 处置: flutter clean && flutter pub get 后重跑 release-r2 --commit 即过；诊断口诀=unzip -l 看 release classes.jar 是否有 class，空则清增量而非改脚本 | 回归: 无自动化钉子（发布脚本内联），机械规则=release javac 报插件类缺失且子项目单跑成功 → 先 flutter clean 再查脚本 (Ref: self-update)
