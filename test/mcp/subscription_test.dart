import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/core/errors/mcp_error.dart';
import 'package:goodhub/core/network/backoff.dart';
import 'package:goodhub/mcp/connection_health.dart';
import 'package:goodhub/mcp/connection_manager.dart';
import 'package:goodhub/coordinator/mcp_tool_face.dart';
import 'package:goodhub/mcp/mcp_client.dart';
import 'package:goodhub/mcp/transport/mcp_transport.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response okJson(Object? result, {int status = 200}) => http.Response(
      jsonEncode({'jsonrpc': '2.0', 'id': 1, 'result': result}),
      status,
      headers: {'content-type': 'application/json'},
    );

/// 轮询等待谓词成立（监听是 fire-and-forget，需在推帧前确证已订阅广播流）。
Future<void> _waitFor(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final sw = Stopwatch()..start();
  while (!predicate()) {
    if (sw.elapsed > timeout) throw TimeoutException('waitFor timed out');
    await Future.delayed(const Duration(milliseconds: 2));
  }
}

TransportResponse fakeOk(Object? result, {int status = 200}) =>
    TransportResponse(
      statusCode: status,
      contentType: 'application/json',
      body: jsonEncode({'jsonrpc': '2.0', 'id': 1, 'result': result}),
    );

TransportResponse fakeNoContent() => const TransportResponse(
      statusCode: 202,
      contentType: 'application/json',
      body: '',
    );

/// 可注入的假传输：send/sendStream 按 method 路由；getStream 返回一条**保持打开**
/// 的广播流（测试可手动推 SSE 帧，且不会触发监听循环重连）。
class FakeTransport implements McpTransport {
  FakeTransport(this._handler);
  final TransportResponse Function(String method, String body) _handler;
  final StreamController<String> getCtl =
      StreamController<String>.broadcast();

  @override
  Future<TransportResponse> send(String requestBody) async {
    final m = jsonDecode(requestBody)['method'] as String;
    return _handler(m, requestBody);
  }

  @override
  Future<StreamedTransportResponse> sendStream(String requestBody) async {
    final m = jsonDecode(requestBody)['method'] as String;
    final r = _handler(m, requestBody);
    return StreamedTransportResponse(
      statusCode: r.statusCode,
      contentType: r.contentType,
      lines: Stream.value(r.body),
    );
  }

  @override
  Future<StreamedTransportResponse> getStream() async => StreamedTransportResponse(
        statusCode: 200,
        contentType: 'text/event-stream',
        lines: getCtl.stream,
      );

  @override
  void close() => getCtl.close();
}

/// 标准协商响应（带订阅能力）。
TransportResponse _initWithSubs() => fakeOk({
      'protocolVersion': '2025-06-18',
      'capabilities': {
        'resources': {'subscribe': true},
      },
    });

/// 录制所有请求 method 的假 server（按 hasSubs 声明订阅能力）。
McpClient clientWithRecorder(
  List<String> recorded, {
  bool hasSubs = true,
  List<Object?> tools = const [
    {'name': 'a'},
  ],
}) =>
    McpClient.http(
      baseUrl: 'http://10.0.0.5:8765/mcp',
      httpClient: MockClient((req) async {
        final m = jsonDecode(req.body)['method'] as String;
        recorded.add(m);
        switch (m) {
          case 'initialize':
            return okJson({
              'protocolVersion': '2025-06-18',
              'capabilities': {
                'resources': {'subscribe': hasSubs},
              },
            });
          case 'notifications/initialized':
            return http.Response('', 202);
          case 'tools/list':
            return okJson({'tools': tools});
          case 'resources/subscribe':
            return okJson({'subscriptionId': 's1'});
          case 'resources/unsubscribe':
            return okJson(<String, Object?>{});
          default:
            return okJson(<String, Object?>{});
        }
      }),
    );

