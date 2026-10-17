/// 串行文件写队列 + 临时文件原子替换（File Mutex 降格实现）。
///
/// 规格 SSOT：coding-standards.md §3.2 + architecture.md §4（单 isolate 串行
/// 写队列，杜绝并发裸写）。跨 App 沙盒不共享文件系统（§11），本队列是进程内
/// 串行语义，多进程/多实例同写同一文件不受保护（单进程硬约束 F4.7 前提下不成立）。
///
/// - [write] = 临时文件落盘 + rename 原子替换（崩溃时要么旧档要么新档，无半文件）；
///   [append] = FileMode.append 直追加（append-only 日志面，容忍崩溃尾部截断）；
/// - 单次操作失败**向调用方透传异常，但不毒化队列**——§5.1 基准草案的
///   `_lastWrite = _lastWrite.then(...)` 链式写法会让一次失败永久卡死后续写
///   （errored future 吞掉全部后续回调），此处续链与透传分离修正。
///
/// **互斥粒度 = 文件路径，不是本对象**（2026-10-17 P0-A）：本类的互斥链寄存在
/// [KeyedWriteQueue]（按规范路径键的**进程级**注册表）而非实例字段——
/// `MemoryStore.underSupportDir` 等 factory 装配点每次 new 出新实例，若链随实例
/// 走，则同路径的多实例各持一条链，「读-改-写」复合单元交错即**静默丢失更新**。
/// 接入后：同路径一切写入全局串行，且 [settled] 跨实例可见。
library;

import 'dart:io';

import 'keyed_write_queue.dart';

class SequentialFileWriter {
  SequentialFileWriter(this.file);

  /// 目标文件。append 每次按当前路径打开——轮转 rename 走名后追加自动落新档。
  final File file;

  /// 互斥键（文件规范绝对路径）：同路径的一切实例共用同一条链。
  String get _key => KeyedWriteQueue.keyForPath(file.path);

  /// 全量重写落盘（原子替换）。
  Future<void> write(String content) => KeyedWriteQueue.instance.enqueue(
        _key,
        () async {
          final temp = File('${file.path}.tmp');
          await temp.writeAsString(content, flush: true);
          await temp.rename(file.path);
        },
      );

  /// 追加落盘（文件不存在自动创建）。
  Future<void> append(String content) => KeyedWriteQueue.instance.enqueue(
        _key,
        () async {
          await file.writeAsString(content, mode: FileMode.append, flush: true);
        },
      );

  /// 链尾快照（确定性握手）：await 它 = 该**文件**当前已入队的写全部完成。
  ///
  /// 跨实例可见（同路径的其他实例亦在同一条链上）——供测试/资源释放断言替代
  /// 「固定延迟猜等」：全量并发时 CPU 饱和，延迟窗口不够即 flaky（2026-10-16
  /// `memory_kernel_test`×2 存量失败教训）。
  Future<void> get settled => KeyedWriteQueue.instance.settled(_key);
}
