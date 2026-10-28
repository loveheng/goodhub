/// 保留命名空间断言单测（host-tools-gateway-export PR1-2 / 架构债 #15）。
///
/// 口径：`host` 仅限内置 `HostTransport` 装配；外部传输（Binder 插件 / 手填
/// HTTP 端点 / 任意第三方 transport）声明 `host` 一律拒装——命名仲裁未落地前
/// 重名走静默跳过，本断言是防挤占的唯一手段。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/mcp_runtime.dart';
import 'package:goodhub/coordinator/skill_registry.dart';
import 'package:goodhub/core/errors/mcp_error.dart';
import 'package:goodhub/core/tool_result.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/mcp/mcp_client.dart';
import 'package:goodhub/mcp/server_endpoints.dart';
import 'package:goodhub/mcp/transport/host_transport.dart';
import 'package:goodhub/mcp/transport/mcp_transport.dart';
import 'package:goodhub/sandbox/memory_store.dart';
import 'package:goodhub/core/actor.dart';

/// 外部服务传输 fake（冒充第三方插件 / 远端端点：非 HostTransport）。
class _ForeignTransport implements McpTransport {
  int closeCount = 0;

  @override
  Future<TransportResponse> send(String requestBody) async {
    final method = (jsonDecode(requestBody) as Map)['method'] as String?;
    final result = switch (method) {
      'initialize' => {
          'protocolVersion': '2025-06-18',
          'capabilities': {'tools': <String, Object?>{}},
          'serverInfo': {'name': 'squatter', 'version': '1.0'},
        },
      'tools/list' => {
          'tools': [
            {'name': 'hijack'}
          ]
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
      throw UnsupportedError('fake 无 GET SSE');

  @override
  void close() => closeCount++;
}

class _FakeEngine implements CloudLlmEngine {
  @override
  String get name => 'fake';

  @override
  Stream<CloudStreamEvent> send(CloudChatRequest request, {void Function()? onActivity}) =>
      const Stream<CloudStreamEvent>.empty();
}

Future<MemoryStore> _store() async {
  final store = MemoryStore.underSupportDir((await _tmpDir()).path);
  // 排空握手用 ioDrained（§3.2），防在途 append 写与临时目录删除竞态。
  addTearDown(() => store.ioDrained);
  return store;
}

Future<Directory> _tmpDir() async {
  final d = await Directory.systemTemp.createTemp('reserved_ns_test');
  addTearDown(() => d.delete(recursive: true));
  return d;
}

ServerEndpoint _ep(String id) => ServerEndpoint(
      id: id,
      name: id,
      endpoint: 'http://$id/mcp',
      tier: ServerPrivacyTier.public,
    );

void main() {
  group('mount 入口断言', () {
    test('外部传输声明 host → 抛 ReservedNamespaceException', () async {
      await expectLater(
        const McpRuntime().mount(
          serverId: 'host',
          client: McpClient(_ForeignTransport()),
        ),
        throwsA(isA<ReservedNamespaceException>()),
        reason: '架构债 #15：外部插件 / 手填端点不得挤占宿主虚拟服务',
      );
    });

    test('内置 HostTransport 声明 host → 允许挂载（面可列可调可释）', () async {
      final client = McpClient(HostTransport(
        invoker: ({required String name, required String argumentsJson}) async =>
            const ToolExecutionResult(content: 'host-ok'),
        allowlist: [
          HostExportEntry(
            allowedActors: <Actor>{Actor.owner},
            name: 'get_host_status',
            description: '测试用只读工具',
            inputSchema: <String, Object?>{'type': 'object'},
            annotations: <String, Object?>{'readOnlyHint': true},
          ),
        ],
      ));
      final m = await const McpRuntime().mount(
        serverId: 'host',
        client: client,
        release: client.close,
      );
      expect(m.face.serverId, 'host');
      expect(m.caps.hasTools, isTrue);
      expect(m.face.cachedSchemas.map((s) => s.name), ['get_host_status']);
      expect(m.face.cachedSchemas.single.visibility.name, 'shared');

      // 经 face 实调（网关投影层剥前缀后直达的路径）
      final called = await m.face.execute(const AssembledToolCall(
        id: 'c1',
        name: 'get_host_status',
        argumentsJson: '{}',
      ));
      expect(called.isError, isFalse);
      expect(called.content, 'host-ok');

      m.close();
      await expectLater(client.call('ping'), throwsStateError);
    });

    test('非保留 serverId 不受影响（外部服务照常挂载）', () async {
      final client = McpClient(_ForeignTransport());
      final m = await const McpRuntime().mount(
        serverId: 'goodshare',
        client: client,
        release: client.close,
      );
      expect(m.face.cachedSchemas.map((s) => s.name), ['hijack']);
      m.close();
    });

    test('mountEndpoint 端点 id=host → 同样拒装（委托 mount 同一断言）',
        () async {
      await expectLater(
        const McpRuntime().mountEndpoint(
          ServerEndpoint(
            id: 'host',
            name: 'host',
            endpoint: 'http://x/mcp',
            tier: ServerPrivacyTier.public,
          ),
          clientFactory: (_, _) => McpClient(_ForeignTransport()),
        ),
        throwsA(isA<ReservedNamespaceException>()),
      );
    });
  });

  group('assemble 直挂循环（chat 装配面）', () {
    test('端点声明 host → 该端点拒装 + danger 通告，其余端点照常挂载', () async {
      final notes = <String>[];
      final assembly = await const McpRuntime().assemble(
        context: SessionContext(),
        endpoints: [_ep('host'), _ep('goodshare')],
        locals: const [],
        apiKeyReader: (id) async => 'key-$id',
        memoryStore: await _store(),
        skills: SkillRegistry()..registerAll(builtinSkills()),
        engine: _FakeEngine(),
        tempDirResolver: _tmpDir,
        documentsDirResolver: _tmpDir,
        clientFactory: (endpoint, apiKey) => McpClient(_ForeignTransport()),
      );
      addTearDown(assembly.close);
      expect(assembly.router.serverIds, ['goodshare'],
          reason: 'host 端点被拒装，且不得炸掉整轮装配');
      expect(assembly.router.serverIds, isNot(contains('host')));
      expect(notes, isEmpty, reason: '通告经 onNote 端口，本例未注入');
    });

    test('被拒端点的 client 走 close 释放（不泄漏连接）', () async {
      final transports = <_ForeignTransport>[];
      final assembly = await const McpRuntime().assemble(
        context: SessionContext(),
        endpoints: [_ep('host')],
        locals: const [],
        apiKeyReader: (id) async => 'key-$id',
        memoryStore: await _store(),
        skills: SkillRegistry()..registerAll(builtinSkills()),
        engine: _FakeEngine(),
        tempDirResolver: _tmpDir,
        documentsDirResolver: _tmpDir,
        clientFactory: (endpoint, apiKey) {
          final t = _ForeignTransport();
          transports.add(t);
          return McpClient(t);
        },
      );
      addTearDown(assembly.close);
      expect(transports, hasLength(1));
      expect(transports.single.closeCount, 1, reason: '拒装即释放，不得留悬空 client');
      expect(assembly.router.serverIds, isEmpty);
    });
  });
}