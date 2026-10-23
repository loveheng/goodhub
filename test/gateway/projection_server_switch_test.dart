/// 私有服务「列举 → 切到单个」链路单测（用户裁决 2026-10-23）。
///
/// 覆盖两个网关系统工具：`gateway__list_servers`（列全部已挂载 MCP 服务）
/// 与 `gateway__select_private(policy=single|private|full)`（连接级切换；
/// 旧参数 `scope=` 为兼容别名，不进 schema）。
/// **安全断言重点**：切换只改本连接投影，宿主槽位与其他连接零影响。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/mcp_tool_face.dart';
import 'package:goodhub/gateway/gateway_server.dart';
import 'package:goodhub/gateway/mcp_gateway_handler.dart';
import 'package:goodhub/gateway/projection_pipeline.dart';
import 'package:goodhub/mcp/mcp_client.dart';
import 'package:goodhub/mcp/transport/mcp_transport.dart';

class _FakeTransport implements McpTransport {
  @override
  Future<TransportResponse> send(String requestBody) async {
    final req = jsonDecode(requestBody) as Map<String, Object?>;
    final method = req['method'];
    final params = req['params'];
    final result = method == 'tools/list'
        ? {
            'tools': [
              {
                'name': 'echo',
                'description': 'd',
                'inputSchema': {'type': 'object'},
                '_meta': {
                  'goodhub': {'visibility': 'shared'}
                },
              }
            ]
          }
        : {
            'content': [
              {
                'type': 'text',
                'text': 'echo:${params is Map ? params['name'] : ''}'
              }
            ]
          };
    return TransportResponse(
      statusCode: 200,
      contentType: 'application/json',
      body: jsonEncode({'jsonrpc': '2.0', 'id': req['id'], 'result': result}),
    );
  }

  @override
  Future<StreamedTransportResponse> sendStream(String requestBody) async {
    final req = jsonDecode(requestBody) as Map<String, Object?>;
    return StreamedTransportResponse(
      statusCode: 200,
      contentType: 'application/json',
      lines: Stream<String>.fromIterable([jsonEncode({
        'jsonrpc': '2.0',
        'id': req['id'],
        'result': {
          'content': [
            {'type': 'text', 'text': 'echo'}
          ]
        }
      })]),
    );
  }

  @override
  Future<StreamedTransportResponse> getStream() =>
      throw UnsupportedError('假传输无 GET SSE');

  @override
  void close() {}
}

Future<McpToolFace> _face(String id) async {
  final f = McpToolFace(client: McpClient(_FakeTransport()), serverId: id);
  await f.listTools();
  return f;
}

Future<(McpGatewayServer, String)> _start() async {
  final handler = GatewayHandler(
    faces: {
      'pubA': await _face('pubA'),
      'pubB': await _face('pubB'),
      'privA': await _face('privA'),
      'privB': await _face('privB'),
    },
    privateServerIds: {'privA', 'privB'},
  );
  final server = McpGatewayServer(handler);
  await server.start(address: InternetAddress.loopbackIPv4, port: 0);
  return (server, 'http://127.0.0.1:${server.port}/mcp');
}

Future<HttpClientResponse> _post(HttpClient c, String url, String body,
    {String? sessionId}) async {
  final req = await c.postUrl(Uri.parse(url));
  req.headers.set(HttpHeaders.acceptHeader, 'application/json');
  req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
  if (sessionId != null) req.headers.set('Mcp-Session-Id', sessionId);
  req.write(body);
  return req.close();
}

Future<Map<String, Object?>> _body(HttpClientResponse r) async =>
    jsonDecode(await r.transform(utf8.decoder).join()) as Map<String, Object?>;

