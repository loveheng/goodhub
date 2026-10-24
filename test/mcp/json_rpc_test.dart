/// JSON-RPC 解析单测：A02（review-fix-2026-10）id 宽松解析——string id 不得
/// 抛裸 TypeError（违 §5.5），int/String 之外置 null。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/core/errors/mcp_error.dart';
import 'package:goodhub/mcp/json_rpc.dart';

void main() {
  group('A02：JsonRpcResponse.id 宽松解析', () {
    test('int id 原样保留', () {
      final r = JsonRpcResponse.parse({'id': 7, 'result': 'ok'});
      expect(r.id, 7);
    });

    test('string id 保留（部分 server 回 string）——撤修复即红', () {
      final r = JsonRpcResponse.parse({'id': 'abc-1', 'result': 'ok'});
      expect(r.id, 'abc-1');
    });

    test('畸形 id（非 int/String）→ null（不抛）', () {
      final r = JsonRpcResponse.parse({'id': 3.14, 'result': 'ok'});
      expect(r.id, isNull);
    });

    test('error 帧同样宽松（string id 不影响错误解析）', () {
      final r = JsonRpcResponse.parse({
        'id': 'req-x',
        'error': {'code': -32601, 'message': 'no such tool'},
      });
      expect(r.error, isA<McpRpcException>());
      expect(r.id, 'req-x');
    });
  });
}
