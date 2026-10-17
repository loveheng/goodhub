---
dev-loop: lessons
format: v1
epic: global
total-merged: 4
last-merge: 2026-10-11
---

# lessons

维护协议（使用时机/录入准则/四段格式/清零纪律）SSOT = `.agents/skills/goodhub-workflow/SKILL.md`「经验教训维护协议」节——规则住 skill，本文件只承载数据正文（防双源）

## llm / 模型部署

- 手工 run-as 铺模型文件到 app_flutter 后 App 报模型未下载，run-as ls 却看得到文件 ➔ Context.getDir(name) 自动加 app_ 前缀，真实 documents 路径 = app_app_flutter/llm_models/，按字面名铺必错位 ➔ 铺文件铺到 app_app_flutter；App 视角看不见时在原生桥加逐层 exists/canRead/list 取证日志直证，勿信 run-as 视角 (Ref: init)

## android-ops

- adb shell 传复杂命令时 sh -c 引号会被 adb 拆散——分步执行（逐条 adb shell / run-as），不拼单行复合命令 (Ref: init)
- goodshare 整包 debug（8066）覆装真机报 INSTALL_FAILED_VERSION_DOWNGRADE ➔ 设备在位的是 --split-per-abi 的 arm64 拆分包，Flutter splits 对拆分产物自动 versionCode=pub+2000（8066+2000=10066），整包数值更低被判降级 ➔ goodshare 真机覆装一律用 --split-per-abi 产物 app-arm64-v8a-debug.apk；装机基线纪律=拆分包进设备、整包不发 (Ref: init)
- adb input text 输入 URL 被设备拼音 IME 全角化（HTTP：／／…全角冒号句号）➔ input text 走 IME 转换层，中文键盘全角模式会变形 ➔ 自驱前先 ime set com.google.android.inputmethod.latin/...LatinIME；uiautomator dump 对 Flutter 页语义树可能残缺（只出 2 个节点）➔ 以 screencap 截图+坐标换算（物理分辨率/截图尺寸）为准 (Ref: init)
- integration_test 跑完后 build/app/outputs/flutter-apk/app-debug.apk 被测试入口构建覆盖（Dart 入口=测试文件而非 lib/main.dart），adb install -r 装回后点图标启动的是测试壳（只注册测试不 runApp）→ 永卡闪屏+黑屏+logcat 零 flutter 日志，与 Impeller 黑屏同表象但根因不同 ➔ 真机装包纪律：integration_test 跑完要装机验证，必须先 `flutter build apk --debug` 重建正式入口再 install；黑屏取证三件套=dumpsys window 查 mTopFullscreenOpaqueWindowState + screencap + logcat 查 flutter: 日志（零 Dart 日志=入口不对，非渲染问题） (Ref: thirdconnect)

## 持久化 / JSON

- jsonDecode 嵌套段是 Map<String, dynamic>，`is Map<String, Object?>` 恒 false（泛型不变、dynamic 运行时非 Object?）➔ JSON 持久化读路径必须逐层显式转换（for-comprehension 重建），顶层 as cast 穿不透嵌套段，嵌套判断静默返 null (Ref: m2-5-skill-refstore)
- 持久化类读方法若不与写方法同走装载路径，新实例读回恒空（同实例测试路径被写方法的顺带装载掩盖）➔ 读方法首行强制触发 _load；『写→新实例→读回』用例是抓装载体空转的关键，同实例断言测不出这类 bug (Ref: m2-5-skill-refstore)

## mcp / 传输

- dart:io HttpResponse.bufferOutput 默认 true——SSE 流内帧（中途 progress/心跳/反向请求）全部缓冲滞留到连接关闭才一次性发出，join 全量断言的测试抓不到（读完再验），只有增量逐帧消费的测试能暴露 ➔ SSE 起始处必须 bufferOutput=false，真机中途帧联调前置依赖此修复；**好仓每一处新写 SSE 承载面都要复查此修复**——G1 gateway_server.dart（晚于 goodshare 修复 1 天新写）就漏了，真网外部客户端实测（progress 4 帧挤压收尾 1ms）才暴露；现已有逐帧计时回归钉子 test/gateway/gateway_server_test.dart「SSE 进度帧即达」（撤修复即红，已验证能咬人） (Ref: m3-ui-subs-sampling, thirdconnect)

## 工具链 / toolbox

- `toolbox run todos add` 的事项文本经 shell 传递，禁用反引号与 `$`——反引号被 bash 当命令替换执行（实测落盘后开头被吞），`$` 被变量展开 ➔ 带这两种字符的条目改用 Edit 直接写文件，勿走 shell（事后补回易漏且留双源）(Ref: misc)
- `todos add --src` 必须以 `ai` 或 `用户` 起头（可带 `, 说明` 后缀）——写 `agent` 被拒（exit 1，误以为落盘失败）(Ref: misc)
- 域内 `todos.md` 机械件格式：标题须为 `# <epic名> · 域内待办`、frontmatter 须 `format: v3` + `epic: <名>`，否则 `todos add` 报「缺标题行」拒绝写入——存量 v2 域文件首次写入前先改头部 (Ref: misc)
- LiteRT-LM 迁移：R8 混淆致 JNI SIGABRT ➔ proguard 必须 keep `-keep class com.google.ai.edge.** { *; }` (Ref: init)
- release 构建踩坑（Flutter 3.47.5）：`dev_dependencies` 的 `integration_test` 会被 `flutter pub get`/`flutter analyze` 以非 release 语义反复写入 `android GeneratedPluginRegistrant.java`，但其原生类不进 release classpath ➔ `compileReleaseJavaWithJavac` 报「程序包 dev.flutter.plugins.integration_test 不存在」构建失败 ➔ `release-r2.sh` 在 analyze 之后用 python 剔除 registrant 中该 try/catch 注册块 + 构建带 `--no-pub`（patch 早于 analyze 会被覆盖；build 阶段 pub get 会再写脏）；上游修复后可删脚本中该段 (Ref: self-update)

