---
dev-loop: lessons
format: v1
epic: global
total-merged: 4
last-merge: 2026-10-11
---

# lessons

按模块归类的避坑规则正文（正文行禁用 `- [` 开头——该前缀专属底部追加区）

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
## 待归并（android-ops）

- [android-ops] 真机自驱输入 URL：ime set 到 Gboard(LatinIME) 后 input text 仍被中文候选转换（HTTP：／／全角化复现）——Gboard 单实例承载多语言，ime set 只切 IME 不切键盘语言 ➔ 英文/URL 类自驱输入不可靠 ➔ 真机联调遇文本输入面直接交人工手输，AI 侧只做 tap/screencap/坐标换算（截图尺寸=物理分辨率，显示缩放图必错位） (Ref: m4)

## 待归并（android-ops）

- [android-ops] 真机自驱输入 URL：ime set 到 Gboard(LatinIME) 后 input text 仍被中文候选转换（HTTP：／／全角化复现）——Gboard 单实例承载多语言，ime set 只切 IME 不切键盘语言 ➔ 英文/URL 类自驱输入不可靠 ➔ 真机联调遇文本输入面直接交人工手输，AI 侧只做 tap/screencap/坐标换算（截图尺寸=物理分辨率，显示缩放图必错位） (Ref: m4)

