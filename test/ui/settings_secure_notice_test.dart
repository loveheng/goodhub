/// 设置页 · 安全存储升级提示行 widget 测试（2026-10-24 事故回归钉子）：
/// health 注入位判定提示行显示/隐藏；生产路径在无通道测试环境按正常降级
/// （检查失败不出提示、不拖垮页面）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/cow_sync.dart';
import 'package:goodhub/core/security/secure_storage_upgrade.dart';
import 'package:goodhub/ui/settings_page.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('secure_notice_test');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
  }

  Future<void> pumpPage(WidgetTester tester, SecureStorageHealth? health) async {
    await tester.pumpWidget(MaterialApp(
      home: SettingsPage(
        // CoW 注入假件免平台通道依赖（BYOK/节点段已迁资源中心四 tab——
        // 2026-11-02 能力中心拍板，设置页不再装配，注入面随之收缩）。
        storeOverride: CowOverridesStore(dir: tmp),
        secureHealthOverride:
            health == null ? null : () async => health,
      ),
    ));
    await settleIo(tester);
  }

  testWidgets('legacyDataLost → 列表顶部提示行（重试钮重跑检查）', (tester) async {
    await pumpPage(tester, SecureStorageHealth.legacyDataLost);

    expect(find.byKey(const Key('secure-storage-notice')), findsOneWidget);
    expect(find.textContaining('MCP 服务令牌与云端模型密钥需重新录入'),
        findsOneWidget);
  });

  testWidgets('ok → 无提示行', (tester) async {
    await pumpPage(tester, SecureStorageHealth.ok);

    expect(find.byKey(const Key('secure-storage-notice')), findsNothing);
  });

  testWidgets('生产路径（无注入）：无通道环境检查失败按正常降级，不出提示',
      (tester) async {
    await pumpPage(tester, null);

    expect(find.byKey(const Key('secure-storage-notice')), findsNothing);
  });
}
