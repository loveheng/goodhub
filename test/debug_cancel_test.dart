import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/mcp_tool_face.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/mcp/mcp_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('debug', () async {
    final bodies = <String>[];
    late final McpToolFace face;
    final client = McpClient(
      baseUrl: 'http://10.0.0.5:8765/mcp',
      httpClient: MockClient((req) async {
        bodies.add(req.body);
        if (req.body.contains('"method":"initialize"')) {
          return http.Response(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': 1,
                'result': {
                  'protocolVersion': '2025-06-18',
                  'capabilities': {'tools': {}, 'sampling': {}},
                },
              }),
              200,
              headers: {'content-type': 'application/json'});
        }
        if (req.body.contains('notifications/')) return http.Response('', 202);
        return http.Response(
          'data: ${jsonEncode({
            'jsonrpc': '2.0',
            'method': 'notifications/progress',
            'params': {'progressToken': 1, 'progress': 0, 'total': 1},
          })}\n\n'
          'data: ${jsonEncode({
            'jsonrpc': '2.0',
            'id': 1,
            'result': {
              'content': [
                {'type': 'text', 'text': 'done'}
              ],
              'isError': false,
            },
          })}\n\n',
          200,
          headers: {'content-type': 'text/event-stream; charset=utf-8'},
        );
      }),
    );
    face = McpToolFace(
      client: client,
      onProgress: (tool, progress, total, message) {
        debugPrint('onProgress fired: $tool $progress/$total');
        face.cancelActiveRequest(reason: 'user abort');
      },
    );
    final r = await face.execute(
      const AssembledToolCall(id: 'c1', name: 'f', argumentsJson: '{}'),
    );
    await pumpEventQueue();
    debugPrint('RESULT isError=${r.isError} bodies=${bodies.length}');
    for (final b in bodies) {
      debugPrint('BODY: ${b.length > 150 ? b.substring(0, 150) : b}');
    }
  });
}

