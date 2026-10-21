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
    bool bindLocked = false,
    bool withResourceEntries = true,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: SessionContextSheetBody(
          t: ConsoleTokens.fallback,
          bound: bound,
          bindLocked: bindLocked,
          onPickResource: withResourceEntries ? () {} : null,
          onManageResources: withResourceEntries ? () {} : null,
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

  // P1-6（2026-10-22）：一个入口装三类挂载物（session 绑定 / run 附件 / 应用级
  // 资源库），必须分组到肉眼可辨——遵循 chat-interaction §1 #11。
  testWidgets('三级生命周期分组：标题 + 期限说明各就各位', (tester) async {
    await tester.pumpWidget(harness(
      bound: null,
      onBind: (_) {},
      onClear: () {},
    ));
    expect(find.text('挂载'), findsOneWidget,
        reason: '标题不再自称「本次会话上下文」（它装的不止会话绑定）');
    expect(find.text('本次会话绑定'), findsOneWidget);
    expect(find.text('跨轮有效 · 切会话或新建会话即重置'), findsOneWidget);
    expect(find.text('本次发送附件'), findsOneWidget);
    expect(find.text('随本次发送后即清空 · 移除只注销待发项，不删资源库'),
        findsOneWidget);
    expect(find.text('资源中心'), findsOneWidget);
    expect(find.text('跨会话持久 · 仅在此显式删除才消失'), findsOneWidget);
  });

  // P1-8：运行中只锁「会话绑定」（它改写会话 slot、扰动在途装配）；资源类动作
  // 属视图态/其他面，不该跟着一起死——此前「附加资源」灰而「管理资源中心」可点，
  // 同一类入口两态，用户无法归因。
  testWidgets('运行中：绑定项置灰 + 说明点名绑定，资源入口照常可点',
      (tester) async {
    await tester.pumpWidget(harness(
      bound: null,
      onBind: (_) {},
      onClear: () {},
      bindLocked: true,
    ));
    expect(find.text('任务运行中：服务绑定暂不可切换（挂载资源不受影响）'),
        findsOneWidget);

    for (final title in ['公共', '服务A']) {
      final tile = tester.widget<ListTile>(
        find.ancestor(of: find.text(title), matching: find.byType(ListTile)),
      );
      expect(tile.enabled, isFalse, reason: '$title：会话绑定在运行中被锁');
    }
    final attach = tester.widget<ListTile>(
      find.byKey(const ValueKey('menu-attach')),
    );
    expect(attach.enabled, isTrue, reason: '挂载资源不扰动在途 Run，不应置灰');
    final manage = tester.widget<ListTile>(
      find.byKey(const ValueKey('menu-resource-center')),
    );
    expect(manage.enabled, isTrue, reason: '与附加资源同质入口，策略须一致');
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
