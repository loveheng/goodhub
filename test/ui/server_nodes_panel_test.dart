/// M4-T5 Server 节点卡面板 widget 测试（settings_page 节点卡段）：
/// 节点渲染（端口/延迟/工具计数/鉴权态等宽遥测轨）+ 探测全联动 + 挂载开关
/// 落盘（enabled=false → _send 装配过滤，见 chat_page 侧约定）。
/// 纪律：同 byok_panel_test——store 读写走真实异步，全部经
/// [WidgetTester.runAsync] 让路（settleIo 轮询），长列表目标先 ensureVisible。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/cow_sync.dart';
import 'package:goodhub/core/security/secure_key_value.dart';
import 'package:goodhub/llm/cloud/byok_store.dart';
import 'package:goodhub/mcp/server_endpoints.dart';
import 'package:goodhub/mcp/server_probe.dart';
import 'package:goodhub/ui/settings_page.dart';

void main() {
  late Directory tmp;
  late File file;
  late InMemorySecureKeyValue secure;
  late ServerEndpointStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nodes_panel_test');
    file = File('${tmp.path}/mcp_servers.json');
    secure = InMemorySecureKeyValue();
    store = ServerEndpointStore(file: file, secure: secure);
    await store.save(const [
      ServerEndpoint(
        id: 'srv_a',
        name: 'goodshare',
        endpoint: 'http://10.0.2.2:8765/mcp',
        hasKey: true,
      ),
      ServerEndpoint(
        id: 'srv_b',
        name: 'shuguang',
        endpoint: 'http://10.0.2.2:9000/mcp',
      ),
    ]);
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
  }

  Future<void> pumpPanel(WidgetTester tester, {NodeProbeFn? probe}) async {
    await tester.pumpWidget(MaterialApp(
      home: SettingsPage(
        // CoW/BYOK 面板同注入假件：其默认装配走平台通道，测试环境不可达，
        // 失败置 _error 会替换整个 ListView（面板级短路），节点卡无从渲染。
        autoProbe: false, // 探活断言均走显式「探测全部」点击，自动探活会翻倍计数
        storeOverride: CowOverridesStore(dir: tmp),
        byokStoreOverride: ByokStore(secure: secure),
        endpointStoreOverride: store,
        probeOverride: probe,
      ),
    ));
    await settleIo(tester);
  }

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
  }

  NodeProbeFn probeAlways(NodeProbeResult r) =>
      (endpoint, {String? apiKey}) async => r;

  testWidgets('渲染节点卡：端点名/endpoint/端口/未探测态/挂载开关默认开',
      (tester) async {
    await pumpPanel(tester);

    expect(find.byKey(const Key('node-item-srv_a')), findsOneWidget);
    expect(find.byKey(const Key('node-item-srv_b')), findsOneWidget);
    expect(find.text('goodshare'), findsOneWidget);
    expect(find.textContaining('http://10.0.2.2:8765/mcp'), findsOneWidget);
    expect(find.textContaining('端口 8765'), findsOneWidget);
    expect(find.textContaining('端口 9000'), findsOneWidget);
    // 未探测：指标占位 + 存况展示（srv_a 有令牌 / srv_b 无令牌）。
    expect(find.textContaining('延迟 — · 工具 —'), findsNWidgets(2));
    expect(find.textContaining('未探测 · 已存令牌'), findsOneWidget);
    expect(find.textContaining('未探测 · 无令牌'), findsOneWidget);
    final swA =
        tester.widget<Switch>(find.byKey(const Key('node-switch-srv_a')));
    expect(swA.value, isTrue, reason: '缺省挂载');
  });

  testWidgets('探测全部：在线结果回填延迟/工具计数/已授权', (tester) async {
    final probed = <String>[];
    await pumpPanel(
      tester,
      probe: (endpoint, {String? apiKey}) async {
        probed.add('$endpoint#$apiKey');
        return const NodeProbeResult(
            online: true, latencyMs: 12, toolCount: 7);
      },
    );

    await tapVisible(tester, find.byKey(const Key('nodes-probe-all')));
    await settleIo(tester);

    expect(probed.length, 2, reason: '两个节点并行探活');
    expect(find.textContaining('延迟 12ms · 工具 7'), findsNWidgets(2));
    expect(find.textContaining('已授权'), findsNWidgets(2));
  });

  testWidgets('探活带令牌：hasKey 节点取安全存储真值作 apiKey', (tester) async {
    await store.setApiKey('srv_a', 'sk-secret');
    final keys = <String?>[];
    await pumpPanel(
      tester,
      probe: (endpoint, {String? apiKey}) async {
        keys.add(apiKey);
        return const NodeProbeResult(online: true, latencyMs: 1, toolCount: 1);
      },
    );
    await tapVisible(tester, find.byKey(const Key('nodes-probe-all')));
    await settleIo(tester);

    expect(keys.where((k) => k == null).length, 1,
        reason: 'srv_b 无令牌传 null');
    expect(keys, contains('sk-secret'), reason: 'srv_a 从安全存储取真值');
  });

  testWidgets('403 → 待授权 Rose 文案（禁与离线混淆）', (tester) async {
    await pumpPanel(
        tester,
        probe: probeAlways(const NodeProbeResult(
            online: false, authDenied: true, error: 'HTTP 403')));

    await tapVisible(tester, find.byKey(const Key('nodes-probe-all')));
    await settleIo(tester);

    expect(find.textContaining('⚠ 待授权(403)'), findsNWidgets(2));
  });

  testWidgets('离线 → 非待授权口径（错误态不冒充鉴权被拒）', (tester) async {
    await pumpPanel(
        tester,
        probe: probeAlways(
            const NodeProbeResult(online: false, error: 'connection refused')));

    await tapVisible(tester, find.byKey(const Key('nodes-probe-all')));
    await settleIo(tester);

    expect(find.textContaining('已授权'), findsNothing);
    expect(find.textContaining('待授权'), findsNothing);
  });

  testWidgets('挂载开关：卸载落盘 enabled=false（配置与令牌保留）', (tester) async {
    await pumpPanel(tester);

    await tapVisible(tester, find.byKey(const Key('node-switch-srv_a')));
    await settleIo(tester);

    List<ServerEndpoint> loaded = [];
    await tester.runAsync(() async => loaded = await store.load());
    expect(loaded.firstWhere((e) => e.id == 'srv_a').enabled, isFalse);
    expect(loaded.firstWhere((e) => e.id == 'srv_b').enabled, isTrue);
    // 卡片呈现卸载态。
    expect(find.text('已卸载'), findsOneWidget);
    expect(
        tester
            .widget<Switch>(find.byKey(const Key('node-switch-srv_a'))).value,
        isFalse);
  });

  testWidgets('重挂载：开关切回 enabled=true 恢复', (tester) async {
    // 预置一个卸载态节点（真实文件 I/O 须在 runAsync 内让路 FakeAsync）。
    await tester.runAsync(() async {
      await store.save(const [
        ServerEndpoint(
          id: 'srv_a',
          name: 'goodshare',
          endpoint: 'http://10.0.2.2:8765/mcp',
          hasKey: true,
          enabled: false,
        ),
      ]);
    });
    await pumpPanel(tester);

    expect(find.text('已卸载'), findsOneWidget);
    await tapVisible(tester, find.byKey(const Key('node-switch-srv_a')));
    await settleIo(tester);

    List<ServerEndpoint> loaded = [];
    await tester.runAsync(() async => loaded = await store.load());
    expect(loaded.single.enabled, isTrue);
    expect(find.text('已卸载'), findsNothing);
  });
}
