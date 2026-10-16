/// P0-B 网关安全上下文隔离 + 装配句柄释放回归（2026-10-17）。
///
/// 两条致命暗雷：
/// 1. `GatewayHandler.forSession()` 此前把 `security` **同一引用**透传给所有 PC
///    会话 → `_sessionGrants` 全局共享：PC-A 点「本会话记住」后 PC-B 同工具免
///    L2 确认（跨会话提权）；且 grant 只按 tool 名，跨 server 同名工具互免。
/// 2. 挂载原语（`McpRuntime.mount/mountEndpoint`）此前只回 face/caps/schemas，
///    **没有任何释放通道**——`mountEndpoint` 内部建的 client 调用方拿不到引用，
///    网关重扫/停服无从关闭，每次包变更广播触发重扫就泄漏一批传输资源。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/mcp_runtime.dart';
import 'package:goodhub/coordinator/permission_gateway.dart';
import 'package:goodhub/gateway/gateway_security.dart';
import 'package:goodhub/gateway/mcp_gateway_handler.dart';
import 'package:goodhub/mcp/mcp_client.dart';
import 'package:goodhub/mcp/server_endpoints.dart';
import 'package:goodhub/mcp/transport/mcp_transport.dart';

/// 确认卡假件：记录被调用次数（弹卡次数 = 是否走了人工裁决）。
class _FakeDelegate implements GateDelegate {
  _FakeDelegate(this.decision);

  final GateDecision decision;
  var calls = 0;

  @override
  Future<GateDecision> confirm(ToolPendingConfirmation pending) async {
    calls++;
    return decision;
  }
}

/// 计数假传输：协议面最小实现，close 可观测（句柄封死，只能从传输层观测）。
class _CountingTransport implements McpTransport {
  _CountingTransport({this.failSend = false});

  int closeCount = 0;
  final bool failSend;

  @override
  Future<TransportResponse> send(String requestBody) async {
    if (failSend) throw StateError('boom');
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

const _okResult = GatewayToolResult(content: 'ok', isError: false);

Future<GatewayToolResult> _ok() async => _okResult;

const _ep = ServerEndpoint(id: 'ep1', name: 'ep1', endpoint: 'http://x/mcp');

void main() {
  group('P0-B 会话豁免隔离', () {
    test('1 会话豁免不跨 PC 连接：A 记住后，B 连接同工具仍须弹卡', () async {
      final delegateA = _FakeDelegate(
        const GateDecision(approved: true, rememberSession: true),
      );
      final delegateB =
          _FakeDelegate(const GateDecision(approved: true));
      final secA = GatewaySecurity(delegate: delegateA);
      final secB = secA.forSession()..delegate = delegateB;

      await secA.guard(
        serverId: 'srv',
        tool: 'srv__write',
        annotations: null, // 双缺从严 → L2
        argumentsJson: '{}',
        run: _ok,
      );
      expect(delegateA.calls, 1, reason: 'A 首次调用须经确认卡');

      await secB.guard(
        serverId: 'srv',
        tool: 'srv__write',
        annotations: null,
        argumentsJson: '{}',
        run: _ok,
      );
      expect(delegateB.calls, 1,
          reason: 'B 是另一个 PC 会话，不得继承 A 的「本会话记住」'
              '（修复前共享同一 security 实例：此处为 0，等于跨会话提权）');
    });

    test('2 同名工具分属不同服务不得互免（grant key 强制带服务维度）', () async {
      final delegate = _FakeDelegate(
        const GateDecision(approved: true, rememberSession: true),
      );
      final sec = GatewaySecurity(delegate: delegate);

      await sec.guard(
          serverId: 'srvA', tool: 'write', annotations: null, argumentsJson: '{}', run: _ok);
      await sec.guard(
          serverId: 'srvB', tool: 'write', annotations: null, argumentsJson: '{}', run: _ok);

      expect(delegate.calls, 2,
          reason: '豁免键须为 serverId::tool——只按 tool 名会让 A 服务获批'
              '替 B 服务同名工具开后门（修复前此处为 1）');
    });

    test('3 连接投影各自持有独立安全上下文，disposeSession 幂等', () {
      final sec = GatewaySecurity(delegate: _FakeDelegate(const GateDecision(approved: true)));
      final template = GatewayHandler(faces: const {}, security: sec);
      final s1 = template.forSession();
      final s2 = template.forSession();

      expect(identical(s1.security, s2.security), isFalse,
          reason: '两连接的豁免集必须互不干扰');
      expect(identical(s1.security, sec), isFalse,
          reason: '模板的 security 是投影源，不得被连接直接持有');

      s1.disposeSession();
      s1.disposeSession(); // 幂等：回收路径（idle GC / stop）可能重复调用
    });

    test('4 连接回收后该连接的豁免不残留', () async {
      final delegate = _FakeDelegate(
        const GateDecision(approved: true, rememberSession: true),
      );
      final sec = GatewaySecurity(delegate: delegate);
      final session = GatewayHandler(faces: const {}, security: sec).forSession();

      await session.security!.guard(
          serverId: 'srv', tool: 'write', annotations: null, argumentsJson: '{}', run: _ok);
      expect(delegate.calls, 1);

      session.disposeSession(); // 模拟连接 idle 回收
      await session.security!.guard(
          serverId: 'srv', tool: 'write', annotations: null, argumentsJson: '{}', run: _ok);
      expect(delegate.calls, 2, reason: '新连接（复用 handler 对象）须重新裁决');
    });
  });

  group('P0-B 装配句柄释放通道', () {
    test('5 mount：调用方经 release 交回的释放能力随句柄返回', () async {
      final t = _CountingTransport();
      final mount = await const McpRuntime().mount(
        serverId: 's1',
        client: McpClient(t),
        release: () => t.close(),
      );

      expect(t.closeCount, 0, reason: '挂载本身不得关闭调用方持有的 client');
      mount.close();
      expect(t.closeCount, 1);
    });

    test('6 mountEndpoint：拥有 client 就必须交出释放通道', () async {
      final t = _CountingTransport();
      final mount = await const McpRuntime().mountEndpoint(
        _ep,
        clientFactory: (endpoint, apiKey) => McpClient(t),
      );

      expect(t.closeCount, 0);
      mount.close(); // 网关重扫/停服走这条（修复前：无从关闭，恒 0）
      expect(t.closeCount, 1);
    });

    test('7 mountEndpoint 挂载失败须自清理 client 再上抛', () async {
      final t = _CountingTransport(failSend: true);

      await expectLater(
        const McpRuntime().mountEndpoint(
          _ep,
          clientFactory: (endpoint, apiKey) => McpClient(t),
        ),
        throwsA(isA<Object>()),
      );
      expect(t.closeCount, 1, reason: '失败路径不留悬空 client（既有契约，防回归）');
    });
  });
}
