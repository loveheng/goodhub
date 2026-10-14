/// 流式文本缓冲池（P0 流控层，stream-perf §3）：SSE/引擎 delta 先进池，按
/// [interval] 节拍批量刷盘，把「每 delta 一次 setState + 一次全文重解析」降为
/// 「每节拍一次」（默认 40ms ≈ 25fps，低于常见 60/120Hz 刷新率半个周期以上，
/// 视觉不可感知）。
///
/// 铁律（stream-perf §3）：流结束 / Abort / 异常路径必须 [flush] 强制清空——
/// 会话快照（ConversationStore）与终态渲染都以 `_track` 为准，缓冲期内到达的
/// 尾帧不得丢失。纯 Dart 实现（零 Flutter 依赖），可经 fake_async 单测。
library;

import 'dart:async';

/// 刷盘回调：参数 = 本次批量取走的文本（可能跨多个 delta 拼接）。
typedef StreamFlushSink = void Function(String text);

class StreamTextBuffer {
  StreamTextBuffer({
    this.interval = const Duration(milliseconds: 40),
    this.onFlush,
  });

  /// 刷盘节拍。
  final Duration interval;

  /// 刷盘回调（chat_page 装配期一次性设置）。
  StreamFlushSink? onFlush;

  final StringBuffer _pending = StringBuffer();
  Timer? _timer;
  var _disposed = false;

  /// 待刷文本是否非空。
  bool get hasPending => _pending.isNotEmpty;

  /// delta 入池；运行中只保留一个节拍定时器（后续 delta 搭本次节拍车）。
  /// dispose 后为终态：静默丢弃（防 widget 销毁后再入池）。
  void add(String delta) {
    if (_disposed || delta.isEmpty) return;
    _pending.write(delta);
    _timer ??= Timer(interval, _onTick);
  }

  void _onTick() {
    _timer = null;
    _emit(drain());
  }

  /// 取走并清空缓冲；无待刷返回 null。
  String? drain() {
    if (_pending.isEmpty) return null;
    final text = _pending.toString();
    _pending.clear();
    return text;
  }

  /// 强制清空（流结束/中止/异常路径）：取消节拍定时器，残余文本立即刷出。
  /// 幂等——无残余 / 已 dispose 时静默返回。
  void flush() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = null;
    _emit(drain());
  }

  /// 取消定时器并丢弃残余（widget 销毁用）：此后 add/flush 均为静默 no-op
  /// （终态语义，防 Run 的 finally 迟到的 flush 触发已销毁页面的 setState）。
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _pending.clear();
  }

  void _emit(String? text) {
    if (text == null || text.isEmpty) return;
    onFlush?.call(text);
  }
}
