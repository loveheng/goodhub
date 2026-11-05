/// AI 调试桥契约回归：鉴权 / 回环绑定 / 结构化端点 / 未配置端口 501 / 释放。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/gateway/debug_bridge.dart';

/// 内存日志源（契约端口化后公共包不再直连宿主 AppLog）。
class _MemoryLogSink implements DebugLogSink {
  final List<DebugLogEntry> _entries = <DebugLogEntry>[];
  int _revision = 0;

  @override
  int get length => _entries.length;

  @override
  int get revision => _revision;

  @override
  List<DebugLogEntry> entries() => List<DebugLogEntry>.unmodifiable(_entries);

  void add(String message, {String level = 'info'}) {
    _entries.add(DebugLogEntry(
        timestamp: DateTime.now(), level: level, message: message));
    _revision++;
  }
}

typedef _Response = ({int status, Map<String, Object?> body});

Future<_Response> _request(
  int port,
  String method,
  String path, {
  String? token,
  Object? body,
}) async {
  final client = HttpClient();
  try {
    final req = await client.open(method, '127.0.0.1', port, path);
    if (token != null) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final resp = await req.close();
    final text = await utf8.decoder.bind(resp).join();
    return (
      status: resp.statusCode,
      body: Map<String, Object?>.from(jsonDecode(text) as Map),
    );
  } finally {
    client.close();
  }
}

Future<DebugBridge> _start({
  DebugStateProvider? stateProvider,
  DebugUiTreeProvider? uiTreeProvider,
  DebugActionHandler? actionHandler,
  DebugResetHandler? resetHandler,
  DebugLogSink? logSink,
}) async {
  final bridge = DebugBridge(
    token: 'test-token',
    logSink: logSink,
    stateProvider: stateProvider,
    uiTreeProvider: uiTreeProvider,
    actionHandler: actionHandler,
    resetHandler: resetHandler,
  );
  await bridge.start(port: 0);
  addTearDown(bridge.stop);
  return bridge;
}

