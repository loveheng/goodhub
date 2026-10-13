// 设备侧无头 e2e：发现 → Binder 同步 → 反向请求闭环 → 网关 HTTP 聚合。
//
// 运行（真机联调）：
//   flutter test integration_test/thirdconnect_e2e_test.dart -d <device>
//
// 覆盖 thirdconnect 断点「设备 e2e 联调」：T-trans-2/3/4 + G1~G5 全链路。
// 注意：刻意不经由 GatewayController.start()（其会拉起前台保活服务，在测试
// 进程/非前台下易被系统杀进程），改为手工装配 face + 直接起 McpGatewayServer。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:goodhub/coordinator/mcp_tool_face.dart';
import 'package:goodhub/coordinator/permission_gateway.dart';
import 'package:goodhub/gateway/gateway_security.dart';
import 'package:goodhub/gateway/mcp_gateway_handler.dart';
import 'package:goodhub/gateway/gateway_server.dart';
import 'package:goodhub/mcp/local_plugin_discovery.dart';

/// 测试用自动批准 delegate：绕过手机屏 L2 确认卡，让网关工具真跑（无人值守不挂起）。
class _AutoApproveDelegate implements GateDelegate {
  const _AutoApproveDelegate();
  @override
  Future<GateDecision> confirm(ToolPendingConfirmation pending) async =>
      const GateDecision(approved: true, rememberSession: true);
}

