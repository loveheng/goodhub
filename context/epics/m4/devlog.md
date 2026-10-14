---
dev-loop: devlog
format: v1
epic: m4
total-merged: 2
last-merge: 2026-10-14
---

（开发过程日志按行追加：[变更]/[验证]/[note]/[SSOT 修正]；≥5 条自动归并进 memory.md——dev-loop §2）

- [变更] CoW 撞名补用户面通告（2026-10-14，用户拍板补）：`chat_page.dart` CoW 注册循环把静默 `byName!=null→continue` 改为发 `TrackNote('⚠ CoW 模板「X」重名：已采用 <serverId> 版本，跳过 <serverId> 的同名模板')`（danger:false，先到先得）。补齐 design「撞名跳过 + 通告」的通告侧。analyze 0 新增（存量 1 info deprecated 行号 635→667 因文件增长）。注：通告嵌在 ChatPage._send，无独立单测；真机可见性随设备端 UI 冒烟
- [变更] Markdown parser 抽共享包（2026-10-14，D12 抽包点，solution-admission 结构化引入）：新建同级纯 Dart 仓 `/home/zzh/app/rich_text/`（pubspec sdk ^3.13.4 + flutter_lints + test；`lib/rich_text.dart` 1422 行原样搬迁、头注中性化为共享 provenance；test 4 例转 `package:test`）。goodhub 删内联 `lib/doc/rich_text.dart` + `test/doc/rich_text_test.dart`（`doc/` 目录清空移除）；`rich_text_view.dart` import 改 `package:rich_text/rich_text.dart`；pubspec 加 `rich_text: { path: ../rich_text }`。验证：rich_text `dart analyze` 0 / `dart test` 4 绿；goodhub `flutter pub get` 解析 path 依赖 / analyze 0 新增 / 全量 **409 绿**（413−4，parser 测试随包搬迁）。渲染器按 D12 各自留（不进包）。goodshare adopt + 上 git 宿主待协同
- [变更] rich_text 包 DIP 拆分 + 渲染器改吃 AST（2026-10-14，用户拍板完整 DIP）：包内拆两 library——`rich_text.dart`（**抽象**：AST 模型 + `RichTextParser` 接口 + 纯 AST 运算 serialize*/inlineToPlain/blockToPlain/classifyMediaUrl/编辑原语）+ `markdown_subset.dart`（**实现**：`MarkdownSubsetParser` + 语法责任链 + 依赖 parser 的 helper normalizeAiMarkdown/markdownToPlain/inlineSpansOf/scanTodoTexts/lostMediaUrls，`import`+`export` 抽象库）。goodhub 渲染器 `rich_text_view.dart` 改吃 `List<RichBlock>`（去内部 parse、只 import 抽象库），parse 移到调用点 `dual_track_stream.dart`（import 实现库）→ 渲染器只依赖抽象。验证：rich_text `dart analyze` 0 / `dart test` 4 绿；goodhub `flutter analyze` 0 新增 / 全量 **409 绿**
