/// 本地插件面板 widget 测试（services_hall_page 本地插件段，2026-10-15 新增）：
/// Binder 发现项渲染（标题/包名/transportId/已挂载）+ 信任态 pill（同签名私有生态
/// 自动信任 / 第三方待信任按钮）+ 信任卡片确认后转「已信任」+ 包变更流热刷新。
/// 纪律：store 读写走真实异步，全部经 [WidgetTester.runAsync] 让路（settleIo 轮询）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/cow_sync.dart';
import 'package:goodhub/core/security/secure_key_value.dart';
import 'package:goodhub/llm/cloud/byok_store.dart';
import 'package:goodhub/mcp/local_plugin_discovery.dart';
import 'package:goodhub/mcp/server_endpoints.dart';
import 'package:goodhub/ui/services_hall_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory tmp;
  late File file;
  late InMemorySecureKeyValue secure;
  late ServerEndpointStore store;

  final sameSig = LocalPluginInfo(
    serverId: 'priv',
    serverTitle: '私有插件',
    packageName: 'com.zzh.goodhub.priv',
    serviceClassName: 'com.zzh.goodhub.priv.PrivService',
    signatureSha256: 'deadbeef',
    sameSignature: true,
  );
  final thirdParty = LocalPluginInfo(
    serverId: 'ext',
    serverTitle: '外部插件',
    packageName: 'com.example.ext',
    serviceClassName: 'com.example.ext.ExtService',
    signatureSha256: 'cafe',
    sameSignature: false,
  );

  late List<LocalPluginInfo> discovered;
  late StreamController<void> changesCtrl;
  var scanCalls = 0;

  Future<List<LocalPluginInfo>> fakeScan() async {
    scanCalls++;
    return discovered;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('local_plugins_panel_test');
    file = File('${tmp.path}/mcp_servers.json');
    secure = InMemorySecureKeyValue();
    store = ServerEndpointStore(file: file, secure: secure);
    discovered = [sameSig, thirdParty];
    changesCtrl = StreamController<void>.broadcast();
    scanCalls = 0;
  });

  tearDown(() async {
    await changesCtrl.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
  }

  Future<void> pumpPanel(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ServicesHallPage(
        // 其余面板同注入假件：其默认装配走平台通道，测试环境不可达，失败会置
        // _error 短路整个 ListView（面板级短路），本地插件卡无从渲染。
        autoProbe: false, // 远端探活断言走显式点击，自动探活会翻倍计数
        storeOverride: CowOverridesStore(dir: tmp),
        byokStoreOverride: ByokStore(secure: secure),
        endpointStoreOverride: store,
        localScanOverride: fakeScan,
        localChangesOverride: changesCtrl.stream,
      ),
    ));
    await settleIo(tester);
  }

  testWidgets('渲染本地插件卡：标题/包名/transportId/已挂载', (tester) async {
    await pumpPanel(tester);

    expect(
      find.byKey(const Key('local-plugin-local:com.zzh.goodhub.priv_priv')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('local-plugin-local:com.example.ext_ext')),
      findsOneWidget,
    );
    expect(find.text('私有插件'), findsOneWidget);
    expect(find.textContaining('com.zzh.goodhub.priv'), findsOneWidget);
    expect(
      find.textContaining('local:com.zzh.goodhub.priv_priv'),
      findsOneWidget,
    );
    expect(find.text('已挂载（自动）'), findsNWidgets(2));
  });

  testWidgets('同签名插件显「私有生态 · 自动信任」，第三方显「待信任」+按钮',
      (tester) async {
    await pumpPanel(tester);

    expect(find.text('私有生态 · 自动信任'), findsOneWidget);
    expect(find.text('待信任'), findsOneWidget);
    expect(
      find.byKey(const Key('local-trust-local:com.example.ext_ext')),
      findsOneWidget,
    );
    // 仅第三方有「信任」按钮（同签名免确认，无按钮）。
    expect(find.text('信任'), findsOneWidget);
  });

  testWidgets('信任第三方插件：弹卡确认后转「已信任」', (tester) async {
    await pumpPanel(tester);
    expect(find.text('待信任'), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('local-trust-local:com.example.ext_ext')),
    );
    await settleIo(tester);
    // 信任卡片弹窗。
    expect(find.text('信任本地插件？'), findsOneWidget);
    await tester.tap(find.text('信任并挂载'));
    await settleIo(tester);

    expect(find.text('已信任'), findsOneWidget);
    expect(find.text('待信任'), findsNothing);
  });

  testWidgets('包变更流触发重扫热刷新', (tester) async {
    await pumpPanel(tester);
    expect(scanCalls, 1, reason: '初始拉扫一次');

    discovered = [sameSig]; // 卸载了第三方
    changesCtrl.add(null);
    await settleIo(tester);

    expect(scanCalls, greaterThan(1), reason: '包变更触发重扫');
    expect(
      find.byKey(const Key('local-plugin-local:com.example.ext_ext')),
      findsNothing,
      reason: '第三方已卸载不再出现',
    );
  });
}
