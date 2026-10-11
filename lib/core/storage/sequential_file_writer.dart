/// 串行文件写队列 + 临时文件原子替换（File Mutex 降格实现）。
///
/// 规格 SSOT：coding-standards.md §5.1 + architecture.md §4（单 isolate 串行
/// 写队列，杜绝并发裸写）。跨 App 沙盒不共享文件系统（§11），本队列是进程内
/// 串行语义，多进程/多实例同写同一文件不受保护（单进程硬约束 F4.7 前提下不成立）。
///
/// - [write] = 临时文件落盘 + rename 原子替换（崩溃时要么旧档要么新档，无半文件）；
///   [append] = FileMode.append 直追加（append-only 日志面，容忍崩溃尾部截断）；
/// - 单次操作失败**向调用方透传异常，但不毒化队列**——§5.1 基准草案的
///   `_lastWrite = _lastWrite.then(...)` 链式写法会让一次失败永久卡死后续写
///   （errored future 吞掉全部后续回调），此处续链与透传分离修正。
library;

import 'dart:io';

class SequentialFileWriter {
  SequentialFileWriter(this.file);

  /// 目标文件。append 每次按当前路径打开——轮转 rename 走名后追加自动落新档。
  final File file;

  Future<void> _tail = Future<void>.value();

  /// 全量重写落盘（原子替换）。
  Future<void> write(String content) => _enqueue(() async {
        final temp = File('${file.path}.tmp');
        await temp.writeAsString(content, flush: true);
        await temp.rename(file.path);
      });

  /// 追加落盘（文件不存在自动创建）。
  Future<void> append(String content) => _enqueue(() async {
        await file.writeAsString(content, mode: FileMode.append, flush: true);
      });

  Future<T> _enqueue<T>(Future<T> Function() task) {
    final result = _tail.then((_) => task());
    // 吞错仅为续链（错误已透传 result），防一次失败杀死整条队列。
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}
