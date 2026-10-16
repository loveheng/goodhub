/// B2 基线测试（window-kernel-split 步 0）+ 步 1 装配测试：会话绑定默认回退链
/// 纯函数、装配产物等价性、资源释放（close/abort 两段语义 + 装配异常回收）。
///
/// 回退链（plan.md §2.1 B2，「最易改错的一段」）：
/// 已显式绑定直接用（'' → null = 显式公共）→ 全局钉选 isDefault →
/// 首个 private → null。与 `chat_page._resolveBinding` 逐行同构（步 3 接线
/// 替换，等价性由此钉住）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/mcp_runtime.dart';
import 'package:goodhub/coordinator/skill_registry.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/mcp/mcp_client.dart';
import 'package:goodhub/mcp/server_endpoints.dart';
import 'package:goodhub/mcp/transport/mcp_transport.dart';
import 'package:goodhub/sandbox/memory_store.dart';

ServerEndpoint ep(
  String id, {
  ServerPrivacyTier tier = ServerPrivacyTier.private,
  bool isDefault = false,
}) =>
    ServerEndpoint(id: id, name: id, endpoint: 'http://x/mcp', tier: tier, isDefault: isDefault);

void main() {
  group('resolveBinding 回退链（B2）', () {
    test('已显式绑定 serverId：直接锁定，无视 isDefault 与顺序', () {
      final eps = [ep('a', isDefault: true), ep('b')];
      expect(resolveBinding(eps, bound: 'b'), 'b');
    });

    test('显式公共（''）→ null（不再回退私有——三态语义防回跳）', () {
      final eps = [ep('a', isDefault: true)];
      expect(resolveBinding(eps, bound: ''), isNull);
    });

    test('未绑定 + 全局钉选：isDefault 优先，与排列顺序无关', () {
      expect(resolveBinding([ep('a'), ep('d', isDefault: true)]), 'd');
      expect(resolveBinding([ep('d', isDefault: true), ep('a')]), 'd');
    });

    test('未绑定 + 无钉选：首个 private（保持列表序）', () {
      expect(resolveBinding([ep('p2'), ep('p1')]), 'p2');
    });

    test('public 端点不参与回退', () {
      expect(
        resolveBinding([
          ep('pub', tier: ServerPrivacyTier.public),
          ep('pub2', tier: ServerPrivacyTier.public, isDefault: true),
        ]),
        isNull,
        reason: 'public（含 isDefault）不得进私有槽位回退链',
      );
    });

    test('无 private 端点 → null（纯公共）', () {
      expect(resolveBinding(const <ServerEndpoint>[]), isNull);
    });

    test('钉选优先于首个 private（同列表两私有）', () {
      expect(resolveBinding([ep('first'), ep('pinned', isDefault: true)]), 'pinned');
    });
  });

  _assembleTests();
}

// ---------------------------------------------------------------------------
// 步 1 · 装配测试（plan §3 单测：装配产物等价性 + 资源释放）
// ---------------------------------------------------------------------------

/// 计数 fake 传输：协议面最小实现（initialize / tools/list），close 计数可观测
/// （句柄封死，只能从 transport 层观测——plan 步 1 单测断言手段）。
class _CountingTransport implements McpTransport {
  _CountingTransport({this.failSend = false});

  int closeCount = 0;
  final bool failSend;

