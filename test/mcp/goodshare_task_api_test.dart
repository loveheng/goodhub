/// GoodshareTaskApi tools/call 信封解包单测（T7 实测修复钉子）。
///
/// 背景：goodshare T4d 包装层起 tools/call 结果为 MCP 标准信封
/// `{content:[{type:'text',text}], isError}`，任务载荷 JSON 在首 text 块——
/// 回归钉住 claim/apply 载荷解析不再直读 result。
library;

import 'dart:convert' as json;

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/mcp/goodshare_task_api.dart';
import 'package:goodhub/mcp/mcp_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _rpc(Object? result) => http.Response(
      '{"jsonrpc":"2.0","id":1,"result":${json.jsonEncode(result)}}',
      200,
      headers: {'content-type': 'application/json'},
    );

McpClient _clientWith(Object? Function() result) => McpClient.http(
      baseUrl: 'http://127.0.0.1:8765/mcp',
      httpClient: MockClient((_) async => _rpc(result())),
    );

void main() {
  test('claim：信封内 text 载荷解包后按契约 §3.2 解析', () async {
    const payload = {
      'status': 'claimed',
      'task_id': 't1',
      'item_id': 'i1',
      'task_action': 'llm_summarize',
      'text': '正文',
      'version': 22,
    };
    final api = GoodshareTaskApi(_clientWith(() => {
          'content': [
            {'type': 'text', 'text': json.jsonEncode(payload)},
          ],
          'isError': false,
        }));
    final task = await api.claim();
    expect(task.taskId, 't1');
    expect(task.itemId, 'i1');
    expect(task.taskAction, 'llm_summarize');
    expect(task.text, '正文');
    expect(task.version, 22);
  });

  test('apply：信封内条目快照解包为 Map（Applied keys 取快照字段）', () async {
    const snapshot = {
      'id': 'i1',
      'title': '标题',
      'summary_md': '摘要',
      'version': 23,
    };
    final api = GoodshareTaskApi(_clientWith(() => {
          'content': [
            {'type': 'text', 'text': json.jsonEncode(snapshot)},
          ],
          'isError': false,
        }));
    final out = await api.apply(const ApplyPayload(
      taskId: 't1',
      itemId: 'i1',
      note: 'note',
    ));
    expect(out, isA<Map<String, Object?>>());
    expect((out as Map)['id'], 'i1');
  });

  test('touch：非 JSON 文本（ok）原样返回不抛', () async {
    final api = GoodshareTaskApi(_clientWith(() => {
          'content': [
            {'type': 'text', 'text': 'ok'},
          ],
          'isError': false,
        }));
    await expectLater(api.touch('t1'), completes);
  });
}