void main() {
  const noBackoff = ExponentialBackoff(jitter: 0, initial: Duration.zero);

  group('T4-5 订阅消费 · McpClient', () {
    test('subscribeResource 下发 resources/subscribe + 返回 id + 记录订阅',
        () async {
      final rec = <String>[];
      final client = clientWithRecorder(rec);
      await client.negotiate(); // 置 _caps

      final id = await client.subscribeResource('res://x');
      expect(id, 's1');
      expect(client.subscribedUris, contains('res://x'));
      expect(rec, contains('resources/subscribe'));
      // 同一 uri 重复订阅幂等（不重复下发）
      await client.subscribeResource('res://x');
      expect(rec.where((m) => m == 'resources/subscribe').length, 1);
    });

    test('unsubscribeResource 下发 resources/unsubscribe + 移除记录', () async {
      final rec = <String>[];
      final client = clientWithRecorder(rec);
      await client.negotiate();
      await client.subscribeResource('res://x');
      expect(client.subscribedUris, contains('res://x'));

      await client.unsubscribeResource('res://x');
      expect(client.subscribedUris, isEmpty);
      expect(rec, contains('resources/unsubscribe'));
    });

    test('server 未声明订阅能力：subscribeResource 抛协议违规', () async {
      final rec = <String>[];
      final client = clientWithRecorder(rec, hasSubs: false);
      await client.negotiate();
      expect(
        () => client.subscribeResource('res://x'),
        throwsA(isA<McpProtocolException>()),
      );
    });

    test('handleServerNotification 仅分发 notifications/resources/updated',
        () async {
      final rec = <String>[];
      final client = clientWithRecorder(rec);
      String? got;
      client.onResourceUpdated = (uri) => got = uri;

      client.handleServerNotification(
        'notifications/resources/updated',
        {'uri': 'res://y'},
      );
      expect(got, 'res://y');

      // 其他通知不触发
      got = null;
      client.handleServerNotification('notifications/tools/list_changed', null);
      expect(got, isNull);
    });

    test('POST-SSE 流内含 notifications/resources/updated 帧 → 分发且返回终帧',
        () async {
      final rec = <String>[];
      final client = McpClient.http(
        baseUrl: 'http://10.0.0.5:8765/mcp',
        httpClient: MockClient((req) async {
          final m = jsonDecode(req.body)['method'] as String;
          rec.add(m);
          if (m == 'tools/call') {
            // SSE 流：先资源变更通知帧，再结果帧（末帧后留空行断帧，尾随
            // keep-alive 注释行确保空行被 LineSplitter 发射）。
            final body = [
              'data: {"jsonrpc":"2.0","method":"notifications/resources/updated","params":{"uri":"res://z"}}',
              '',
              'data: {"jsonrpc":"2.0","id":1,"result":{"ok":true}}',
              '',
              ': keep-alive',
            ].join('\n');
            return http.Response(
              body,
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          }
          return okJson(<String, Object?>{});
        }),
      );

      String? got;
      client.onResourceUpdated = (uri) => got = uri;
      final result = await client.callWithProgress(
        'tools/call',
        params: {'x': 1},
        onProgress: (_) {},
      );
      expect(got, 'res://z'); // 帧内通知已分发
      expect(result, {'ok': true}); // 终帧仍正常返回
    });
  });

  group('T4-5 订阅消费 · McpConnection', () {
    test('subscribe 委托 + onResourceUpdated 转发 + 启动 GET 监听', () async {
      final rec = <String>[];
      final transport = FakeTransport((m, body) {
        rec.add(m);
        switch (m) {
          case 'initialize':
            return _initWithSubs();
          case 'notifications/initialized':
            return fakeNoContent();
          case 'tools/list':
            return fakeOk({'tools': [{'name': 'a'}]});
          case 'resources/subscribe':
            return fakeOk({'subscriptionId': 's1'});
          default:
            return fakeOk(<String, Object?>{});
        }
      });
      final client = McpClient(transport);
      await client.negotiate();
      final conn = McpConnection(
          client: client,
          backoff: noBackoff,
          faceFactory: (c) => McpToolFace(client: c),
        );

      String? got;
      conn.onResourceUpdated = (uri) => got = uri;
      await conn.subscribe('res://x');
      expect(conn.subscribedUris, contains('res://x'));
      expect(rec, contains('resources/subscribe'));
      await _waitFor(() => transport.getCtl.hasListener);
      expect(transport.getCtl.hasListener, isTrue); // GET SSE 监听已启动

      client.handleServerNotification(
        'notifications/resources/updated',
        {'uri': 'res://x'},
      );
      expect(got, 'res://x'); // 经 client → conn 转发
      client.stopNotificationListener();
    });

    test('重连（server 重启）后重放订阅', () async {
      final rec = <String>[];
      final transport = FakeTransport((m, body) {
        rec.add(m);
        switch (m) {
          case 'initialize':
            return _initWithSubs();
          case 'notifications/initialized':
            return fakeNoContent();
          case 'tools/list':
            return fakeOk({'tools': [{'name': 'a'}]});
          case 'resources/subscribe':
            return fakeOk({'subscriptionId': 's1'});
          default:
            return fakeOk(<String, Object?>{});
        }
      });
      final client = McpClient(transport);
      await client.negotiate();
      final conn = McpConnection(
          client: client,
          backoff: noBackoff,
          faceFactory: (c) => McpToolFace(client: c),
        );

      await conn.subscribe('res://a'); // 首次订阅：1 次 resources/subscribe
      expect(rec.where((m) => m == 'resources/subscribe').length, 1);

      // 断连 → 恢复（重连 = 重 negotiate + 重 listTools + 重放订阅）
      await conn.handleHealthState(ConnectionState.offline);
      final report = await conn.handleHealthState(ConnectionState.online);
      expect(report?.success, isTrue);

      // 重放后订阅计数 +1
      expect(rec.where((m) => m == 'resources/subscribe').length, 2);
      expect(conn.subscribedUris, contains('res://a'));
      client.stopNotificationListener();
    });

    test('resourceStaleMessage 为 D19 canonical 文案（不自动重读）', () {
      expect(
        McpConnection.resourceStaleMessage,
        contains('不自动重读'),
      );
    });
  });

  group('T4-5 收官 · GET SSE 订阅监听', () {
    test('GET SSE 下行 notifications/resources/updated → onResourceUpdated + 可停',
        () async {
      final transport = FakeTransport((m, body) {
        switch (m) {
          case 'initialize':
            return _initWithSubs();
          case 'notifications/initialized':
            return fakeNoContent();
          case 'resources/subscribe':
            return fakeOk({'subscriptionId': 's1'});
          default:
            return fakeOk(<String, Object?>{});
        }
      });
      final client = McpClient(transport);
      await client.negotiate();
      final completer = Completer<String>();
      client.onResourceUpdated = (uri) => completer.complete(uri);

      await client.subscribeResource('res://x');
      unawaited(client.startNotificationListener());
      await _waitFor(() => transport.getCtl.hasListener); // 等监听订阅到流
      transport.getCtl
        ..add('data: {"jsonrpc":"2.0","method":"notifications/resources/updated",'
            '"params":{"uri":"res://x"}}')
        ..add('');
      final got = await completer.future.timeout(const Duration(seconds: 2));
      expect(got, 'res://x');
      client.stopNotificationListener();
    });

    test('readResource 读后自动订阅并启动监听 + 推送帧分发', () async {
      final transport = FakeTransport((m, body) {
        switch (m) {
          case 'initialize':
            return _initWithSubs();
          case 'notifications/initialized':
            return fakeNoContent();
          case 'resources/read':
            return fakeOk({'contents': [{'type': 'text', 'text': 'hello'}]});
          case 'resources/subscribe':
            return fakeOk({'subscriptionId': 's1'});
          default:
            return fakeOk(<String, Object?>{});
        }
      });
      final client = McpClient(transport);
      await client.negotiate();

      final text = await client.readResource('res://x');
      expect(text, 'hello');
      expect(client.subscribedUris, contains('res://x'));

      final completer = Completer<String>();
      client.onResourceUpdated = (uri) => completer.complete(uri);
      await _waitFor(() => transport.getCtl.hasListener);
      expect(transport.getCtl.hasListener, isTrue);
      transport.getCtl
        ..add('data: {"jsonrpc":"2.0","method":"notifications/resources/updated",'
            '"params":{"uri":"res://x"}}')
        ..add('');
      final got = await completer.future.timeout(const Duration(seconds: 2));
      expect(got, 'res://x');
      client.stopNotificationListener();
    });

    test('HttpTransport.getStream 返回 SSE 流（GET /mcp）', () async {
      final client = McpClient.http(
        baseUrl: 'http://10.0.0.5:8765/mcp',
        httpClient: MockClient((req) async {
          if (req.method == 'GET') {
            return http.Response(
              'data: {"x":1}\n\n',
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          }
          return okJson(<String, Object?>{});
        }),
      );
      final resp = await client.transport.getStream();
      expect(resp.statusCode, 200);
      expect(resp.contentType, contains('event-stream'));
      final lines = await resp.lines.toList();
      expect(lines, contains('data: {"x":1}'));
    });
  });
}
