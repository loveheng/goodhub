/// HostTransport 骨架单测（host-tools-gateway-export PR1-1）。
///
/// 覆盖设计稿「Host 导出 Allowlist」与门禁 1/2 的机械契约：
/// - 合成 `tools/list` 形状（annotations 强置 / `_meta` visibility+tags）；
/// - 未登记者不导出 + 空面合法（空数组、不抛）；
/// - 控制面原语黑名单（列不出 + 调用显式拒绝）；
/// - 工具名禁含 `__`（登记纪律的**单测保底**，不落运行期 throw）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/discovery_executor.dart';
import 'package:goodhub/core/tool_result.dart';
import 'package:goodhub/core/tool_visibility.dart';
import 'package:goodhub/mcp/mcp_client.dart';
import 'package:goodhub/mcp/transport/host_transport.dart';
import 'package:goodhub/core/actor.dart';

/// 记录调用参数的假执行端口。
class _SpyInvoker {
  final List<({String name, String argumentsJson})> calls = [];
  Object? throwOnCall;

  Future<ToolExecutionResult> call({
    required String name,
    required String argumentsJson,
  }) async {
    calls.add((name: name, argumentsJson: argumentsJson));
    final err = throwOnCall;
    if (err != null) throw err;
    return const ToolExecutionResult(content: 'ok');
  }
}

HostTransport _host(_SpyInvoker spy, {List<HostExportEntry> allowlist = const []}) =>
    HostTransport(invoker: spy.call, allowlist: allowlist);

/// 单发一请求并解出 JSON-RPC 帧（走真实协议层的解析口径）。
Future<Map<String, Object?>> _rpc(
  HostTransport t,
  String method, {
  Object? params,
  int? id = 1,
}) async {
  final resp = await t.send(jsonEncode(<String, Object?>{
    'jsonrpc': '2.0',
    'method': method,
    'params': ?params,
    'id': ?id,
  }));
  expect(resp.statusCode, 200);
  return jsonDecode(resp.body) as Map<String, Object?>;
}

Map<String, Object?> _result(Map<String, Object?> frame) =>
    frame['result'] as Map<String, Object?>;

Map<String, Object?> _error(Map<String, Object?> frame) =>
    frame['error'] as Map<String, Object?>;

HostExportEntry _entry(
  String name, {
  Map<String, Object?>? annotations,
  List<String> tags = const [],
  ToolVisibility visibility = ToolVisibility.shared,
}) =>
    HostExportEntry(
      allowedActors: <Actor>{Actor.owner},
      name: name,
      description: '测试工具 $name（怎么用才对：仅用于单测）',
      inputSchema: const <String, Object?>{'type': 'object'},
      annotations: annotations,
      visibility: visibility,
      tags: tags,
    );

