/// P0-B 网关层装配-释放契约（2026-10-17 债 #14）：此前 `GatewayController`
/// 的四个装配依赖全是顶层全局直引用且无注入位，重扫释放与起服失败回滚两条
/// 关键路径**无从单测**，只能真机验收。本文件经注入位把它拉进单测：
///
/// 1. 重扫（包变更广播触发）必须先释放上一批传输——修复前每次广播泄漏一批；
/// 2. 起服失败（绑端口失败）必须回滚全部已挂载句柄，零残留。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/app/service_directory.dart';
import 'package:goodhub/core/security/secure_key_value.dart';
import 'package:goodhub/gateway/gateway_controller.dart';
import 'package:goodhub/mcp/local_plugin_discovery.dart';
import 'package:goodhub/mcp/mcp_client.dart';
import 'package:goodhub/mcp/server_endpoints.dart';
import 'package:goodhub/mcp/trusted_plugins.dart';
import 'package:goodhub/mcp/transport/mcp_transport.dart';
import 'package:path_provider/path_provider.dart';

/// 计数假传输：协议面最小实现，close 可观测。
class _CountingTransport implements McpTransport {
  int closeCount = 0;

  @override
  Future<TransportResponse> send(String requestBody) async {
    final method = (jsonDecode(requestBody) as Map)['method'] as String?;
    final Object result = switch (method) {
      'initialize' => {
          'protocolVersion': '2025-06-18',
          'capabilities': {'tools': {}},
          'serverInfo': {'name': 'fake', 'version': '1.0'},
        },
      'tools/list' => {
          'tools': [
            {'name': 'a'},
          ],
        },
      _ => <String, Object?>{},
    };
    return TransportResponse(
      statusCode: 200,
      contentType: 'application/json',
      body: jsonEncode({'jsonrpc': '2.0', 'id': 1, 'result': result}),
    );
  }

  @override
  Future<StreamedTransportResponse> sendStream(String requestBody) async =>
      StreamedTransportResponse(
        statusCode: 200,
        contentType: 'text/event-stream',
        lines: const Stream<String>.empty(),
      );

  @override
  Future<StreamedTransportResponse> getStream() =>
      throw UnsupportedError('no GET SSE（非 HTTP 传输口径）');

  @override
  void close() => closeCount++;
}

/// 假插件源：固定两个同签名插件（免信任闸门），每次 scan 返回同一批。
class _FakeDiscovery implements LocalPluginSource {
  static const pluginCount = 2;
  static const _plugins = <LocalPluginInfo>[
    LocalPluginInfo(
      serverId: 'plugA',
      serverTitle: '插件A',
      packageName: 'com.example.a',
      serviceClassName: 'com.example.a.PluginService',
      sameSignature: true,
    ),
    LocalPluginInfo(
      serverId: 'plugB',
      serverTitle: '插件B',
      packageName: 'com.example.b',
      serviceClassName: 'com.example.b.PluginService',
      sameSignature: true,
    ),
  ];

  final transports = <_CountingTransport>[];
  final _changes = StreamController<void>.broadcast();

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<List<LocalPluginInfo>> scan() async => _plugins;

  @override
  McpClient createClient(LocalPluginInfo info) {
    final t = _CountingTransport();
    transports.add(t);
    return McpClient(t);
  }

  int get closedCount =>
      transports.fold(0, (sum, t) => sum + t.closeCount);
}

class _FakeTrustGate implements PluginTrustGate {
  @override
  bool isTrusted(String packageName) => true;
}

class _FakeSecure implements SecureKeyValue {
  final _m = <String, String>{};

  @override
  Future<String?> read(String key) async => _m[key];

  @override
  Future<void> write(String key, String value) async => _m[key] = value;

  @override
  Future<void> delete(String key) async => _m.remove(key);
}

void main() {
  late Directory tmp;
  late _FakeDiscovery discovery;
  late GatewayController c;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('gw_mount');
    discovery = _FakeDiscovery();
    c = GatewayController.shared;

    // 端点 store 预置空库（避免走 prefs 迁移分支）
    final store = ServerEndpointStore(
      file: File('${tmp.path}/mcp_servers.json'),
      secure: _FakeSecure(),
    );
    await store.save(const <ServerEndpoint>[]);

    // 逐条赋值（不用级联：cascade 内赋函数字面量会让后续级联目标被推断成
    // 该函数的返回类型，触发 undefined_setter）
    c.supportDir = () async => tmp;
    c.discovery = discovery;
    c.endpointStore = ({String? supportPath}) async => store;
    c.trustGate = () async => _FakeTrustGate();
  });

  tearDown(() async {
    await c.stop(); // 归还句柄（stop 幂等）
    // 还原注入位：shared 是进程级单例，防污染同文件其它用例
    c.supportDir = getApplicationSupportDirectory;
    c.discovery = localPluginDiscovery;
    c.endpointStore = serverEndpointStore;
    c.trustGate = _instance;
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('1 重扫：上一批挂载的传输全部释放（包变更广播不再累积泄漏）', () async {
    await c.rescan();
    expect(c.faces.length, _FakeDiscovery.pluginCount);
    expect(discovery.closedCount, 0, reason: '首次装配不关闭任何传输');

    await c.rescan(); // 模拟插件安装触发的包变更广播
    expect(discovery.closedCount, _FakeDiscovery.pluginCount,
        reason: '重扫必须先释放上一批——修复前裸 faces.clear() 会丢掉全部旧 client，'
            '每次广播泄漏一批（Binder EventChannel / 传输句柄）');
    expect(c.faces.length, _FakeDiscovery.pluginCount,
        reason: '释放与重挂成对：face 数不衰减');
  });

  test('2 起服失败（端口被占）：回滚全部装配句柄，零残留', () async {
    final blocker = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(blocker.close);

    await expectLater(
      c.start(address: InternetAddress.loopbackIPv4, port: blocker.port),
      throwsA(isA<Object>()),
      reason: '绑端口失败必须上抛（起服失败不能静默）',
    );

    expect(c.faces, isEmpty, reason: '装配成功但绑端口失败 → 不留悬空 face');
    expect(c.running, isFalse);
    expect(discovery.closedCount, _FakeDiscovery.pluginCount,
        reason: '起服失败须回滚全部已挂载句柄——修复前此处为 0（全套悬空）');
  });
}

/// 生产信任闸门（还原注入位用）。
Future<PluginTrustGate> _instance() async => TrustedPlugins.instance;
