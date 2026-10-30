/// 应用内统一日志内核（内存环形缓冲，开发调试用）。
///
/// 设计口径（2026-10-30 拍板）：
/// - **捕获走 debugPrint sink**而非逐调用点迁移：`install()` 在装配期把全局
///   `debugPrint` 换成捕获实现——先记入环形缓冲，再委托原实现，控制台行为
///   不变。全仓既有 170+ 处 `debugPrint` 零改动即被捕获，未来新调用点与
///   Flutter 框架内部 debug 输出同享捕获面。
/// - **内存环形缓冲**：不落盘、重启即清；容量上限淘汰最旧（FIFO）。
/// - 级别为推断值：正文含 `[DEGRADE]` 按警告，`AppLog.e` 显式错误；其余信息。
///   debugPrint 原始签名无级别字段，推断是 sink 模式的固有限制。
/// - 线程安全面：仅主 isolate 使用（UI 调试页读同一份）；缓冲读写均为
///   同步操作，不做跨 isolate 广播。
library;

import 'package:flutter/foundation.dart';

/// 日志级别（推断或显式指定）。
enum LogLevel { debug, info, warning, error }

/// 单条日志。
class LogEntry {
  const LogEntry({
    required this.timestamp,
    required this.level,
    required this.message,
  });

  final DateTime timestamp;
  final LogLevel level;
  final String message;

  /// 单行渲染（等宽遥测样式，`HH:mm:ss.SSS`）。
  String get line {
    final h = timestamp.hour.toString().padLeft(2, '0');
    final m = timestamp.minute.toString().padLeft(2, '0');
    final s = timestamp.second.toString().padLeft(2, '0');
    final ms = timestamp.millisecond.toString().padLeft(3, '0');
    return '$h:$m:$s.$ms ${level.tag} $message';
  }
}

extension on LogLevel {
  String get tag => switch (this) {
        LogLevel.debug => 'D',
        LogLevel.info => 'I',
        LogLevel.warning => 'W',
        LogLevel.error => 'E',
      };
}

/// 全局日志内核：环形缓冲 + debugPrint sink 安装。
///
/// 应用级单例（不进 `service_directory`：纯调试设施，无领域态，测试经
/// [resetForTest] 隔离）。显式打点用 [d]/[i]/[w]/[e]；存量 `debugPrint`
/// 调用经 [install] 自动捕获。
class AppLog {
  AppLog._();

  static final AppLog instance = AppLog._();

  /// 缓冲容量：淘汰最旧。调试回看窗口按当前会话体量取值，不落盘故无 IO 压力。
  static const int kMaxEntries = 2000;

  final List<LogEntry> _entries = <LogEntry>[];
  final ValueNotifier<int> _revision = ValueNotifier<int>(0);

  /// 缓冲变更版本号：日志页监听它增量刷新（无逐条事件流，避免高频 notify
  /// 抖动；页侧按节拍读 [entries]）。
  ValueListenable<int> get revision => _revision;

  /// 只读快照（拷贝防遍历中被淘汰改表）。
  List<LogEntry> get entries => List<LogEntry>.unmodifiable(_entries);

  int get length => _entries.length;

  void d(String message) => _add(LogLevel.debug, message);

  void i(String message) => _add(LogLevel.info, message);

  void w(String message) => _add(LogLevel.warning, message);

  void e(String message) => _add(LogLevel.error, message);

  /// 清空缓冲（日志页「清空」按钮）。
  void clear() {
    _entries.clear();
    _bump();
  }

  void _add(LogLevel level, String message) {
    _entries.add(LogEntry(
      timestamp: DateTime.now(),
      level: level,
      message: message,
    ));
    if (_entries.length > kMaxEntries) {
      _entries.removeRange(0, _entries.length - kMaxEntries);
    }
    _bump();
  }

  void _bump() => _revision.value++;

  // ---- debugPrint sink ----

  static DebugPrintCallback? _previousPrint;
  static bool _installed = false;

  /// 装配期安装（`main.dart` 调用一次）：替换全局 `debugPrint`，捕获后委托
  /// 原实现。重复调用幂等。测试环境不装（注入式断言用显式 API）。
  static void install() {
    if (_installed || kReleaseMode) return;
    _installed = true;
    _previousPrint = debugPrint;
    debugPrint = _capturePrint;
  }

  static void _capturePrint(String? message, {int? wrapWidth}) {
    if (message != null && message.isNotEmpty) {
      instance._add(_inferLevel(message), message);
    }
    _previousPrint?.call(message, wrapWidth: wrapWidth);
  }

  /// 级别推断：sink 无级别字段，按项目现行正文约定识别。
  static LogLevel _inferLevel(String message) {
    if (message.contains('[DEGRADE]') ||
        message.contains('[W]') ||
        message.toLowerCase().contains('error') ||
        message.toLowerCase().contains('failed')) {
      return LogLevel.warning;
    }
    return LogLevel.info;
  }

  /// 测试隔离：清缓冲并卸载 sink 替换。
  static void resetForTest() {
    instance._entries.clear();
    instance._revision.value = 0;
    if (_previousPrint != null) {
      debugPrint = _previousPrint!;
      _previousPrint = null;
    }
    _installed = false;
  }
}