void main() {
  group('initialize 握手（只声明 tools）', () {
    test('协议版本 + serverInfo + 不声明 sampling/resources', () async {
      final frame = await _rpc(_host(_SpyInvoker()), 'initialize');
      final result = _result(frame);
      expect(result['protocolVersion'], '2025-06-18');
      final caps = result['capabilities'] as Map<String, Object?>;
      expect(caps.containsKey('tools'), isTrue,
          reason: '须声明 tools 能力（挂载原语按此判 Tier 2）');
      expect(caps.containsKey('sampling'), isFalse,
          reason: '宿主不供给反向请求面——声明会把 face 拖进流式调用');
      expect(caps.containsKey('resources'), isFalse,
          reason: '无订阅能力，协议层不应建 GET SSE 监听');
      final info = result['serverInfo'] as Map<String, Object?>;
      expect(info['name'], HostTransport.serverName);
    });
  });

  group('tools/list 合成面（Allowlist 口径）', () {
    test('未登记者一律不导出（注入空表 → 空面合法，不抛）', () async {
      final result = _result(await _rpc(_host(_SpyInvoker()), 'tools/list'));
      expect(result['tools'], isEmpty, reason: '空面在 MCP 下合法');
    });

    test('生产登记表：至少一个 shared 且 readOnlyHint:true 的条目（§5.7 保底）',
        () async {
      // 本组用例显式断言**生产静态表**（此前交付为空面，登记首项后此保底生效）。
      expect(kHostExportAllowlist, isNotEmpty,
          reason: 'Allowlist 空面只作过渡保底；登记首项后本断言长期钉住');
      final sharedReadOnly = kHostExportAllowlist.where((e) =>
          e.visibility == ToolVisibility.shared &&
          (e.annotations ?? const {})['readOnlyHint'] == true);
      expect(sharedReadOnly, isNotEmpty,
          reason: '至少一个 shared 且显式 readOnlyHint:true 的条目');
    });

    test('生产登记表经合成面下发（schema 由 resolver 提供，非表内复制）', () async {
      final resolverCalls = <String>[];
      final transport = HostTransport(
        invoker: _SpyInvoker().call,
        schemaResolver: (name) {
          resolverCalls.add(name);
          return <String, Object?>{
            'description': '宿主环境事实（来自执行面）',
            'inputSchema': <String, Object?>{'type': 'object', 'title': 'status'},
          };
        },
      );
      final tools = ((_result(await _rpc(transport, 'tools/list'))['tools']) as List)
          .cast<Map<String, Object?>>();
      expect(tools.map((e) => e['name']), contains('get_host_status'));
      final status = tools.firstWhere((e) => e['name'] == 'get_host_status');
      expect(status['description'], '宿主环境事实（来自执行面）',
          reason: '描述 owner = 执行面（§5.1 住在执行器侧），Allowlist 不复制');
      expect((status['inputSchema'] as Map)['title'], 'status');
      expect(resolverCalls, contains('get_host_status'));
      expect((status['annotations'] as Map)['readOnlyHint'], true);
      final meta = (status['_meta'] as Map)['goodhub'] as Map;
      expect(meta['visibility'], 'shared');
      expect(meta['tags'], ['core']);
    });

    test('登记项原样合成 name/description/inputSchema', () async {
      final t = _host(_SpyInvoker(), allowlist: [_entry('get_host_status')]);
      final tools = (_result(await _rpc(t, 'tools/list'))['tools'] as List)
          .cast<Map<String, Object?>>();
      expect(tools, hasLength(1));
      expect(tools.single['name'], 'get_host_status');
      expect(tools.single['inputSchema'], <String, Object?>{'type': 'object'});
    });

    test('门禁 1：未声明 readOnly/destructive → 强置 destructiveHint:true', () async {
      final t = _host(_SpyInvoker(),
          allowlist: [_entry('a'), _entry('b', annotations: const {'title': 'B'})]);
      final tools = (_result(await _rpc(t, 'tools/list'))['tools'] as List)
          .cast<Map<String, Object?>>();
      for (final tool in tools) {
        expect((tool['annotations'] as Map)['destructiveHint'], true,
            reason: '${tool['name']} 未声明 hint → 必须落 L2 确认卡');
      }
    });

    test('已显式声明的 annotations 原样透出（不强置）', () async {
      final t = _host(_SpyInvoker(), allowlist: [
        _entry('ro', annotations: const {'readOnlyHint': true}),
        _entry('rw', annotations: const {'readOnlyHint': false}),
      ]);
      final tools = (_result(await _rpc(t, 'tools/list'))['tools'] as List)
          .cast<Map<String, Object?>>();
      final byName = {for (final e in tools) e['name'] as String: e['annotations'] as Map};
      expect(byName['ro'], <String, Object?>{'readOnlyHint': true});
      expect(byName['rw'], <String, Object?>{'readOnlyHint': false},
          reason: '显式 readOnlyHint=false 已是破坏性声明，不得被强置覆盖');
    });

    test('_meta.goodhub 带 visibility 与 tags（pruned 拾取依据）', () async {
      final t = _host(_SpyInvoker(), allowlist: [
        _entry('a', tags: const ['core', 'io']),
        _entry('b', visibility: ToolVisibility.private),
      ]);
      final tools = (_result(await _rpc(t, 'tools/list'))['tools'] as List)
          .cast<Map<String, Object?>>();
      final meta = {
        for (final e in tools)
          e['name'] as String: ((e['_meta'] as Map)['goodhub'] as Map)
      };
      expect((meta['a']!['visibility']), 'shared');
      expect((meta['a']!['tags']), ['core', 'io']);
      expect((meta['b']!['visibility']), 'private', reason: '缺省/显式 private 都不进投影');
      expect(meta['b']!.containsKey('tags'), isFalse, reason: '未打标不留空数组');
    });

    test('门禁 2：控制面原语合成面强制剔除', () async {
      final t = _host(_SpyInvoker(),
          allowlist: [for (final n in kHostControlPlaneTools) _entry(n)]);
      final tools = (_result(await _rpc(t, 'tools/list'))['tools'] as List);
      expect(tools, isEmpty, reason: 'use_server 等控制面原语不对外导出');
    });

    test('畸形登记名（含 __）剔除 + 留痕，不抛', () async {
      final t = _host(_SpyInvoker(), allowlist: [_entry('host__nested')]);
      final tools = (_result(await _rpc(t, 'tools/list'))['tools'] as List);
      expect(tools, isEmpty);
    });
  });

  group('tools/call（进程内直调）', () {
    test('登记项 → 注入端口（裸名 + 入参 JSON）→ content 信封', () async {
      final spy = _SpyInvoker();
      final t = _host(spy, allowlist: [_entry('get_host_status')]);
      final frame = await _rpc(t, 'tools/call', params: {
        'name': 'get_host_status',
        'arguments': {'detail': true},
      });
      expect(spy.calls.single.name, 'get_host_status');
      expect(spy.calls.single.argumentsJson, '{"detail":true}');
      final result = _result(frame);
      expect(result['isError'], false);
      expect((result['content'] as List).single, <String, Object?>{
        'type': 'text',
        'text': 'ok',
      });
    });

    test('缺 arguments → 传 {} 而非报错', () async {
      final spy = _SpyInvoker();
      final t = _host(spy, allowlist: [_entry('a')]);
      await _rpc(t, 'tools/call', params: {'name': 'a'});
      expect(spy.calls.single.argumentsJson, '{}');
    });

    test('未登记者调用 → -32602（名字级拒绝，不执行）', () async {
      final spy = _SpyInvoker();
      final frame = await _rpc(_host(spy), 'tools/call',
          params: {'name': 'query_memory'});
      expect(_error(frame)['code'], -32602);
      expect(spy.calls, isEmpty);
    });

    test('控制面原语调用 → -32602 显式拒绝', () async {
      final spy = _SpyInvoker();
      final frame = await _rpc(_host(spy), 'tools/call',
          params: {'name': 'use_server', 'arguments': {'server_id': 'all'}});
      expect(_error(frame)['code'], -32602);
      expect(spy.calls, isEmpty);
    });

    test('带 __ 的名字 → -32602（畸形前缀名，投影层职责）', () async {
      final spy = _SpyInvoker();
      final frame = await _rpc(_host(spy), 'tools/call',
          params: {'name': 'host__other__tool'});
      expect(_error(frame)['code'], -32602);
      expect(spy.calls, isEmpty);
    });

    test('缺 name / arguments 非 object → -32602', () async {
      final spy = _SpyInvoker();
      final t = _host(spy, allowlist: [_entry('a')]);
      expect(_error(await _rpc(t, 'tools/call', params: const {}))['code'], -32602);
      expect(
          _error(await _rpc(t, 'tools/call', params: const {
                'name': 'a',
                'arguments': 'not-an-object',
              }))['code'],
          -32602);
      expect(spy.calls, isEmpty);
    });

    test('宿主执行抛异常 → isError 信封 + 不外泄栈信息', () async {
      final spy = _SpyInvoker()..throwOnCall = StateError('内部细节 secret');
      final t = _host(spy, allowlist: [_entry('a')]);
      final result = _result(await _rpc(t, 'tools/call', params: {'name': 'a'}));
      expect(result['isError'], true);
      final text = ((result['content'] as List).single as Map)['text'] as String;
      expect(text, isNot(contains('secret')), reason: '禁底层异常裸漏到 MCP 层');
    });

    test('宿主返回 isError → 原样透出信封', () async {
      final t = HostTransport(
        invoker: ({required String name, required String argumentsJson}) async =>
            const ToolExecutionResult(content: '读取失败(bad_request)', isError: true),
        allowlist: [_entry('a')],
      );
      final result = _result(await _rpc(t, 'tools/call', params: {'name': 'a'}));
      expect(result['isError'], true);
    });
  });

  group('协议面健壮性', () {
    test('通知帧（无 id）→ 202 空体，不返帧', () async {
      final resp = await _host(_SpyInvoker())
          .send(jsonEncode(<String, Object?>{'method': 'notifications/initialized'}));
      expect(resp.statusCode, 202);
      expect(resp.body, isEmpty);
    });

    test('未知方法 → -32601；畸形 JSON → -32700；缺 method → -32600', () async {
      final t = _host(_SpyInvoker());
      expect(_error(await _rpc(t, 'prompts/list'))['code'], -32601);
      final bad = jsonDecode((await t.send('{not json')).body) as Map<String, Object?>;
      expect((bad['error'] as Map)['code'], -32700);
      final noMethod = jsonDecode(
              (await t.send(jsonEncode(<String, Object?>{'id': 9}))).body)
          as Map<String, Object?>;
      expect((noMethod['error'] as Map)['code'], -32600);
      expect(noMethod['id'], 9, reason: '错误帧必须回带原 id 供协议层关联');
    });

    test('ping → 空 result（探活口径）', () async {
      expect(_result(await _rpc(_host(_SpyInvoker()), 'ping')), isEmpty);
    });

    test('流式路径单帧封装（callWithProgress Polyfill 口径）', () async {
      final streamed = await _host(_SpyInvoker()).sendStream(jsonEncode(
          <String, Object?>{'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'}));
      expect(streamed.statusCode, 200);
      expect(streamed.contentType, 'text/event-stream');
      final lines = await streamed.lines.toList();
      expect(lines, hasLength(2));
      expect(lines.first.startsWith('data: '), isTrue);
      expect(lines.last, isEmpty,
          reason: '空行是 SSE 断帧符——漏掉会让 callWithProgress 抛「流结束无 result 帧」');
    });

    test('真实协议层 callWithProgress 能解出单帧 result（回归钉子）', () async {
      final client = McpClient(_host(_SpyInvoker(), allowlist: [_entry('a')]));
      addTearDown(client.close);
      final result = await client.callWithProgress('tools/list',
          onProgress: (_) {}, onRequestId: (id) {
        expect(id, greaterThan(0));
      });
      final tools = ((result as Map<String, Object?>)['tools'] as List)
          .cast<Map<String, Object?>>();
      expect(tools.single['name'], 'a');

      final called = await client.callWithProgress(
        'tools/call',
        params: {'name': 'a', 'arguments': const <String, Object?>{}},
        onProgress: (_) {},
      );
      expect((called as Map<String, Object?>)['isError'], false);
    });

    test('无 GET SSE 订阅通道 → UnsupportedError（协议层退化为不监听）', () {
      expect(() => _host(_SpyInvoker()).getStream(), throwsUnsupportedError);
    });

    test('close 幂等；关闭后 send 快失败（生命周期归 owner）', () async {
      final t = _host(_SpyInvoker());
      t.close();
      t.close();
      await expectLater(t.send('{}'), throwsStateError);
    });
  });

  group('登记纪律保底断言（单测钉死）', () {
    test('Allowlist 工具名禁含 __（命名空间分隔符仅两段）', () {
      for (final e in kHostExportAllowlist) {
        expect(e.name.contains('__'), isFalse,
            reason: '工具名 ${e.name} 含结构分隔符 __，投影层会解析出畸形名');
      }
    });

    test('控制面黑名单与宿主元工具常量同步（防字面量漂移）', () {
      expect(kHostControlPlaneTools, contains(DiscoveryExecutor.getConnectedApps));
      expect(kHostControlPlaneTools, contains(DiscoveryExecutor.activateServerTools));
      expect(kHostControlPlaneTools, contains(DiscoveryExecutor.useServer));
    });

    test('保留 serverId 与前缀形态一致（host__ 由网关投影层拼装）', () {
      expect(kHostServerId, 'host');
      expect('${kHostServerId}__tool', 'host__tool');
    });
  });
}