Future<String> _init(HttpClient c, String base, [String? q]) async {
  final r = await _post(c, q == null ? base : '$base?$q',
      jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize'}));
  return r.headers.value('mcp-session-id')!;
}

Future<Map<String, Object?>> _call(
        HttpClient c, String base, String sid, String tool,
        [Map<String, Object?> args = const {}]) async =>
    _body(await _post(
        c, base,
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 9,
          'method': 'tools/call',
          'params': {'name': tool, 'arguments': args}
        }),
        sessionId: sid));

Future<List<String>> _names(HttpClient c, String base, String sid) async {
  final b = await _body(await _post(
      c, base,
      jsonEncode({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'}),
      sessionId: sid));
  final tools = ((b['result'] as Map)['tools']) as List;
  return [for (final t in tools) (t as Map)['name'] as String];
}

void main() {
  test('系统工具文案零悬空引用（禁引用未声明的 gateway__ 工具名）', () {
    final declared = {
      for (final t in GatewayHandler.systemToolJson) t['name'] as String,
    };
    final texts = <String>[];
    void walk(Object? v) {
      if (v is String) {
        texts.add(v);
      } else if (v is Map) {
        v.forEach((_, e) => walk(e));
      } else if (v is List) {
        v.forEach(walk);
      }
    }

    walk(GatewayHandler.systemToolJson);
    final referenced = <String>{};
    for (final t in texts) {
      for (final m in RegExp(r'gateway__[a-z_]+').allMatches(t)) {
        referenced.add(m.group(0)!);
      }
    }
    expect(referenced.difference(declared), isEmpty,
        reason: '系统工具文案引用了未声明的工具名——PC 侧模型会照抄调用'
            '不存在的工具（2026-10-23 术语纠错后的现名 = '
            '${GatewayHandler.kGatewayListServers}）');
    expect(texts.join('\n'), isNot(contains('gateway__list_private_servers')),
        reason: '旧名不得残留在面向 PC 的文案里');
    // 词表层防漂移（D1 单轴化收尾）：面向 PC 的文案只许出现现行键 `policy=`，
    // 旧键 `strategy=` / 旧参数 `scope=` 是兼容别名、不进 PC 可见面——
    // 文案照抄旧词表会让 PC 侧模型沿用已退役拼写（与旧工具名残留同源）。
    final joined = texts.join('\n');
    expect(joined, isNot(contains('strategy=')),
        reason: '面向 PC 的文案禁引用旧 URL 键 strategy=（现行键 = policy=）');
    expect(joined, isNot(contains('scope=')),
        reason: '面向 PC 的文案禁引用旧参数名 scope=（现行参数 = policy）');
  });

  test('single 拒绝话术不用旧词表（strategy=/scope= 残留即红）', () async {
    final handler = GatewayHandler(
      faces: {'pubA': await _face('pubA')},
      policy: ProjectionPolicy.single('pubA'),
    );
    final r = await handler.toolsCall(
      name: GatewayHandler.kGatewayListServers,
      arguments: const {},
      onProgress: (_) {},
    );
    expect(r.isError, isTrue);
    expect(r.content, isNot(contains('strategy=')),
        reason: '运行时拒绝话术禁引用旧 URL 键（PC 会照抄重连）');
    expect(r.content, isNot(contains('scope=')),
        reason: '运行时拒绝话术禁引用旧参数名');
    expect(r.content, contains('gateway__select_private'),
        reason: 'single 下必须给同连接退出通道（无需重连）');
    expect(r.content, contains('policy=full'));
    // 切换回执（describeGatewayProjection）同样只许现行词表。
    final switched = await handler.toolsCall(
      name: GatewayHandler.kGatewaySelectPrivate,
      arguments: const {'server_id': 'pubA', 'policy': 'single'},
      onProgress: (_) {},
    );
    expect(switched.isError, isFalse);
    expect(switched.content, contains('policy=full'),
        reason: 'single 回执须指引现行退出参数');
    expect(switched.content, isNot(contains('scope=')),
        reason: 'single 回执禁引用旧参数名');
  });

  test('拒绝话术指向现名工具（旧名残留会让 PC 侧幻觉调用）', () async {
    final handler = GatewayHandler(faces: {});
    final r = await handler.toolsCall(
      name: GatewayHandler.kGatewaySelectPrivate,
      arguments: const {'server_id': 'nope'},
      onProgress: (_) {},
    );
    expect(r.isError, isTrue);
    expect(r.content, contains(GatewayHandler.kGatewayListServers));
    expect(r.content, isNot(contains('gateway__list_private_servers')),
        reason: '旧名 gateway__list_private_servers 已不存在（术语纠错后改名）');
  });

  test('被信任闸门拦下的插件进 blocked 段（区分「没装」与「没信任」）', () async {
    final privA = await _face('privA');
    final handler = GatewayHandler(
      faces: {'privA': privA},
      privateServerIds: {'privA'},
      blockedPlugins: const {
        'goodshare': '未信任的第三方插件：请先在宿主聊天页或 ⚙ 设置 → 本地插件中信任一次',
        'shiguang': '未信任的第三方插件：请先在宿主聊天页或 ⚙ 设置 → 本地插件中信任一次',
      },
    );
    final r = await handler.toolsCall(
      name: GatewayHandler.kGatewayListServers,
      arguments: const {},
      onProgress: (_) {},
    );
    expect(r.isError, isFalse);
    final payload = jsonDecode(r.content) as Map<String, Object?>;
    expect([for (final b in payload['blocked'] as List) (b as Map)['server_id']],
        ['goodshare', 'shiguang'],
        reason: '已安装未信任的插件必须可诊断，否则 PC 会误判「宿主没装」');
    for (final b in (payload['blocked'] as List).cast<Map<String, Object?>>()) {
      expect(b['reason'], contains('信任'));
      expect(b.containsKey('packageName'), isFalse, reason: '不透包名');
      expect(b.containsKey('signature'), isFalse, reason: '不透签名');
    }
    expect(payload['blocked_hint'], contains('信任'));
  });

  test('列举工具列出**全部已挂载服务**（含 public / 本地插件），逐条标 tier',
      () async {
    final (server, base) = await _start();
    final c = HttpClient();
    try {
      final sid = await _init(c, base);
      final names = await _names(c, base, sid);
      expect(names, contains(GatewayHandler.kGatewayListServers));
      expect(names, contains(GatewayHandler.kGatewaySelectPrivate));

      final r = await _call(c, base, sid, GatewayHandler.kGatewayListServers);
      expect((r['result'] as Map)['isError'], isFalse);
      final content = ((r['result'] as Map)['content'] as List).single as Map;
      expect(content['type'], 'text');
      final data = jsonDecode(content['text'] as String) as Map<String, Object?>;
      final servers = (data['servers'] as List).cast<Map<String, Object?>>();
      expect(servers, hasLength(4), reason: '列全部已挂载服务，不只列私有');
      expect([for (final s in servers) s['server_id']],
          ['privA', 'privB', 'pubA', 'pubB'], reason: '按 id 排序');
      final byId = {for (final s in servers) s['server_id'] as String: s};
      expect(byId['privA']!['tier'], 'private');
      expect(byId['privA']!['source'], 'endpoint-private');
      expect(byId['pubA']!['tier'], 'public');
      expect(byId['pubB']!['source'], 'public',
          reason: '本地插件恒 public（系统托管常驻曝光）——不因「用户口语的私有」缺席');
      for (final s in servers) {
        expect(s['shared_tools'], 1);
        expect(s.containsKey('serverName'), isFalse,
            reason: '不回服务自报名（可能含用户自定义命名）');
        expect(s.containsKey('endpoint'), isFalse, reason: '不回端点/凭据');
      }
      expect(data['policy'], 'full');
    } finally {
      c.close(force: true);
      await server.stop();
    }
  });

  test('public 服务也能被列出并切进 single（用户诉求：不必先改端点隐私级别）',
      () async {
    final (server, base) = await _start();
    final c = HttpClient();
    try {
      final sid = await _init(c, base);
      final r = await _call(c, base, sid, GatewayHandler.kGatewayListServers);
      final content = ((r['result'] as Map)['content'] as List).single as Map;
      final data = jsonDecode(content['text'] as String) as Map<String, Object?>;
      final ids = [for (final s in data['servers'] as List) (s as Map)['server_id']];
      expect(ids, contains('pubA'), reason: 'public 服务在清单里可见可切');

      final switched = await _call(
          c, base, sid, GatewayHandler.kGatewaySelectPrivate,
          {'server_id': 'pubA', 'scope': 'single'});
      expect((switched['result'] as Map)['isError'], isFalse);
      final names = await _names(c, base, sid);
      expect(names,
          containsAll(['echo', GatewayHandler.kGatewaySelectPrivate]));
      expect(names, hasLength(2), reason: '目录只剩 pubA 的裸名工具 + 出口工具');
    } finally {
      c.close(force: true);
      await server.stop();
    }
  });

  test('列举 → 切 single → 目录只剩该私有服务的无前缀工具，且可实调', () async {
    final (server, base) = await _start();
    final c = HttpClient();
    try {
      final sid = await _init(c, base);
      final switched = await _call(
          c, base, sid, GatewayHandler.kGatewaySelectPrivate,
          {'server_id': 'privB', 'scope': 'single'});
      expect((switched['result'] as Map)['isError'], isFalse);

      final names = await _names(c, base, sid);
      expect(names, ['echo', GatewayHandler.kGatewaySelectPrivate],
          reason: 'single 只留目标服务的裸名工具 + 唯一出口工具，'
              '公共面/其余私有/列举工具全隐匿');

      final called = await _call(c, base, sid, 'echo');
      expect((called['result'] as Map)['isError'], isFalse,
          reason: '无前缀调用经服务端补齐后直达');
    } finally {
      c.close(force: true);
      await server.stop();
    }
  });

  test('scope=single 后可用 scope=full 回到完整联邦面（单向易收）', () async {
    final (server, base) = await _start();
    final c = HttpClient();
    try {
      final sid = await _init(c, base);
      await _call(c, base, sid, GatewayHandler.kGatewaySelectPrivate,
          {'server_id': 'privA', 'scope': 'single'});
      expect(await _names(c, base, sid),
          ['echo', GatewayHandler.kGatewaySelectPrivate]);

      final back = await _call(c, base, sid, GatewayHandler.kGatewaySelectPrivate,
          {'server_id': 'all', 'scope': 'full'});
      expect((back['result'] as Map)['isError'], isFalse);
      final names = await _names(c, base, sid);
      expect(names, contains('pubA__echo'));
      expect(names, contains('pubB__echo'));
      expect(names, contains(GatewayHandler.kGatewaySelectPrivate),
          reason: '回到 full 则控制面工具复现');
    } finally {
      c.close(force: true);
      await server.stop();
    }
  });

  test('连接级隔离：A 切 single 不影响同宿主另一连接 B 与宿主默认投影', () async {
    final (server, base) = await _start();
    final c = HttpClient();
    try {
      final sidA = await _init(c, base);
      final sidB = await _init(c, base);
      await _call(c, base, sidA, GatewayHandler.kGatewaySelectPrivate,
          {'server_id': 'privA', 'scope': 'single'});

      expect(await _names(c, base, sidA),
          ['echo', GatewayHandler.kGatewaySelectPrivate]);
      final namesB = await _names(c, base, sidB);
      expect(namesB, contains('pubA__echo'),
          reason: 'B 连接投影零污染');
      expect(namesB, isNot(contains('privA__echo')),
          reason: 'A 的连接级私有绑定不得外溢到 B');
    } finally {
      c.close(force: true);
      await server.stop();
    }
  });

  test('scope=private（缺省，既有行为）：联邦面 + 该私有服务工具', () async {
    final (server, base) = await _start();
    final c = HttpClient();
    try {
      final sid = await _init(c, base);
      final r = await _call(c, base, sid, GatewayHandler.kGatewaySelectPrivate,
          {'server_id': 'privA'});
      expect((r['result'] as Map)['isError'], isFalse);
      final names = await _names(c, base, sid);
      expect(names, contains('privA__echo'));
      expect(names, contains('pubA__echo'));
      expect(names, isNot(contains('privB__echo')));
    } finally {
      c.close(force: true);
      await server.stop();
    }
  });

  test('拒绝路径：未挂载目标 / 非私有目标走 scope=private / 非法 scope / single+all',
      () async {
    final (server, base) = await _start();
    final c = HttpClient();
    try {
      final sid = await _init(c, base);
      Future<bool> fails(Map<String, Object?> a) async =>
          ((await _call(c, base, sid,
              GatewayHandler.kGatewaySelectPrivate, a))['result']
              as Map)['isError'] ==
          true;

      expect(await fails({'server_id': 'ghost'}), isTrue, reason: '未挂载');
      expect(
          await fails({'server_id': 'pubA'}), isTrue,
          reason: 'scope=private 仅限私有服务');
      expect(await fails({'server_id': 'privA', 'scope': 'narrow'}), isTrue);
      expect(
          await fails({'server_id': 'all', 'scope': 'single'}), isTrue,
          reason: 'scope=single 必须指定具体服务');
      // 非私有服务走 scope=single 是合法的（single 是通用收敛语义）
      expect(
          await fails({'server_id': 'pubA', 'scope': 'single'}), isFalse);
    } finally {
      c.close(force: true);
      await server.stop();
    }
  });

  test('single 下控制面工具零泄漏（不列出 + 调用被拒）', () async {
    final (server, base) = await _start();
    final c = HttpClient();
    try {
      final sid = await _init(c, base, 'strategy=single&server=privA');
      final names = await _names(c, base, sid);
      expect(names, isNot(contains(GatewayHandler.kGatewayListServers)),
          reason: 'single 下无需再选服务，列举工具隐匿');
      expect(names, contains(GatewayHandler.kGatewaySelectPrivate),
          reason: '出口工具必须保留，否则切进 single 后回不来 = 死锁');
      final r = await _call(c, base, sid, GatewayHandler.kGatewayListServers);
      expect((r['result'] as Map)['isError'], isTrue,
          reason: 'single 下非出口控制面工具显式拒绝');
    } finally {
      c.close(force: true);
      await server.stop();
    }
  });
  group('单轴化：policy 为主名 / scope 为兼容别名（2026-10-23 裁决 D1）', () {
    test('policy=single → 目录只剩该服务裸名工具（剥前缀）', () async {
      final pubB = await _face('pubB');
      final handler = GatewayHandler(faces: {'pubB': pubB});
      final r = await handler.toolsCall(
        name: GatewayHandler.kGatewaySelectPrivate,
        arguments: const {'server_id': 'pubB', 'policy': 'single'},
        onProgress: (_) {},
      );
      expect(r.isError, isFalse);
      final names = handler.toolsList().map((t) => t['name']).toList();
      expect(names, contains('echo'));
      expect(names, isNot(contains('pubB__echo')));
    });

    test('policy=private → 联邦面 + 该私有服务（私有叠加）', () async {
      final privA = await _face('privA');
      final pubB = await _face('pubB');
      final handler = GatewayHandler(
        faces: {'privA': privA, 'pubB': pubB},
        privateServerIds: {'privA'},
      );
      final r = await handler.toolsCall(
        name: GatewayHandler.kGatewaySelectPrivate,
        arguments: const {'server_id': 'privA', 'policy': 'private'},
        onProgress: (_) {},
      );
      expect(r.isError, isFalse);
      final names = handler.toolsList().map((t) => t['name']).toList();
      expect(names, contains('privA__echo'),
          reason: 'private 档 = 联邦面 + 该私有服务');
      expect(names, contains('pubB__echo'));
    });

    test('policy=full → 联邦面且私有叠加清空', () async {
      final privA = await _face('privA');
      final pubB = await _face('pubB');
      final handler = GatewayHandler(
        faces: {'privA': privA, 'pubB': pubB},
        privateServerIds: {'privA'},
      );
      await handler.toolsCall(
        name: GatewayHandler.kGatewaySelectPrivate,
        arguments: const {'server_id': 'privA', 'policy': 'private'},
        onProgress: (_) {},
      );
      final r = await handler.toolsCall(
        name: GatewayHandler.kGatewaySelectPrivate,
        arguments: const {'server_id': 'all', 'policy': 'full'},
        onProgress: (_) {},
      );
      expect(r.isError, isFalse);
      final names = handler.toolsList().map((t) => t['name']).toList();
      expect(names, contains('pubB__echo'));
      expect(names, isNot(contains('privA__echo')),
          reason: 'full 档 = 联邦面，私有叠加已清空');
    });

    test('policy=pruned → 拒绝（连接内无 tag 来源，仅建立期可用）', () async {
      final pubB = await _face('pubB');
      final handler = GatewayHandler(faces: {'pubB': pubB});
      final r = await handler.toolsCall(
        name: GatewayHandler.kGatewaySelectPrivate,
        arguments: const {'server_id': 'pubB', 'policy': 'pruned'},
        onProgress: (_) {},
      );
      expect(r.isError, isTrue);
      expect(r.content, contains('连接建立期'),
          reason: '拒绝话术须指向可自纠路径（改用 policy=single）');
    });

    test('旧参数 scope= 仍生效（兼容别名，既有客户端零改动）', () async {
      final pubB = await _face('pubB');
      final handler = GatewayHandler(faces: {'pubB': pubB});
      final r = await handler.toolsCall(
        name: GatewayHandler.kGatewaySelectPrivate,
        arguments: const {'server_id': 'pubB', 'scope': 'single'},
        onProgress: (_) {},
      );
      expect(r.isError, isFalse);
      final names = handler.toolsList().map((t) => t['name']).toList();
      expect(names, contains('echo'));
      expect(names, isNot(contains('pubB__echo')));
    });

    test('scope=pruned → 拒绝（与 policy=pruned 同口径）', () async {
      final pubB = await _face('pubB');
      final handler = GatewayHandler(faces: {'pubB': pubB});
      final r = await handler.toolsCall(
        name: GatewayHandler.kGatewaySelectPrivate,
        arguments: const {'server_id': 'pubB', 'scope': 'pruned'},
        onProgress: (_) {},
      );
      expect(r.isError, isTrue);
      expect(r.content, contains('连接建立期'));
    });

    test('非法 policy 字面量 → 拒绝并列出合法档位', () async {
      final pubB = await _face('pubB');
      final handler = GatewayHandler(faces: {'pubB': pubB});
      final r = await handler.toolsCall(
        name: GatewayHandler.kGatewaySelectPrivate,
        arguments: const {'server_id': 'pubB', 'policy': 'wide'},
        onProgress: (_) {},
      );
      expect(r.isError, isTrue);
      expect(r.content, contains('single'));
      expect(r.content, contains('pruned'));
    });

    test('schema 只暴露 policy（PC 侧单一词表：scope 不进 schema）', () {
      final json = GatewayHandler.systemToolJson.firstWhere(
          (t) => t['name'] == GatewayHandler.kGatewaySelectPrivate);
      final schema = json['inputSchema'] as Map<String, Object?>;
      final props =
          (schema['properties'] as Map<String, Object?>).keys.toList();
      expect(props, contains('policy'));
      expect(props, isNot(contains('scope')),
          reason: 'scope 为兼容别名，不进 schema → PC 侧只记一套词表');
    });
  });

}
