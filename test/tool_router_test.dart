import 'dart:convert' as json;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:goodhub/core/errors/mcp_error.dart';
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
  return McpClient(baseUrl: 'http://fake', httpClient: mock);
}

void main() {
  group('ToolRouter 海关门控（F1.9）', () {
    test('未打标工具不注册，打标工具命名空间化注册', () async {
      final client = _fakeClient(tools: [
        {
          'name': 'list_items',
          'description': '列出条目',
          'inputSchema': {'type': 'object'},
          'annotations': {'x-mcp-export-to-shared': true}
        },
        {
          'name': 'internal_tool',
          'description': '私有工具',
          'inputSchema': {'type': 'object'},
          // 无 annotations = 私有，坚决不收集
        },
        {
          'name': 'legacy_tool',
          'description': '裸命名（早期草案）',
          'inputSchema': {'type': 'object'},
          'annotations': {'export_to_shared': true} // 裸命名废弃，不生效
        },
      ]);
      final router = ToolRouter();
      await router.mount(client, 'goodshare');

      expect(router.catalog, ['goodshare__list_items']);
      expect(router.lookup('goodshare__list_items')?.exportToShared, true);
      expect(router.lookup('goodshare__internal_tool'), isNull);
      expect(router.lookup('goodshare__legacy_tool'), isNull);
    });

    test('readOnlyHint 只存储不裁决（注解仅建议值）', () async {
      final client = _fakeClient(tools: [
        {
          'name': 'get_item',
          'description': '读条目',
          'inputSchema': {'type': 'object'},
          'annotations': {
            'readOnlyHint': true,
            'x-mcp-export-to-shared': true
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
              'annotations': {'x-mcp-export-to-shared': true}
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
          'annotations': {'x-mcp-export-to-shared': true}
        }
      ]);
      final b = _fakeClient(tools: [
        {
          'name': 'get',
          'description': 'b',
          'inputSchema': {'type': 'object'},
          'annotations': {'x-mcp-export-to-shared': true}
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
          'annotations': {'x-mcp-export-to-shared': true}
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
