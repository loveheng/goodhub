/// ux-hardening P1-8：信任卡片按钮权重与后果文案。
/// 安全 UI 惯例：危险/授权选项走弱化路径，安全默认上主位。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/mcp/local_plugin_discovery.dart';
import 'package:goodhub/ui/tokens/console_tokens.dart';
import 'package:goodhub/ui/trust_plugin_dialog.dart';

// 'a' * 64 非 const 可算——_info 去 const。
final _info = LocalPluginInfo(
  serverId: 'demo',
  serverTitle: '演示插件',
  packageName: 'com.zzh.demo',
  serviceClassName: 'com.zzh.demo.Service',
  signatureSha256: 'a' * 64,
  sameSignature: false,
);

void main() {
  Widget host(Widget child) => MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          extensions: const [ConsoleTokens.fallback],
        ),
        home: Scaffold(body: child),
      );

  testWidgets('权重不再反置：拒绝=主按钮（安全默认），信任并挂载=弱化路径',
      (tester) async {
    await tester.pumpWidget(host(TrustPluginDialog(
      info: _info,
      onConfirm: () {},
      onDeny: () {},
    )));

    expect(find.widgetWithText(FilledButton, '拒绝'), findsOneWidget,
        reason: '安全默认上主位（历史病：信任=高亮主按钮，诱导授权）');
    expect(find.widgetWithText(OutlinedButton, '信任并挂载'), findsOneWidget,
        reason: '授权第三方 = 弱化路径');
    expect(find.widgetWithText(TextButton, '信任并挂载'), findsNothing);
  });

  testWidgets('两个回调分别可达', (tester) async {
    var confirmed = 0;
    var denied = 0;
    await tester.pumpWidget(host(TrustPluginDialog(
      info: _info,
      onConfirm: () => confirmed++,
      onDeny: () => denied++,
    )));

    await tester.tap(find.text('信任并挂载'));
    expect(confirmed, 1);
    await tester.tap(find.text('拒绝'));
    expect(denied, 1);
  });

  testWidgets('P1-8：拒绝后果明示（不信任时会发生什么、如何改主意）', (tester) async {
    await tester.pumpWidget(host(TrustPluginDialog(
      info: _info,
      onConfirm: () {},
      onDeny: () {},
    )));
    expect(find.textContaining('拒绝 = 本次不挂载'), findsOneWidget);
    expect(find.textContaining('设置页 → 本地插件面板重新信任'), findsOneWidget);
    // P1-7 的指纹比对指引仍在。
    expect(find.textContaining('与插件发布方（官网/应用页）公布的指纹比对'),
        findsOneWidget);
  });
}
