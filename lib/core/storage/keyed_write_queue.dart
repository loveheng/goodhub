/// 进程级「按路径键」的串行写队列注册表（File Mutex 的真实实现层）。
///
/// **为什么要有这一层**：`SequentialFileWriter` 自述为「File Mutex 降格实现」，
/// 但它的互斥链 `_tail` 是**实例字段**——互斥粒度实际是「对象」而非「文件」。
/// 而 `MemoryStore.underSupportDir` / `WorkspaceStateStore.underSupportDir` /
/// `ConversationStore.underSupportDir` 全是 factory，每次调用 new 出新实例，
/// 于是同路径的写落到多条互不相干的链上：
///
/// ```
/// main.dart:74 / gateway_controller.dart:147 / chat_page.dart:708,712
///   / memory_board_page.dart:60   →   五个实例，五条链，同一批文件
/// ```
///
/// 「读-改-写」复合单元交错即**静默丢失更新**（用户记忆/会话事实被覆盖且无痕）。
/// 本注册表把互斥键从对象身份换成**规范路径**，使同路径的一切写入全局串行；
/// 依赖它的两层都须接入：
///
/// - `SequentialFileWriter`（单次 write/append 的原子落盘）；
/// - `MemoryStore` / `WorkspaceStateStore` 的**复合读-改-写单元**——只串行化
///   底层 write 不够：两个实例仍会各自读到同一份旧内容、最后一次写覆盖前一次。
///
/// 规格补记（coding-standards §5.1）：跨 App 沙盒不共享文件系统（§11），本队列
/// 仍是**单进程内**串行语义，多进程同写不受保护（既有硬约束，非本轮改动面）。
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

/// 按路径键排队的串行写队列注册表（进程级单例）。
///
/// 语义与 `SequentialFileWriter._enqueue` 同口径：单次失败**向调用方透传异常，
/// 但不毒化队列**（续链与透传分离）；链排空且无后继时**惰性除名**，防长会话
/// 累积（key 数稳态应为 0）。
class KeyedWriteQueue {
  KeyedWriteQueue._();

  /// 进程级唯一注册表。
  static final KeyedWriteQueue instance = KeyedWriteQueue._();

  /// 路径 → 链尾（仅存**在途**链；排空即除名）。
  final Map<String, Future<void>> _tails = <String, Future<void>>{};

  /// 互斥键：规范绝对路径（同路径的一切实例共用同一条链）。
  ///
  /// 用 `File.absolute` 做同步规范化（不引 async 的 `canonicalize`）：Android
  /// 单平台、路径均由调用方以绝对路径给出，规范化只为消除 `./`、`..` 差异。
  static String keyForPath(String path) => File(path).absolute.path;

  /// 当前在途链数（测试断言「惰性回收」用；生产稳态应为 0）。
  @visibleForTesting
  int get keyCount => _tails.length;

  /// 排队执行 [task]：返回透传结果与异常的 future，链本身吞错仅为续链。
  Future<T> enqueue<T>(String key, Future<T> Function() task) {
    final prev = _tails[key] ?? Future<void>.value();
    final result = prev.then((_) => task());
    final chain = result.then<void>((_) {}, onError: (Object _) {});
    _tails[key] = chain;
    // 惰性回收：仅当自己仍是链尾才除名——期间有新任务入队则 `_tails[key]`
    // 已被替换，identical 判否，让位给后入的链去收尾。
    chain.whenComplete(() {
      if (identical(_tails[key], chain)) _tails.remove(key);
    });
    return result;
  }

  /// 链尾快照（确定性握手）：await 它 = 该键**当前已入队**的全部任务完成。
  ///
  /// **跨实例可见**——同路径的其他实例也排在同一条链上，故可替代「固定延迟
  /// 猜等」（2026-10-16 `memory_kernel_test`×2 全仓并发 flaky 的存量教训）。
  /// 内部带收敛循环：await 期间若又有新任务入队，继续等新链尾，避免漏等。
  Future<void> settled(String key) async {
    while (true) {
      final pending = _tails[key];
      if (pending == null) return;
      await pending;
      if (identical(_tails[key], pending)) return;
    }
  }
}
