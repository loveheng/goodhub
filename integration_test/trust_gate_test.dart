// 信任闸门 integration_test（thirdconnect §1.2.6，手动验收项①自动化）：
//
//   ① 第三方（非同签名）插件首次接入 → 弹信任卡片（包名 + 签名 SHA-256）
//   ② 点「信任并挂载」→ showTrustCard 返回 true + 包名持久化入白名单（真实 SharedPreferences）
//   ③ 点「拒绝」→ 返回 false + 不入白名单
//
// 运行（真机）：
//   flutter test integration_test/trust_gate_test.dart -d <device>
//
// 说明：FSI/L2AlertActivity（手动验收项②）是独立原生 Activity 且需 PC 触发网关
// L2 请求，Flutter integration_test 无法干净覆盖，仍走手动真机；电池白名单（③）
// 属系统设置项，同理手动。本测试覆盖可自动化的信任闸门 UI 流全路径。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:goodhub/mcp/local_plugin_discovery.dart';
import 'package:goodhub/mcp/trusted_plugins.dart';
import 'package:goodhub/ui/trust_plugin_dialog.dart';

/// 合成「第三方」插件（sameSignature=false，真实设备上无此包——卡片是纯 UI，
/// 不依赖 PackageManager 真实发现，故可脱离靶子 APK 驱动）。
const _thirdParty = LocalPluginInfo(
  serverId: 'trustgate-third',
  serverTitle: '第三方联调插件',
  packageName: 'com.example.thirdparty.trustgate',
  serviceClassName: 'com.example.ThirdPartyService',
  signatureSha256:
      'AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99',
  sameSignature: false,
);

/// 拒绝路径用的第二个未信任包。
const _thirdParty2 = LocalPluginInfo(
  serverId: 'trustgate-third2',
  serverTitle: '第三方联调插件2',
  packageName: 'com.example.thirdparty.trustgate2',
  serviceClassName: 'com.example.ThirdPartyService2',
  signatureSha256: 'BB:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99',
  sameSignature: false,
);

Future<void> _pumpHarness(WidgetTester tester, LocalPluginInfo info,
    Completer<bool> done) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: FilledButton(
            onPressed: () async {
              final r = await showTrustCard(context, info);
              if (!done.isCompleted) done.complete(r);
            },
            child: const Text('open-trust-card'),
          ),
        ),
      ),
    ),
  ));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('信任闸门：卡片展示 → 信任并挂载 → 白名单持久化；拒绝 → 不入白名单',
      (tester) async {
    final trusted = await TrustedPlugins.instance;
    // 前置清理：确保两个测试包名都不在白名单（真机 SharedPreferences 真实读写）。
    await trusted.remove(_thirdParty.packageName);
    await trusted.remove(_thirdParty2.packageName);
    expect(trusted.isTrusted(_thirdParty.packageName), isFalse);
    expect(trusted.isTrusted(_thirdParty2.packageName), isFalse);

    // ---- ① 首次接入（未信任）：弹信任卡片，展示包名 + SHA-256 + 双按钮 ----
    final done1 = Completer<bool>();
    await _pumpHarness(tester, _thirdParty, done1);
    await tester.tap(find.text('open-trust-card'));
    await tester.pumpAndSettle();

    expect(find.text('信任本地插件？'), findsOneWidget,
        reason: '第三方未信任插件应弹信任卡片');
    expect(find.textContaining(_thirdParty.packageName), findsOneWidget,
        reason: '卡片应展示插件包名');
    expect(find.textContaining('AA:BB:CC:DD'), findsOneWidget,
        reason: '卡片应展示签名 SHA-256 指纹');
    expect(find.text('信任并挂载'), findsOneWidget);
    expect(find.text('拒绝'), findsOneWidget);

    // ---- ② 信任并挂载：返回 true + 包名持久化入白名单（含 sha256/title 元数据）----
    await tester.tap(find.text('信任并挂载'));
    await tester.pumpAndSettle();
    final r1 = await done1.future.timeout(const Duration(seconds: 10),
        onTimeout: () => throw TimeoutException('信任确认回调未完成'));
    expect(r1, isTrue, reason: '点「信任并挂载」showTrustCard 应返回 true');
    expect(trusted.isTrusted(_thirdParty.packageName), isTrue,
        reason: '确认后包名应持久化入白名单（闸门下次不再弹卡）');
    final meta =
        trusted.all()[_thirdParty.packageName] as Map<String, Object?>?;
    expect(meta, isNotNull);
    expect(meta!['sha256'], _thirdParty.signatureSha256);
    expect(meta['title'], _thirdParty.serverTitle);

    // ---- ③ 拒绝路径：另一未信任包，点「拒绝」→ false + 不入白名单 ----
    final done2 = Completer<bool>();
    await _pumpHarness(tester, _thirdParty2, done2);
    await tester.pumpAndSettle(); // 卸下上一轮卡片后的 harness 重建
    await tester.tap(find.text('open-trust-card'));
    await tester.pumpAndSettle();
    expect(find.text('信任本地插件？'), findsOneWidget);

    await tester.tap(find.text('拒绝'));
    await tester.pumpAndSettle();
    final r2 = await done2.future.timeout(const Duration(seconds: 10),
        onTimeout: () => throw TimeoutException('拒绝回调未完成'));
    expect(r2, isFalse, reason: '点「拒绝」showTrustCard 应返回 false');
    expect(trusted.isTrusted(_thirdParty2.packageName), isFalse,
        reason: '拒绝后不应入白名单');

    // 收尾清理：不留测试白名单残留。
    await trusted.remove(_thirdParty.packageName);
    await trusted.remove(_thirdParty2.packageName);
  });
}
