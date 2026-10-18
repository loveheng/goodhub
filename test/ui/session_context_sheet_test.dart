/// 「本次会话上下文」弹层单选语义锚（2026-10-18 用户拍板）：
/// 公共常驻首项、恒有一项选中；选中服务再点 = 回公共（onClear）；
/// 底部「清空」行移除。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/mcp/server_endpoints.dart';
import 'package:goodhub/ui/components/session_context_sheet.dart';
import 'package:goodhub/ui/tokens/console_tokens.dart';

void main() {
  Widget harness({
    String? bound,
    required ValueChanged<String> onBind,
    required VoidCallback onClear,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: SessionContextSheetBody(
          t: ConsoleTokens.fallback,
          bound: bound,
          privEndpoints: const [
            ServerEndpoint(
              id: 'srv_a',
              name: '服务A',
              endpoint: 'http://a:8765/mcp',
              tier: ServerPrivacyTier.private,
            ),
            ServerEndpoint(
              id: 'srv_b',
              name: '服务B',
              endpoint: 'http://b:8765/mcp',
              tier: ServerPrivacyTier.private,
            ),
          ],
          localPlugins: const [],
          defaultId: null,
          endpointName: (id) => id,
          onBind: onBind,
          onClear: onClear,
          onDone: () {},
        ),
      ),
    );
  }

  bool publicChecked(WidgetTester tester) =>
      tester.widgetList(find.widgetWithText(ListTile, '公共')).isNotEmpty &&
      tester
          .widget<ListTile>(
            find.ancestor(
              of: find.text('公共'),
              matching: find.byType(ListTile),
            ),
          )
          .trailing !=
          null;

  testWidgets('公共常驻首项：未绑定（null）与显式公共（\'\'）均显示选中态',
      (tester) async {
    await tester.pumpWidget(harness(
      bound: null,
      onBind: (_) {},
      onClear: () {},
    ));
    expect(find.text('公共'), findsOneWidget);
    expect(publicChecked(tester), isTrue, reason: '恒有一项选中（null 按公共显示）');

    await tester.pumpWidget(harness(
      bound: '',
      onBind: (_) {},
      onClear: () {},
    ));
    expect(publicChecked(tester), isTrue);

    // 底部「清空（纯公共）」行已移除。
    expect(find.text('清空（纯公共）'), findsNothing);
  });

  testWidgets('点服务 → onBind；选中服务再点 → onClear（回显式取消）',
      (tester) async {
    String? boundTo;
    var cleared = 0;
    await tester.pumpWidget(harness(
      bound: null,
      onBind: (id) => boundTo = id,
      onClear: () => cleared++,
    ));

    await tester.tap(find.text('服务A'));
    expect(boundTo, 'srv_a');
    expect(cleared, 0);

    // 切到已选中态：再点服务A = 取消（onClear），不重复 onBind。
    await tester.pumpWidget(harness(
      bound: 'srv_a',
      onBind: (id) => boundTo = id,
      onClear: () => cleared++,
    ));
    await tester.tap(find.text('服务A'));
    expect(cleared, 1);

    // 点公共行 → onBind('')。
    await tester.pumpWidget(harness(
      bound: 'srv_a',
      onBind: (id) => boundTo = id,
      onClear: () => cleared++,
    ));
    await tester.tap(find.text('公共'));
    expect(boundTo, '');
  });

  testWidgets('公共已选中时不可再点（radio 语义：不可取消）', (tester) async {
    var boundTo = 'x';
    await tester.pumpWidget(harness(
      bound: '',
      onBind: (id) => boundTo = id,
      onClear: () {},
    ));
    final tile = tester.widget<ListTile>(
      find.ancestor(of: find.text('公共'), matching: find.byType(ListTile)),
    );
    expect(tile.onTap, isNull, reason: '已选中的公共项 onTap 置空');
    expect(boundTo, 'x'); // 未被改动
  });
}
