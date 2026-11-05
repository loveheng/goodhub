/// 调试桥动作执行面回归：定位 / 点击 / 文本注入 / 导航 / 结构化错误。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/ui/debug_actions.dart';
import 'package:goodhub/ui/debug_routes.dart';
import 'package:goodhub/ui/log_viewer_page.dart';

Future<void> _pump(WidgetTester tester, Widget body) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: body)));
  debugActionContextOverride = tester.element(find.byType(Scaffold));
}

void main() {
  tearDown(() {
    debugActionContextOverride = null;
    debugActionNavigatorOverride = null;
  });

  testWidgets('tap_node 按 text 命中并触发祖先回调', (tester) async {
    var taps = 0;
    await _pump(
      tester,
      GestureDetector(
        onTap: () => taps++,
        child: const Text('点我'),
      ),
    );
    final r = await executeDebugAction('tap_node', <String, Object?>{
      'text': '点我',
    }) as Map;
    expect(r['ok'], isTrue);
    expect(r['via'], 'callback');
    expect(taps, 1);
  });

  testWidgets('tap_node 按 key 命中按钮', (tester) async {
    var taps = 0;
    await _pump(
      tester,
      ElevatedButton(
        key: const ValueKey('send'),
        onPressed: () => taps++,
        child: const Text('提交'),
      ),
    );
    final r = await executeDebugAction('tap_node', <String, Object?>{
      'key': 'send',
    }) as Map;
    expect(r['ok'], isTrue);
    expect(taps, 1);
  });

  testWidgets('未命中回结构化错误与候选节点', (tester) async {
    await _pump(tester, const Text('唯一节点'));
    final r = await executeDebugAction('tap_node', <String, Object?>{
      'key': 'missing',
    }) as Map;
    expect(r['ok'], isFalse);
    expect(r['error'], 'node_not_found');
    expect(r['candidates'] as List, isNotEmpty);
  });

  testWidgets('set_text 经 EditableText.controller 注入，绕过 IME', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await _pump(
      tester,
      TextField(key: const ValueKey('input'), controller: controller),
    );
    final r = await executeDebugAction('set_text', <String, Object?>{
      'key': 'input',
      'value': 'http://127.0.0.1:8765/mcp',
    }) as Map;
    expect(r['ok'], isTrue);
    expect(controller.text, 'http://127.0.0.1:8765/mcp');
  });

  testWidgets('set_text 按 type 定位 EditableText（无 Key 的输入框）',
      (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await _pump(tester, TextField(controller: controller));
    final r = await executeDebugAction('set_text', <String, Object?>{
      'type': 'EditableText',
      'value': 'no-ime',
    }) as Map;
    expect(r['ok'], isTrue);
    expect(controller.text, 'no-ime');
  });

  testWidgets('navigate 走白名单路由直达目标页', (tester) async {
    await tester.pumpWidget(MaterialApp(
      onGenerateRoute: resolveDebugRoute,
      home: const Scaffold(body: Text('home')),
    ));
    debugActionContextOverride = tester.element(find.byType(Scaffold));
    debugActionNavigatorOverride = tester.state(find.byType(Navigator));
    bindDebugRoutes(debugRouteRegistry);
    final r = await executeDebugAction('navigate', <String, Object?>{
      'page': 'logs',
    }) as Map;
    expect(r['ok'], isTrue);
    expect(r['route'], '/debug/logs');
    await tester.pumpAndSettle();
    expect(find.byType(LogViewerPage), findsOneWidget);
  });

  test('未知动作 / 未知页 / ping 的结构化返回', () async {
    bindDebugRoutes(debugRouteRegistry);
    final unknown = await executeDebugAction('nope', <String, Object?>{}) as Map;
    expect(unknown['error'], 'unknown_action');
    expect(unknown['available'], kDebugActions);

    final badPage = await executeDebugAction('navigate', <String, Object?>{
      'page': 'nope',
    }) as Map;
    expect(badPage['error'], 'unknown_page');
    expect((badPage['available'] as List), contains('logs'));

    final ping = await executeDebugAction('ping', <String, Object?>{}) as Map;
    expect(ping['ok'], isTrue);
    expect(ping['contextReady'], isFalse);
  });
}
