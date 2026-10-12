import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/llm/cloud/sse_parser.dart';

void main() {
  Stream<SseEvent> parse(String raw, {List<String>? chunks}) =>
      parseSse(Stream.fromIterable(chunks ?? [raw]));

  test('单帧单 data 行（带前导空格）', () async {
    final events = await parse('data: {"a":1}\n\n').toList();
    expect(events, hasLength(1));
    expect(events.single.event, 'message');
    expect(events.single.data, '{"a":1}');
  });

  test('data: 后无空格也解析', () async {
    final events = await parse('data:{"a":1}\n\n').toList();
    expect(events.single.data, '{"a":1}');
  });

  test('多行 data 以 \\n 连接', () async {
    final events = await parse('data: a\ndata: b\n\n').toList();
    expect(events.single.data, 'a\nb');
  });

  test('event 字段携带事件名', () async {
    final events = await parse('event: error\ndata: {"x":1}\n\n').toList();
    expect(events.single.event, 'error');
    expect(events.single.data, '{"x":1}');
  });

  test('注释与心跳行忽略', () async {
    final events = await parse(': ping\n\n: keep\ndata: ok\n\n').toList();
    expect(events, hasLength(1));
    expect(events.single.data, 'ok');
  });

  test('CRLF 行尾', () async {
    final events = await parse('data: a\r\n\r\n').toList();
    expect(events.single.data, 'a');
  });

  test('UTF-8 BOM 剥除', () async {
    final events = await parse('\uFEFFdata: x\n\n').toList();
    expect(events.single.data, 'x');
  });

  test('跨块断行拼接（网络分片不丢字）', () async {
    final events = await parse(
      '',
      chunks: ['data: {"a"', ':1}\n\n', 'data: [DO', 'NE]\n\n'],
    ).toList();
    expect(events.map((e) => e.data), ['{"a":1}', '[DONE]']);
  });

  test('仅 event 字段的空帧丢弃；流末无终止空行的残余帧丢弃', () async {
    final events = await parse('event: x\n\ndata: 残余无空行结尾').toList();
    expect(events, isEmpty);
  });
}
