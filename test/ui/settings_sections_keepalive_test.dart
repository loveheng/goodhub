/// window-slim P1-A 分段拆解的**语义守恒**回归：段迁出页面后必须申请 keepAlive。
///
/// 背景（本次拆分真实踩到的坑）：ListView(`children:`) 经 SliverChildListDelegate
/// 构建，滚出视口且超出 cacheExtent 的 child 会被**销毁重建**；拆分前领域态住在
/// 页面层（天然跨滚动存活），迁到段里就退化成「滚一下，编辑一半的表单没了 /
/// 面板错误态消失」（settings_page_test 的错误隔离用例首当其冲变红）。故六个
/// 有状态段一律混入 AutomaticKeepAliveClientMixin。
///
/// 口径说明：Flutter 对「何时真的销毁 child」受 cacheExtent/布局时序影响，用
/// 滚动手势复现不稳定；本用例改为**直接闸住不变式本身**——段 State 必须自行申请
/// keepAlive（白盒但确定），行为侧另有 `settings_page_test` 的错误隔离用例兜底。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/cow_sync.dart';
import 'package:goodhub/core/security/secure_key_value.dart';
import 'package:goodhub/llm/cloud/byok_store.dart';
import 'package:goodhub/mcp/local_plugin_discovery.dart';
import 'package:goodhub/mcp/server_endpoints.dart';
import 'package:goodhub/ui/sections/about_section.dart';
import 'package:goodhub/ui/sections/byok_section.dart';
import 'package:goodhub/ui/sections/cow_section.dart';
import 'package:goodhub/ui/sections/gateway_section.dart';
import 'package:goodhub/ui/sections/local_plugins_section.dart';
import 'package:goodhub/ui/sections/nodes_section.dart';
import 'package:goodhub/ui/tokens/console_tokens.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sections_keepalive');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  /// 最小错误行件（页面级口径的替代件，本用例只关心 keepAlive，不关心文案）。
  Widget errorRow(
    ConsoleTokens t,
    String message,
    VoidCallback onRetry, {
    ValueKey<String>? key,
  }) => Padding(key: key, padding: EdgeInsets.zero, child: Text('⚠ $message'));

  /// 段 State 是否申请了 keepAlive（混入了 AutomaticKeepAliveClientMixin 且
  /// wantKeepAlive 为真）；否则滚动会把段内领域态连带销毁。
  bool requestsKeepAlive(WidgetTester tester, Type widgetType) {
    final state = tester.state<State>(find.byType(widgetType));
    return (state as dynamic).wantKeepAlive as bool;
  }

  testWidgets('六个有状态段全部申请 keepAlive（滚动不丢领域态）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SingleChildScrollView(
          child: Column(
            children: [
              ByokSection(
                store: ByokStore(secure: InMemorySecureKeyValue()),
                onFlash: (_) {},
                errorRowBuilder: errorRow,
              ),
              NodesSection(
                autoProbe: false,
                endpointStoreOverride: ServerEndpointStore(
                  file: File('${tempDir.path}/mcp_servers.json'),
                  secure: InMemorySecureKeyValue(),
                ),
                isDefaultPrivate: (_) => false,
                onPinToggle: (id, label, isDefault) async {},
                onFlash: (_) {},
                errorRowBuilder: errorRow,
              ),
              LocalPluginsSection(
                scan: () async => const <LocalPluginInfo>[],
                changes: const Stream<void>.empty(),
                isDefaultPrivate: (_) => false,
                onPinToggle: (id, label, isDefault) async {},
                onFlash: (_) {},
                errorRowBuilder: errorRow,
              ),
              GatewaySection(onFlash: (_) {}),
              CowSection(
                storeOverride: CowOverridesStore(dir: tempDir),
                onFlash: (_) {},
                errorRowBuilder: errorRow,
              ),
              const AboutSection(),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    for (final type in const <Type>[
      ByokSection,
      NodesSection,
      LocalPluginsSection,
      GatewaySection,
      CowSection,
      AboutSection,
    ]) {
      expect(
        requestsKeepAlive(tester, type),
        isTrue,
        reason: '$type 未申请 keepAlive：滚动出视口会重建段 State（表单/错误态/探活结果丢失）',
      );
    }
  });
}