## 待归并（android-ops）

- [android-ops] 真机自驱输入 URL：ime set 到 Gboard(LatinIME) 后 input text 仍被中文候选转换（HTTP：／／全角化复现）——Gboard 单实例承载多语言，ime set 只切 IME 不切键盘语言 ➔ 英文/URL 类自驱输入不可靠 ➔ 真机联调遇文本输入面直接交人工手输，AI 侧只做 tap/screencap/坐标换算（截图尺寸=物理分辨率，显示缩放图必错位） (Ref: m4)

## 待归并（misc）

- [docs/终态纪律] AI 生成文档混入过程数据——goodhub-docs 域表曾硬编码文档数（3/4/14）、迁入时间线备注（「ui-design 于 2026-10-17 自 product 迁入」）、「暂无 + 解释正常流程」伪例外段，lessons.md 自身也有整段重复的待归并块 | 根因：AI 写文档倾向自证过程（何时新增/原来没有/为什么不冲突），未区分「现行事实」与「关于事实的历史」 | 处置：终态文档只写现行事实，过程/时间线/变更叙事一律归 devlog；docs-spec §7 反模式立法 + goodhub-docs 域表重写落地 | 回归：docs-lint 属机械校验抓不住语义级过程数据，依赖评审抽查 (Ref: misc)

- [release-r2.sh] flutter analyze 含 issue 即 exit 1（存量 info 也算）➔ release-r2.sh set -e 被 1 条 deprecated info 中止构建 ➔ 发布脚本 analyze 降为告警不阻断，交付门槛由日常 analyze/test 把守 (Ref: self-update) (Ref: self-update)
- [dart/closure] 闭包在 late final 局部变量声明前引用它编译报错「can't be referenced before it is declared」➔ Dart 禁止 late 局部变量在声明位置之前的闭包中引用（闭包可能早于初始化被调用）➔ 含 late final 局部变量且闭包需引用它时，把声明前置到闭包定义之前（即使赋值在后）(Ref: chatmessage)
- [hybrid_cloud_engine] 流内事件间隙超时(interEventGapTimeout)永不触发，整流误判 healthy ➔ 事件处理器内重装计时器的三元 isFirst ? firstTokenTimeout : interEventGapTimeout 在首个事件到达时(isFirst=true)重装了 firstTokenTimeout——「本事件之前」的预算被错装到「本事件之后」的间隙上 ➔ 双阈值计时器：初始计时与事件后续计时是两个装配点，事件处理器里重装的预算必须是「本事件之后」的预算；代码与自身注释矛盾时先怀疑代码，注释即意图 (Ref: chatmessage)
- [flutter/widget-test] ListView 六段重排后 3 个用例「元素不见了」 ➔ 重排让目标落到懒构建视口外，且单向 `dragUntilVisible(Offset(0,-60))` 在目标位于**上方**时永远找不到（只向下滚）并超时 10min ➔ 断言前先 `finder.evaluate()` 判是否已构建：已构建走 `ensureVisible`，未构建先 `drag` 回列表顶部再向下逐屏找；面板顺序是测试隐性依赖，重排必同步修测试滚动 (Ref: page-revamp)
- [flutter/widget-test] `TrustedPlugins` 是进程内单例（缓存 SharedPreferences 句柄）➔ `setMockInitialValues` 重置 mock 但单例仍持旧句柄，上一用例写入的白名单残留到下一用例（单跑绿、全套红）➔ 单例型 store 的用例要么显式幂等清理（用例开头把状态复位），要么换用互不冲突的键；判据「单跑过/全套挂」先怀疑跨用例单例残留 (Ref: page-revamp)
- [架构/信任闸门] 本地插件「撤销信任」一度被认为要断开连接池 ➔ 实际 `isTrusted` 只在**装配期**校验两处（chat_page 本机弹卡 / gateway_controller 网关跳过），不是长连接状态 ➔ 撤销=移出白名单即为完整语义，无需动 ConnectionManager；先查消费点再定语义，别按直觉估工作量 (Ref: page-revamp)
- [flutter/widget-test] MethodChannel 无 mock handler 时 invokeMethod 的 Future 挂起永不完成（不抛 MissingPluginException）➔ 测试二进制信使对未注册通道静默丢弃不回包，异常路径只有显式 mock 抛错时才走 ➔ 依赖平台通道的 initState 异步链（如本地插件发现 scan）在 widget 测试必须 setMockMethodCallHandler 回 null；判据：debugPrint 逐段插桩看断在哪一个 await (Ref: ux-hardening)
- [dart/结构性编辑] 大块结构增量 replace 编辑可静默损坏文件（重复 Text(、括号错位），直到 flutter analyze/dart format 才暴露，且报错行号离肇事编辑很远 ➔ 根因未实证（疑半应用状态落盘；本会话两处：memory_board _opsTab、settings BYOK 头部，均靠 analyze 咬住）➔ 多行结构编辑后立即跑 dart format（解析通过=最快结构探针）+ analyze；大块重写优先整段替换（splice/write），勿依赖连续小 replace 拼结构 (Ref: ux-hardening)
