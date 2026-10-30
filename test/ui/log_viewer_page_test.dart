import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/core/app_log.dart';
import 'package:goodhub/ui/log_viewer_page.dart';

void main() {
  setUp(() {
    AppLog.resetForTest();
  });

  testWidgets('日志页渲染缓冲条目，过滤后计数联动', (tester) async {
    AppLog.instance.i('[mcp-conn] subscribed ok');
    AppLog.instance.w('[DEGRADE] memory-sweep failed: x');

    await tester.pumpWidget(const MaterialApp(home: LogViewerPage()));

    // 标题计数 2/2，两条均渲染。
    expect(find.text('运行日志 (2/2)'), findsOneWidget);
    expect(find.textContaining('subscribed ok'), findsOneWidget);
    expect(find.textContaining('[DEGRADE] memory-sweep'), findsOneWidget);

    // 过滤命中一条。
    await tester.enterText(find.byKey(const Key('log-filter')), 'mcp-conn');
    await tester.pump();
    expect(find.text('运行日志 (1/2)'), findsOneWidget);
    expect(find.textContaining('subscribed ok'), findsOneWidget);
    expect(find.textContaining('[DEGRADE] memory-sweep'), findsNothing);
  });

  testWidgets('清空按钮清空缓冲并显示空态', (tester) async {
    AppLog.instance.i('only-one');

    await tester.pumpWidget(const MaterialApp(home: LogViewerPage()));
    await tester.tap(find.byKey(const Key('log-clear')));
    await tester.pump();

    expect(AppLog.instance.length, 0);
    expect(find.text('运行日志 (0/0)'), findsOneWidget);
    expect(find.textContaining('暂无日志'), findsOneWidget);
  });

  testWidgets('新增日志自动跟随滚底（revision 监听）', (tester) async {
    AppLog.instance.i('first');
    await tester.pumpWidget(const MaterialApp(home: LogViewerPage()));
    await tester.pump();

    for (var i = 0; i < 40; i++) {
      AppLog.instance.i('filler-line-$i');
    }
    await tester.pumpAndSettle();

    // 跟随态下最后一条可见。
    expect(find.textContaining('filler-line-39'), findsOneWidget);
  });
}