void main() {
  test('恒绑 loopback + 全部端点强制 Bearer', () async {
    final bridge = await _start();
    expect(bridge.running, isTrue);
    expect(bridge.bindAddress?.address, InternetAddress.loopbackIPv4.address,
        reason: '免回环绑定会把调试桥暴露给局域网');

    final noToken = await _request(bridge.port, 'GET', '/debug/state');
    expect(noToken.status, 401);
    expect(noToken.body['error'], 'unauthorized');

    final badToken = await _request(bridge.port, 'GET', '/debug/state',
        token: 'wrong');
    expect(badToken.status, 401);

    final ok = await _request(bridge.port, 'GET', '/debug/state',
        token: 'test-token');
    expect(ok.status, 200);
    expect(ok.body['ok'], isTrue);
    expect(ok.body['endpoints'], kDebugBridgeEndpoints);
  });

  test('未指定 token 时启动期随机生成且可鉴权', () async {
    final bridge = DebugBridge();
    await bridge.start(port: 0);
    addTearDown(bridge.stop);
    final token = bridge.token;
    expect(token.length, greaterThanOrEqualTo(32));
    final r = await _request(bridge.port, 'GET', '/debug/state', token: token);
    expect(r.status, 200);
  });

  test('/debug/logs 返回结构化日志并支持 since 增量游标', () async {
    final sink = _MemoryLogSink();
    final bridge = await _start(logSink: sink);
    sink.add('probe-alpha');
    sink.add('probe-beta', level: 'warning');

    final all = await _request(bridge.port, 'GET', '/debug/logs',
        token: 'test-token');
    expect(all.status, 200);
    expect(all.body['total'], 2);
    expect(all.body['since'], 0);
    final entries = all.body['entries']! as List;
    expect(entries, hasLength(2));
    final first = entries.first as Map;
    expect(first['level'], 'info');
    expect(first['message'], 'probe-alpha');
    expect(first['at'], isA<String>());
    expect((entries.last as Map)['level'], 'warning');

    final tail = await _request(bridge.port, 'GET', '/debug/logs?since=1',
        token: 'test-token');
    expect((tail.body['entries']! as List).single is Map, isTrue);
    expect((tail.body['entries']! as List).single as Map,
        containsPair('message', 'probe-beta'));
  });

  test('/debug/state 回显内置元信息并合并注入端口', () async {
    final bridge = await _start(
      logSink: _MemoryLogSink(),
      stateProvider: () => <String, Object?>{'route': 'settings'},
    );
    final r = await _request(bridge.port, 'GET', '/debug/state',
        token: 'test-token');
    expect(r.body['buildMode'], 'debug');
    expect(r.body['logEntries'], 0);
    expect((r.body['app']! as Map)['route'], 'settings');
  });

  test('/debug/ui-tree 未注入 501、注入后原样透传节点', () async {
    final bare = await _start();
    final miss = await _request(bare.port, 'GET', '/debug/ui-tree',
        token: 'test-token');
    expect(miss.status, 501);
    expect(miss.body['port'], 'uiTreeProvider');

    final wired = await _start(
      uiTreeProvider: () => <Map<String, Object?>>[
        <String, Object?>{'key': 'send', 'bounds': <double>[1, 2, 3, 4]},
      ],
    );
    final ok = await _request(wired.port, 'GET', '/debug/ui-tree',
        token: 'test-token');
    expect(ok.status, 200);
    expect((ok.body['nodes']! as List).single as Map,
        containsPair('key', 'send'));
  });

  test('/debug/action 未注入 501、注入后收 action+args 并回结果', () async {
    final bare = await _start();
    final miss = await _request(bare.port, 'POST', '/debug/action',
        token: 'test-token', body: <String, Object?>{'action': 'tap'});
    expect(miss.status, 501);
    expect(miss.body['port'], 'actionHandler');

    String? seenAction;
    Map<String, Object?> seenArgs = <String, Object?>{};
    final wired = await _start(
      actionHandler: (action, args) async {
        seenAction = action;
        seenArgs = args;
        return <String, Object?>{'tapped': true};
      },
    );
    final ok = await _request(wired.port, 'POST', '/debug/action',
        token: 'test-token',
        body: <String, Object?>{
          'action': 'tap_node',
          'args': <String, Object?>{'key': 'send'},
        });
    expect(ok.status, 200);
    expect(seenAction, 'tap_node');
    expect(seenArgs['key'], 'send');
    expect((ok.body['result']! as Map)['tapped'], isTrue);

    final bad = await _request(wired.port, 'POST', '/debug/action',
        token: 'test-token', body: <String, Object?>{'args': <String, Object?>{}});
    expect(bad.status, 400);
    expect(bad.body['error'], 'missing_action');
  });

  test('/debug/reset 未注入 501、注入后才执行', () async {
    final bare = await _start();
    final miss = await _request(bare.port, 'POST', '/debug/reset',
        token: 'test-token');
    expect(miss.status, 501);

    var calls = 0;
    final wired = await _start(resetHandler: () async => calls++);
    final ok = await _request(wired.port, 'POST', '/debug/reset',
        token: 'test-token');
    expect(ok.status, 200);
    expect(calls, 1);
  });

  test('未知路径 404 / 方法不匹配 405 / 坏 JSON 400', () async {
    final bridge = await _start(
      actionHandler: (action, args) async => null,
    );
    final notFound = await _request(bridge.port, 'GET', '/debug/nope',
        token: 'test-token');
    expect(notFound.status, 404);
    final wrongMethod = await _request(bridge.port, 'POST', '/debug/state',
        token: 'test-token');
    expect(wrongMethod.status, 405);
    final badJson = await _request(bridge.port, 'POST', '/debug/action',
        token: 'test-token');
    expect(badJson.status, 400);
    expect(badJson.body['error'], 'invalid_json');
  });

  test('stop 释放监听', () async {
    final bridge = DebugBridge(token: 'test-token');
    await bridge.start(port: 0);
    expect(bridge.running, isTrue);
    await bridge.stop();
    expect(bridge.running, isFalse);
  });
}