  @override
  Future<TransportResponse> send(String requestBody) async {
    if (failSend) throw StateError('boom');
    final method = (jsonDecode(requestBody) as Map)['method'] as String?;
    Object? result;
    if (method == 'initialize') {
      result = {
        'protocolVersion': '2025-06-18',
        'capabilities': {'tools': {}},
        'serverInfo': {'name': 'fake', 'version': '1.0'},
      };
    } else if (method == 'tools/list') {
      result = {
        'tools': [
          {'name': 'a'},
        ],
      };
    } else {
      result = {};
    }
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
      throw UnsupportedError('no GET SSE（非 HTTP 传输口径，协议层退化不监听）');

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

Future<Directory> _tmpDir() async {
  final d = await Directory.systemTemp.createTemp('mcp_runtime_test');
  addTearDown(() => d.delete(recursive: true));
  return d;
}

Future<McpAssembly> _assemble({
  required List<ServerEndpoint> endpoints,
  required Map<String, McpClient> clients,
  required List<McpTransport> transports,
  SessionContext? context,
}) async {
  final tmp = await _tmpDir();
  return const McpRuntime().assemble(
    context: context ?? SessionContext(),
    endpoints: endpoints,
    locals: const [],
    apiKeyReader: (id) async => 'key-$id',
    memoryStore: MemoryStore.underSupportDir(tmp.path),
    skills: SkillRegistry()..registerAll(builtinSkills()),
    engine: _FakeEngine(),
    tempDirResolver: _tmpDir,
    documentsDirResolver: _tmpDir,
    clientFactory: (endpoint, apiKey) {
      final transport = _CountingTransport();
      transports.add(transport);
      final client = McpClient(transport);
      clients[endpoint] = client;
      return client;
    },
  );
}

void _assembleTests() {
  test('装配产物等价性：私有槽位/激活集/回退链/摘要快照', () async {
    final transports = <McpTransport>[];
    final clients = <String, McpClient>{};
    final assembly = await _assemble(
      endpoints: [ep('priv', isDefault: true), ep('pub', tier: ServerPrivacyTier.public)],
      clients: clients,
      transports: transports,
    );
    addTearDown(assembly.close);

    expect(assembly.router.privateServerIds, {'priv'});
    expect(assembly.router.activatedServers, {'pub'}, reason: 'public 默认激活，private 不激活');
    expect(assembly.router.activePrivateServerId, 'priv',
        reason: '未显式绑定 → 全局钉选回退');
    expect(assembly.serverSummaries['priv'], contains('Tier'));
    expect(transports, hasLength(2));
  });

  test('显式公共（bound=""）回退链不回跳私有', () async {
    final assembly = await _assemble(
      endpoints: [ep('priv', isDefault: true)],
      clients: {},
      transports: [],
      context: SessionContext(activePrivateServerId: ''),
    );
    addTearDown(assembly.close);
    expect(assembly.router.activePrivateServerId, isNull);
  });

  test('close() 释放全部传输（计数=1）且幂等；abort 不释放', () async {
    final transports = <McpTransport>[];
    final assembly = await _assemble(
      endpoints: [ep('a'), ep('b')],
      clients: {},
      transports: transports,
    );
    assembly.abort(reason: 'test'); // 不释放
    expect(transports.every((t) => (t as _CountingTransport).closeCount == 0), isTrue);

    await assembly.close();
    expect(transports.every((t) => (t as _CountingTransport).closeCount == 1), isTrue,
        reason: 'close 释放底层传输（T5b：stop 之外的 client.close 既有债）');
    await assembly.close(); // 幂等
    expect(transports.every((t) => (t as _CountingTransport).closeCount == 1), isTrue);
  });

  test('装配异常路径：第 2 个端点失败 → 已建端点传输全部回收（不泄漏）', () async {
    final transports = <McpTransport>[];
    final tmp = await _tmpDir();
    await expectLater(
      const McpRuntime().assemble(
        context: SessionContext(),
        endpoints: [ep('ok'), ep('boom')],
        locals: const [],
        apiKeyReader: (id) async => 'key-$id',
        memoryStore: MemoryStore.underSupportDir(tmp.path),
        skills: SkillRegistry(),
        engine: _FakeEngine(),
        tempDirResolver: _tmpDir,
        documentsDirResolver: _tmpDir,
        clientFactory: (endpoint, apiKey) {
          final fail = (apiKey ?? '').contains('boom');
          final transport = _CountingTransport(failSend: fail);
          transports.add(transport);
          return McpClient(transport);
        },
      ),
      throwsA(isA<Object>()),
    );
    // ep('boom') 与 ep('ok') 共用 endpoint 形状——factory 按 id 注入失败件失败，
    // ok 端点已建连接必须被回收：
    expect(
      transports.whereType<_CountingTransport>().where((t) => !t.failSend),
      isNotEmpty,
    );
    expect(
      transports.whereType<_CountingTransport>().where((t) => !t.failSend).every((t) => t.closeCount >= 1),
      isTrue,
      reason: '装配异常路径：成功协商的端点也必须 close（防泄漏）',
    );
  });
}

