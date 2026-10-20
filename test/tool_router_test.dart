import 'dart:convert' as json;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:goodhub/core/errors/mcp_error.dart';
import 'package:goodhub/core/tool_visibility.dart';
import 'package:goodhub/mcp/mcp_client.dart';
import 'package:goodhub/mcp/tool_router.dart';

/// 按 tools/list 数据构造假客户端（不触网）。
McpClient _fakeClient({
  required List<Map<String, Object?>> tools,
  void Function(String method, Object? params)? onCall,
}) {
  final mock = MockClient((request) async {
    final decoded =
        json.jsonDecode(request.body) as Map<String, Object?>;
    final method = decoded['method'] as String;
    if (method == 'tools/list') {
      return http.Response(
          json.jsonEncode({'jsonrpc': '2.0', 'id': 1, 'result': {'tools': tools}}),
          200,
          headers: {'content-type': 'application/json'});
    }
    onCall?.call(method, decoded['params']);
    return http.Response(
        json.jsonEncode({'jsonrpc': '2.0', 'id': 1, 'result': {'ok': true}}), 200,
        headers: {'content-type': 'application/json'});
  });
  return McpClient.http(baseUrl: 'http://fake', httpClient: mock);
}

void main() {
  group('ToolRouter 海关门控（F1.9）', () {
    test('未打标工具不注册，`_meta.goodhub.visibility=shared` 才注册', () async {
      final client = _fakeClient(tools: [
        {
          'name': 'list_items',
          'description': '列出条目',
          'inputSchema': {'type': 'object'},
          '_meta': {
            'goodhub': {'visibility': 'shared'}
          }
        },
        {
          'name': 'internal_tool',
          'description': '私有工具',
          'inputSchema': {'type': 'object'},
          // 无 _meta = 私有（default-deny），坚决不收集
        },
        {
          'name': 'explicit_private',
          'description': '显式私有',
          'inputSchema': {'type': 'object'},
          '_meta': {
            'goodhub': {'visibility': 'private'}
          }
        },
        {
          'name': 'legacy_tool',
          'description': '旧口径（已作废）',
          'inputSchema': {'type': 'object'},
          // 旧口径 annotations["x-mcp-export-to-shared"]（2026-10-21 作废）
          // 不再生效——访问控制标记不得塞进 MCP annotations。
          'annotations': {'x-mcp-export-to-shared': true}
        },
        {
          'name': 'misplaced_tool',
          'description': '标记放错位置（_meta 顶层）',
          'inputSchema': {'type': 'object'},
          // 标记必须在 _meta.goodhub 子树下；_meta 顶层同名键不生效
          '_meta': {'visibility': 'shared'}
        },
      ]);
      final router = ToolRouter();
      await router.mount(client, 'goodshare');

      expect(router.catalog, ['goodshare__list_items']);
      expect(router.lookup('goodshare__list_items')?.visibility,
          ToolVisibility.shared);
      expect(router.lookup('goodshare__internal_tool'), isNull);
      expect(router.lookup('goodshare__explicit_private'), isNull);
      expect(router.lookup('goodshare__legacy_tool'), isNull);
      expect(router.lookup('goodshare__misplaced_tool'), isNull);
    });

    test('readOnlyHint 只存储不裁决（注解仅建议值）', () async {
      final client = _fakeClient(tools: [
        {
          'name': 'get_item',
          'description': '读条目',
          'inputSchema': {'type': 'object'},
          'annotations': {'readOnlyHint': true},
          '_meta': {
            'goodhub': {'visibility': 'shared'}
          }
        },
      ]);
      final router = ToolRouter();
      await router.mount(client, 'goodshare');
      expect(router.lookup('goodshare__get_item')?.readOnlyHint, true);
    });
  });

  group('ToolRouter 命名空间隔离（F1.2）', () {
    test('call 路由到正确 Server 并剥离命名空间', () async {
      String? received;
      final client = _fakeClient(
          tools: [
            {
              'name': 'list_items',
              'description': 'x',
              'inputSchema': {'type': 'object'},
              '_meta': {
                'goodhub': {'visibility': 'shared'}
              }
            }
          ],
          onCall: (method, params) => received = method);
      final router = ToolRouter();
      await router.mount(client, 'goodshare');

      final result = await router.call('goodshare__list_items',
          args: {'limit': 5});
      expect(received, 'list_items');
      expect(result, isA<Map<String, Object?>>());
    });

    test('未注册工具抛 McpProtocolException', () async {
      final router = ToolRouter();
      await router.mount(
          _fakeClient(tools: const []), 'goodshare');
      expect(() => router.call('todo__add_item', args: const {}),
          throwsA(isA<McpProtocolException>()));
    });

    test('命名空间冲突：不同 Server 注册同名牌工具', () async {
      final a = _fakeClient(tools: [
        {
          'name': 'get',
          'description': 'a',
          'inputSchema': {'type': 'object'},
          '_meta': {
            'goodhub': {'visibility': 'shared'}
          }
        }
      ]);
      final b = _fakeClient(tools: [
        {
          'name': 'get',
          'description': 'b',
          'inputSchema': {'type': 'object'},
          '_meta': {
            'goodhub': {'visibility': 'shared'}
          }
        }
      ]);
      final router = ToolRouter();
      await router.mount(a, 'goodshare');
      // 同 Server 重复挂载同名工具 → 冲突
      expect(
          () => router.mount(a, 'goodshare'),
          throwsA(isA<McpProtocolException>()));
      // 不同 Server 同名工具 → 命名空间隔离，合法
      await router.mount(b, 'todo');
      expect(router.catalog, ['goodshare__get', 'todo__get']);
    });

    test('unmount 清掉该 Server 全部命名空间条目', () async {
      final a = _fakeClient(tools: [
        {
          'name': 'get',
          'description': 'a',
          'inputSchema': {'type': 'object'},
          '_meta': {
            'goodhub': {'visibility': 'shared'}
          }
        }
      ]);
      final router = ToolRouter();
      await router.mount(a, 'goodshare');
      router.unmount('goodshare');
      expect(router.catalog, isEmpty);
      expect(
          () => router.call('goodshare__get', args: const {}),
          throwsA(isA<McpProtocolException>()));
    });
  });

  group('McpTool 解析纪律', () {
    test('工具名含双下划线即契约违规（分隔符保留）', () {
      expect(
          () => McpTool.parse({
                'name': 'bad__name',
                'description': '',
                'inputSchema': {'type': 'object'}
              }),
          throwsA(isA<McpProtocolException>()));
    });

    test('缺 name 即契约违规', () {
      expect(() => McpTool.parse({'description': 'no name'}),
          throwsA(isA<McpProtocolException>()));
    });
  });
}