Future<T> _withTimeout<T>(Future<T> f, String label) => f.timeout(
      const Duration(seconds: 30),
      onTimeout: () => throw TimeoutException('超时: $label', const Duration(seconds: 30)),
    );

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('thirdconnect e2e: discovery + binder sync + reverse loop + gateway http',
      (tester) async {
    debugPrint('[e2e] phase0: scan');
    // ---- e2e-1 发现：GoodHub 自动发现本地 dummy 插件（<queries> + 包扫描）----
    final plugins = await _withTimeout(localPluginDiscovery.scan(), 'scan');
    final dummy = plugins.where((p) => p.serverId == 'dummy').toList();
    expect(dummy, isNotEmpty, reason: '应扫描到本地插件 dummy（serverId=dummy）');
    debugPrint('[e2e] discovered: ${dummy.map((e) => e.serverId).join(', ')}');

    // ---- 手工装配 face（等价 GatewayController._assemble，但不拉前台保活）----
    final handler = GatewayHandler(
      faces: <String, McpToolFace>{},
      security: GatewaySecurity(delegate: const _AutoApproveDelegate()),
    );
    for (final info in plugins) {
      if (info.serverId.isEmpty || handler.faces.containsKey(info.serverId)) continue;
      final client = localPluginDiscovery.createClient(info);
      try {
        await _withTimeout(client.negotiate(), 'negotiate ${info.serverId}');
        final face = McpToolFace(client: client, serverId: info.serverId);
        await _withTimeout(face.listTools(), 'listTools ${info.serverId}');
        handler.faces[info.serverId] = face;
      } on Object catch (e) {
        debugPrint('[e2e][DEGRADE] mount ${info.serverId} failed: $e');
        client.close();
      }
    }
    expect(handler.faces.containsKey('dummy'), isTrue,
        reason: '应挂载 dummy face（系统托管端点）');

    // ---- e2e-1b 聚合 tools/list：前缀 <server_id>__<tool> 透传 ----
    final names = handler.toolsList().map((t) => t['name'] as String).toList();
    debugPrint('[e2e] tools: $names');
    expect(names, contains('dummy__echo'), reason: '应聚合 echo');
    expect(names, contains('dummy__add'), reason: '应聚合 add');
    expect(names, contains('dummy__slowEcho'), reason: '应聚合 slowEcho');
    expect(names, contains('dummy__reverseDemo'), reason: '应聚合 reverseDemo');

    // ---- e2e-2 Binder 同步链路：dummy__slowEcho（progress + 终帧）----
    final r1 = await _withTimeout(
      handler.toolsCall(
        name: 'dummy__slowEcho',
        arguments: {'text': 'hello-binder'},
        onProgress: (_) {},
      ),
      'slowEcho',
    );
    expect(r1.isError, isFalse, reason: 'slowEcho 不应报错');
    expect(r1.content, contains('hello-binder'),
        reason: 'slowEcho 应通过 Binder 回显输入');
    debugPrint('[e2e] slowEcho -> ${r1.content}');

    // ---- e2e-3 反向请求闭环：reverseDemo → sampling(createMessage) → answerReverse ----
    // 注入假 onServerRequest，绕开云端 LLM 可用性，纯净验证传输闭环。
    final face = handler.faces['dummy']!;
    face.client.onServerRequest = (method, params) async {
      expect(method, 'sampling/createMessage');
      return {
        'role': 'assistant',
        'model': 'test-stub',
        'content': {'type': 'text', 'text': 'fake-sampling'},
      };
    };
    final r2 = await _withTimeout(
      face.client.callWithProgress(
        'tools/call',
        params: {
          'name': 'reverseDemo',
          'arguments': {'prompt': 'ping'},
        },
        onProgress: (_) {},
      ),
      'reverseDemo',
    );
    final r2content = _textOf(r2);
    expect(r2content, contains('sampling result: fake-sampling'),
        reason: '反向请求应经 answerReverse 回程并被插件消费（闭环）');
    debugPrint('[e2e] reverseDemo -> $r2content');

    // ---- e2e-4 网关 HTTP（PC 路径，loopback 模拟 PC）----
    final server = McpGatewayServer(handler);
    await server.start(address: InternetAddress.loopbackIPv4, port: 8766);
    debugPrint('[e2e] gateway listening on loopback:8766');
    final client = HttpClient();
    try {
      final (sid, initResp) = await _withTimeout(_rpc(client, '', {
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {
          'protocolVersion': '2025-06-18',
          'capabilities': <String, Object?>{},
          'clientInfo': {'name': 'e2e', 'version': '0'},
        },
      }), 'http initialize');
      expect(initResp['result'], isNotNull, reason: 'initialize 应返回 result');

      final (sid2, listResp) = await _withTimeout(_rpc(client, sid, {
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/list',
      }), 'http tools/list');
      final tools = (listResp['result'] as Map)['tools'] as List;
      expect(tools.any((t) => (t as Map)['name'] == 'dummy__slowEcho'), isTrue,
          reason: 'PC 经 /mcp 应看到 dummy__slowEcho');

      final (sid3, callResp) = await _withTimeout(_rpc(client, sid2, {
        'jsonrpc': '2.0',
        'id': 3,
        'method': 'tools/call',
        'params': {
          'name': 'dummy__slowEcho',
          'arguments': {'text': 'http-e2e'},
        },
      }), 'http tools/call');
      final result = callResp['result'] as Map;
      final text = _textOf(result);
      expect(text, contains('http-e2e'),
          reason: 'PC 经网关 :8766 应经 Binder 调通本地插件');
      debugPrint('[e2e] http slowEcho -> $text');
    } finally {
      client.close();
      await server.stop();
    }
  });
}

String _textOf(Object? result) {
  if (result is! Map) return '';
  final content = result['content'];
  if (content is List) {
    final texts = [
      for (final c in content)
        if (c is Map && c['type'] == 'text' && c['text'] is String) c['text'] as String,
    ];
    return texts.join('\n');
  }
  return '';
}

Future<(String, Map<String, Object?>)> _rpc(
  HttpClient client,
  String sid,
  Map<String, Object?> body,
) async {
  final req = await client.post('127.0.0.1', 8766, '/mcp');
  req.headers.contentType = ContentType.json;
  if (sid.isNotEmpty) req.headers.set('Mcp-Session-Id', sid);
  req.write(jsonEncode(body));
  final resp = await req.close();
  final newSid = resp.headers.value('Mcp-Session-Id') ?? sid;
  final text = await resp.transform(utf8.decoder).join();
  final json = jsonDecode(text) as Map<String, Object?>;
  return (newSid, json);
}
