import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/core/network/backoff.dart';
import 'package:goodhub/mcp/connection_health.dart';
import 'package:goodhub/mcp/connection_manager.dart';
import 'package:goodhub/mcp/mcp_client.dart';
import 'package:goodhub/coordinator/agent_loop.dart';
import 'package:goodhub/coordinator/mcp_tool_face.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 可变 tools/list 载体：模拟「server 重启后工具集变化」。
class _ToolsBox {
  _ToolsBox(this.value);
  List<Map<String, Object?>> value;
}

void main() {
  http.Response okJson(Object? result) => http.Response(
        jsonEncode({'jsonrpc': '2.0', 'id': 1, 'result': result}),
        200,
        headers: {'content-type': 'application/json'},
      );

  McpClient clientFor(_ToolsBox tools, {void Function()? onList}) =>
      McpClient.http(
        baseUrl: 'http://10.0.0.5:8765/mcp',
        httpClient: MockClient((req) async {
          final b = jsonDecode(req.body);
          final m = b['method'];
          if (m == 'initialize') {
            return okJson({
              'protocolVersion': '2025-06-18',
              'capabilities': <String, Object?>{},
            });
          }
          if (m == 'tools/list') {
            onList?.call();
            return okJson({'tools': tools.value});
          }
          if (m == 'notifications/initialized' ||
              m == 'notifications/cancelled') {
            return http.Response('', 202);
          }
          return okJson(<String, Object?>{});
        }),
      );

  /// 协商必失败的 client（模拟 server 失联/重启），供重连失败路径测试。
  McpClient failingClient() => McpClient.http(
        baseUrl: 'http://10.0.0.5:8765/mcp',
        httpClient: MockClient((req) async {
          final m = jsonDecode(req.body)['method'];
          if (m == 'initialize') {
            return http.Response(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': 1,
                'error': {'code': -32000, 'message': 'down'},
              }),
              200,
            );
          }
          return okJson({'tools': []});
        }),
      );

  const noBackoff = ExponentialBackoff(jitter: 0, initial: Duration.zero);

  group('D17 差分清洗', () {
    test('重连后 listTools 与原激活集交集：下线工具剔除并回调', () async {
      final tools = _ToolsBox([
        {'name': 'a'},
        {'name': 'b'},
        {'name': 'c'},
      ]);
      final conn = McpConnection(
        client: clientFor(tools),
        backoff: noBackoff,
      );
      conn.markActivated({'a', 'b', 'c'});

      List<String>? dropped;
      List<String>? kept;
      conn.onActivationChanged = (d, k) {
        dropped = d;
        kept = k;
      };

      // server 重启：c 被废弃
      tools.value = [
        {'name': 'a'},
        {'name': 'b'},
      ];
      final report = await conn.reconnect();

      expect(report.success, isTrue);
      expect(report.droppedTools, ['c']);
      expect(dropped, ['c']);
      expect(conn.activatedToolNames, {'a', 'b'});
      expect(kept, {'a', 'b'});
    });

    test('工具集不变：不触发 onActivationChanged、激活集保留', () async {
      final tools = _ToolsBox([
        {'name': 'a'},
        {'name': 'b'},
      ]);
      final conn = McpConnection(
        client: clientFor(tools),
        backoff: noBackoff,
      );
      conn.markActivated({'a', 'b'});

      var changedCalls = 0;
      conn.onActivationChanged = (d, k) => changedCalls++;

      final report = await conn.reconnect();
      expect(report.success, isTrue);
      expect(report.droppedTools, isEmpty);
      expect(changedCalls, 0);
      expect(conn.activatedToolNames, {'a', 'b'});
    });

    test('未激活过任何工具：重连后无 dropped、激活集仍空', () async {
      final tools = _ToolsBox([
        {'name': 'a'},
        {'name': 'b'},
      ]);
      final conn = McpConnection(
        client: clientFor(tools),
        backoff: noBackoff,
      );
      final report = await conn.reconnect();
      expect(report.success, isTrue);
      expect(report.droppedTools, isEmpty);
      expect(conn.activatedToolNames, isEmpty);
    });

    test('协商失败：reconnect 返回 success=false、激活集不动', () async {
      final tools = _ToolsBox([
        {'name': 'a'},
        {'name': 'b'},
      ]);
      final conn = McpConnection(
        client: McpClient.http(
          baseUrl: 'http://10.0.0.5:8765/mcp',
          httpClient: MockClient((req) async {
            final m = jsonDecode(req.body)['method'];
            if (m == 'initialize') {
              return http.Response(
                jsonEncode({
                  'jsonrpc': '2.0',
                  'id': 1,
                  'error': {'code': -32000, 'message': 'boom'},
                }),
                200,
              );
            }
            return okJson({'tools': tools.value});
          }),
        ),
        backoff: noBackoff,
      );
      conn.markActivated({'a', 'b'});
      final report = await conn.reconnect();
      expect(report.success, isFalse);
      expect(report.error, isNotNull);
      expect(conn.activatedToolNames, {'a', 'b'});
    });
  });

  group('D18 断连处置', () {
    test('转 offline：取消在途 + 回告在途数量', () async {
      // 假 Face：模拟 2 个在途、可取消
      final fakeClient =
          McpClient.http(baseUrl: 'http://10.0.0.5:8765/mcp');
      final face = _FakeFace(fakeClient, inFlight: 2);
      final conn = McpConnection(
        client: fakeClient,
        face: face,
        backoff: noBackoff,
      );

      DisconnectReport? rep;
      conn.onDisconnectReport = (r) => rep = r;

      await conn.handleHealthState(ConnectionState.offline);

      expect(face.cancelled, isTrue);
      expect(rep, isNotNull);
      expect(rep!.inFlightCancelled, 2);
    });

    test('首探 online 不重连（_wasOffline=false，不触发 tools/list）', () async {
      final tools = _ToolsBox([
        {'name': 'a'},
      ]);
      var listCalls = 0;
      final conn = McpConnection(
        client: clientFor(tools, onList: () => listCalls++),
        backoff: noBackoff,
      );
      conn.markActivated({'a'});

      final report = await conn.handleHealthState(ConnectionState.online);
      expect(report, isNull); // 未重连
      expect(listCalls, 0);
    });
  });

  group('D16 / D17 集成：offline→online 自动重连', () {
    test('先 offline（D18）再 online（自动重连 + 差分清洗）', () async {
      final tools = _ToolsBox([
        {'name': 'a'},
        {'name': 'b'},
        {'name': 'c'},
      ]);
      final conn = McpConnection(
        client: clientFor(tools),
        backoff: noBackoff,
      );
      conn.markActivated({'a', 'b', 'c'});

      DisconnectReport? disc;
      conn.onDisconnectReport = (r) => disc = r;
      List<String>? dropped;
      conn.onActivationChanged = (d, _) => dropped = d;

      await conn.handleHealthState(ConnectionState.offline);
      expect(disc, isNotNull);

      // 远端重启：c 下线
      tools.value = [
        {'name': 'a'},
        {'name': 'b'},
      ];

      final report = await conn.handleHealthState(ConnectionState.online);
      expect(report?.success, isTrue);
      expect(dropped, ['c']);
      expect(conn.activatedToolNames, {'a', 'b'});
    });

    test('连续重连失败可控：每 offline→online 触发一次重连、失败返回 false 不抛', () async {
      // 每次重连协商都失败 → reconnect 返回 false；多次断连周期可重试、不卡死。
      final conn = McpConnection(
        client: McpClient.http(
          baseUrl: 'http://10.0.0.5:8765/mcp',
          httpClient: MockClient((req) async {
            final m = jsonDecode(req.body)['method'];
            if (m == 'initialize') {
              return http.Response(
                jsonEncode({
                  'jsonrpc': '2.0',
                  'id': 1,
                  'error': {'code': -32000, 'message': 'down'},
                }),
                200,
              );
            }
            return okJson({'tools': []});
          }),
        ),
        backoff: const ExponentialBackoff(jitter: 0, maxAttempts: 3),
      );
      conn.markActivated({'a'});

      await conn.handleHealthState(ConnectionState.offline);
      final r1 = await conn.handleHealthState(ConnectionState.online);
      expect(r1?.success, isFalse);

      // 第二个断连周期再次重连仍失败，不抛、不卡死（验证可重试且失败可控）。
      await conn.handleHealthState(ConnectionState.offline);
      final r2 = await conn.handleHealthState(ConnectionState.online);
      expect(r2?.success, isFalse);
    });
  });

  group('T4-4 积压丢弃回告', () {
    test('offline 窗口 guardExecute 丢弃积压 + 计数，不执行 run', () async {
      final fakeClient = McpClient.http(baseUrl: 'http://x/mcp');
      final conn = McpConnection(
        client: fakeClient,
        face: _FakeFace(fakeClient),
        backoff: noBackoff,
      );
      await conn.handleHealthState(ConnectionState.offline);
      expect(conn.isOffline, isTrue);

      var ran = 0;
      final r = await conn.guardExecute(() async {
        ran++;
        return ToolExecutionResult(content: 'ok');
      });
      expect(r.isError, isTrue);
      expect(r.content, contains('积压'));
      expect(ran, 0); // run 未被调用
      expect(conn.droppedBacklog, 1);
    });

    test('online 窗口 guardExecute 透传 run', () async {
      final fakeClient = McpClient.http(baseUrl: 'http://x/mcp');
      final conn = McpConnection(
        client: fakeClient,
        face: _FakeFace(fakeClient),
        backoff: noBackoff,
      );
      var ran = 0;
      final r = await conn.guardExecute(() async {
        ran++;
        return ToolExecutionResult(content: 'ok');
      });
      expect(ran, 1);
      expect(r.isError, isFalse);
      expect(conn.droppedBacklog, 0);
    });

    test('恢复成功回告积压数并清零', () async {
      final tools = _ToolsBox([
        {'name': 'a'},
      ]);
      final conn = McpConnection(client: clientFor(tools), backoff: noBackoff);

      await conn.handleHealthState(ConnectionState.offline);
      conn.noteBacklogDropped(n: 3);
      expect(conn.droppedBacklog, 3);

      BacklogReport? rep;
      conn.onBacklogReport = (r) => rep = r;
      final report = await conn.handleHealthState(ConnectionState.online);
      expect(report?.success, isTrue);
      expect(rep?.droppedCount, 3);
      expect(conn.droppedBacklog, 0); // 回告后清零
    });

    test('无积压的恢复不回告', () async {
      final tools = _ToolsBox([
        {'name': 'a'},
      ]);
      final conn = McpConnection(client: clientFor(tools), backoff: noBackoff);
      await conn.handleHealthState(ConnectionState.offline);
      // 无 noteBacklogDropped

      BacklogReport? rep;
      conn.onBacklogReport = (r) => rep = r;
      await conn.handleHealthState(ConnectionState.online);
      expect(rep, isNull);
    });

    test('重连失败不回告、积压跨窗口累计保留', () async {
      final conn = McpConnection(
        client: failingClient(),
        backoff: const ExponentialBackoff(jitter: 0, maxAttempts: 3),
      );
      BacklogReport? rep;
      conn.onBacklogReport = (r) => rep = r;

      // 第一个断连窗口丢弃 2
      await conn.handleHealthState(ConnectionState.offline);
      conn.noteBacklogDropped(n: 2);
      final r1 = await conn.handleHealthState(ConnectionState.online);
      expect(r1?.success, isFalse);
      expect(rep, isNull); // 重连失败，不回告
      expect(conn.droppedBacklog, 2); // 保留累计

      // 第二个断连窗口再丢 1，重连仍失败
      await conn.handleHealthState(ConnectionState.offline);
      conn.noteBacklogDropped(n: 1);
      expect(conn.droppedBacklog, 3);
      final r2 = await conn.handleHealthState(ConnectionState.online);
      expect(r2?.success, isFalse);
      expect(rep, isNull);
      expect(conn.droppedBacklog, 3);
    });
  });
}

/// 假 Face：覆盖在途计数与取消，验证 D18 断连回告链路不依赖真实网络。
class _FakeFace extends McpToolFace {
  _FakeFace(McpClient client, {this.inFlight = 0}) : super(client: client);

  final int inFlight;
  var cancelled = false;

  @override
  int get inFlightCount => inFlight;

  @override
  void cancelActiveRequest({String? reason}) => cancelled = true;
}
