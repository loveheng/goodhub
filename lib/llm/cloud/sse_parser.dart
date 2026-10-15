/// 通用 SSE（text/event-stream）帧解析：UTF-8 解码后的文本块流 → SSE 事件流。
///
/// 实现 WHATWG SSE 规范常用子集：
/// - 事件以空行分隔，`field: value` 行逐条累积；
/// - 多行 `data` 以 `\n` 连接后作为一帧交付；
/// - `event` 字段携带事件名（规范缺省 'message'）；
/// - 以 `:` 开头的行是注释/心跳，忽略；
/// - 首行 UTF-8 BOM 剥除；`\r\n` 与 `\n` 行尾均支持（LineSplitter）。
///
/// 协议客户端（OpenAI/Anthropic）只消费 data/event 两字段；
/// id/retry 解析后丢弃（当前无断线重连语义，F1.4 属 M2.5+）。
library;


import 'dart:async';

/// 单个 SSE 事件（空行结算的一帧）。
class SseEvent {
  const SseEvent({required this.event, required this.data});

  /// 事件名（规范缺省 'message'）。
  final String event;

  /// data 字段按行拼接后的载荷。
  final String data;
}

/// 把文本块流切成 SSE 事件流。纯解析、无 I/O，独立导出供单测。
/// 手写分行器：当前 SDK 的 LineSplitter 在分片边界会复制边界字符（回归），
/// 且需要 \r\n/\n 双兼容与跨块不丢字——自行缓冲切行。
Stream<String> _splitLines(Stream<String> chunks) async* {
  var buf = '';
  await for (final c in chunks) {
    buf += c;
    while (true) {
      final idx = buf.indexOf('\n');
      if (idx < 0) break;
      var line = buf.substring(0, idx);
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
      buf = buf.substring(idx + 1);
      yield line;
    }
  }
  if (buf.isNotEmpty) yield buf;
}

Stream<SseEvent> parseSse(
  Stream<String> chunks, {
  void Function()? onActivity,
}) async* {
  var firstLine = true;
  var eventName = 'message';
  var dataLines = <String>[];

  await for (final line in _splitLines(chunks)) {
    onActivity?.call(); // 任意行到达 = 传输层有字节流动（含心跳注释帧），证明连接活着
    var l = line;
    if (firstLine) {
      // UTF-8 BOM（EF BB BF）解码残留
      if (l.startsWith('\uFEFF')) l = l.substring(1);
      firstLine = false;
    }
    if (l.isEmpty) {
      // 空行结算一帧；无 data 的空行（如仅 event 字段）按规范整帧丢弃
      if (dataLines.isNotEmpty) {
        yield SseEvent(event: eventName, data: dataLines.join('\n'));
      }
      eventName = 'message';
      dataLines = [];
      continue;
    }
    if (l.startsWith(':')) continue; // 注释/心跳行
    final colon = l.indexOf(':');
    final field = colon < 0 ? l : l.substring(0, colon);
    var value = colon < 0 ? '' : l.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1); // 规范：剥一个前导空格
    switch (field) {
      case 'event':
        eventName = value;
      case 'data':
        dataLines.add(value);
      default:
        break; // id/retry 与未知字段：当前无语义，丢弃
    }
  }
  // 流结束时残余未结算帧丢弃（无终止空行 = 帧未完结，契约如此不猜测补全）
}
