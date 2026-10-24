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
import 'package:goodhub/gateway/mcp_gateway_handler.dart';
import 'package:goodhub/gateway/projection_pipeline.dart';
import 'package:goodhub/mcp/local_plugin_discovery.dart';
import 'package:goodhub/mcp/mcp_client.dart';
import 'package:goodhub/mcp/server_endpoints.dart';
import 'package:goodhub/mcp/trusted_plugins.dart';
import 'package:goodhub/mcp/transport/host_transport.dart';
import 'package:goodhub/core/tool_result.dart';
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
  bool isTrusted(String packageName, {String signatureSha256 = ''}) => true;
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
    c.hostExportAllowlist = kHostExportAllowlist;
    c.hostInvokerProvider = GatewayController.defaultHostInvoker;
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  /// host 虚拟服务占用的 face 数（三源装配的第三源）。
  const hostFaceCount = 1;

  group('消费者视图（装配层合一 · Expand 件）', () {
    test('faceFor：已挂载返回 face 实例，未挂载返回 null', () async {
      await c.rescan();
      expect(c.faceFor(kHostServerId), isNotNull,
          reason: 'host 虚拟服务三源装配恒挂载');
      expect(c.faceFor('plugA'), isNotNull, reason: '本地插件源 face 可读');
      expect(c.faceFor('not_mounted_xx'), isNull);
    });

    test('ensureEndpointMounted：已挂载 id 幂等直返（不触发重扫，零新连接）', () async {
      await c.rescan();
      final before = discovery.transports.length;
      final face = await c.ensureEndpointMounted(const ServerEndpoint(
        id: 'plugA',
        name: '插件A',
        endpoint: '', // 空端点本不应挂载——但 id 已在 face 表，幂等直返
      ));
      expect(face, isNotNull, reason: 'face 表命中即返回（单点装配路径零拷贝）');
      expect(discovery.transports.length, before,
          reason: '幂等路径不得触发重扫（重扫会释放重建全部传输）');
      expect(identical(face, c.faces['plugA']), isTrue);
    });

    test('ensureEndpointMounted：未挂载 → 触发一次 rescan，仍无则 null', () async {
      await c.rescan(); // 端点 store 为空库：该端点装配后仍缺席
      final face = await c.ensureEndpointMounted(const ServerEndpoint(
        id: 'ghost_ep',
        name: '幽灵端点',
        endpoint: 'http://127.0.0.1:1/mcp',
      ));
      expect(face, isNull, reason: '端点不在 store / 挂载失败 → null（不炸不猜）');
    });

    test('facesChanged：rescan 后消费者流收到变更事件', () async {
      final got = <void>[];
      final sub = c.facesChanged.listen(got.add);
      addTearDown(sub.cancel);
      await c.rescan();
      await Future<void>.delayed(Duration.zero); // broadcast 流微任务冲刷
      expect(got, isNotEmpty, reason: '消费方以「重拉目录」语义消费变更流');
    });
  });

  test('1 重扫：上一批挂载的传输全部释放（包变更广播不再累积泄漏）', () async {
    await c.rescan();
    expect(c.faces.length, _FakeDiscovery.pluginCount + hostFaceCount,
        reason: '三源装配：本地插件 + host 虚拟服务（本例无端点）');
    expect(discovery.closedCount, 0, reason: '首次装配不关闭任何传输');

    await c.rescan(); // 模拟插件安装触发的包变更广播
    expect(discovery.closedCount, _FakeDiscovery.pluginCount,
        reason: '重扫必须先释放上一批——修复前裸 faces.clear() 会丢掉全部旧 client，'
            '每次广播泄漏一批（Binder EventChannel / 传输句柄）');
    expect(c.faces.length, _FakeDiscovery.pluginCount + hostFaceCount,
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

  test('3 host 虚拟服务：faces[host] 装配，合成面经网关 tools/call 端到端实调',
      () async {
    final calls = <String>[];
    c.hostExportAllowlist = const [
      HostExportEntry(
        name: 'echo_host',
        description: '测试用宿主只读工具',
        inputSchema: <String, Object?>{'type': 'object'},
        annotations: <String, Object?>{'readOnlyHint': true},
      ),
    ];
    c.hostInvokerProvider = (opsLog) async {
      Future<ToolExecutionResult> invoke({
        required String name,
        required String argumentsJson,
      }) async {
        calls.add(name);
        return const ToolExecutionResult(content: 'host-echo-ok');
      }

      return (invoke: invoke, schemaOf: (_) => null);
    };

    await c.rescan();
    expect(c.faces.containsKey(kHostServerId), isTrue,
        reason: '第三装配源：host 虚拟服务须真挂上（否则保留字断言只防挤占不产生收益）');

    final handler = GatewayHandler(
      faces: c.faces,
      privateServerIds: c.privateServerIds,
    );
    // 对外目录：host 工具带 host__ 前缀且 visibility=shared 才进联邦面
    final names = handler.toolsList().map((t) => t['name'] as String).toList();
    expect(names, contains('host__echo_host'));

    final called = await handler.toolsCall(
      name: 'host__echo_host',
      arguments: const <String, Object?>{},
      onProgress: (_) {},
    );
    expect(called.isError, isFalse);
    expect(called.content, 'host-echo-ok');
    expect(calls, ['echo_host'], reason: '前缀经 face 剥除后只把裸名交给宿主执行面');

    await c.stop();
    expect(c.faces, isEmpty, reason: '停服释放含 host 虚拟服务在内的全部句柄');
  });

  test('4 Allowlist 首项端到端：默认登记表 + 默认端口（两条降级路径下仍通）',
      () async {
    // 默认 allowlist（生产表，含 get_host_status）+ 默认 invoker provider：
    // 纯 Dart 环境下资源面（path_provider）与版本（package_info）双双不可用，
    // 两者都须 DEGRADE 降级且**不阻断 host 面装配**。
    await c.rescan();
    final face = c.faces[kHostServerId];
    expect(face, isNotNull);
    expect(face!.cachedSchemas.map((s) => s.name), contains('get_host_status'),
        reason: 'Allowlist 登记项经合成面进 face（schema 由执行面提供）');

    final full = GatewayHandler(faces: c.faces, privateServerIds: c.privateServerIds);
    expect(full.toolsList().map((e) => e['name']), contains('host__get_host_status'));
    final called = await full.toolsCall(
      name: 'host__get_host_status',
      arguments: const <String, Object?>{},
      onProgress: (_) {},
    );
    expect(called.isError, isFalse);
    expect(called.content, contains('goodhub'),
        reason: '宿主身份事实须真的回到 PC（证明整链装配通）');

    final single = GatewayHandler(
      faces: c.faces,
      privateServerIds: c.privateServerIds,
      policy: ProjectionPolicy.single(kHostServerId),
    );
    // 目录按 name 字典序稳定化（管道出口），故用 containsAll 而非顺序断言
    final singleNames = single.toolsList().map((e) => e['name']).toList();
    expect(singleNames, containsAll(
        ['get_host_status', GatewayHandler.kGatewaySelectPrivate]));
    expect(singleNames, hasLength(2),
        reason: 'single 只暴露目标服务 + 唯一出口工具，无公共面泄漏');
    final singleCall = await single.toolsCall(
      name: 'get_host_status',
      arguments: const <String, Object?>{},
      onProgress: (_) {},
    );
    expect(singleCall.isError, isFalse, reason: '无前缀入站经服务端补齐后直达');
    expect(singleCall.content, contains('goodhub'));
  });

  test('5 host 执行端口 provider 抛错：DEGRADE 不阻断其余源装配', () async {
    c.hostInvokerProvider = (opsLog) async => throw StateError('invoker boom');

    await c.rescan();
    expect(c.faces.containsKey(kHostServerId), isFalse,
        reason: 'host 面装配失败即缺席');
    expect(c.faces.length, _FakeDiscovery.pluginCount,
        reason: '单源失败不阻断本地插件源（宁缺勿炸）');
  });
}

/// 生产信任闸门（还原注入位用）。
Future<PluginTrustGate> _instance() async => TrustedPlugins.instance;
