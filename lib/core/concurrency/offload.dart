/// Worker 卸载统一助手（施工稿 `docs/design/arch-consolidation.md` §S5）。
///
/// **适用范围（先收窄）**：仅**纯 CPU 密集的同步转换**——大型 JSON（反）序列化、
/// 加解密/散列、复杂解析、超长文本正则。普通异步文件 IO **不列**（`dart:io` 由
/// native 线程池驱动，包 `Isolate.run` 反而多两次深拷贝）；「预估耗时」类规则
/// **不立**（闭包耗时不可前置判定，写进规则即退化为人治）。
///
/// 两条硬保证（缺一不可，§S5）：
/// 1. **超时守卫**：沿用 `pii_fence` 的 `Isolate.run(...).timeout()` 范式——超时
///    后调用方 fail-fast，底层 Isolate 自然跑完（不可中断）；失败方向由调用方
///    按 fail-closed 从严处置（coding-standards §4.3）。
/// 2. **在途上限**：超时的 Isolate 仍占 CPU，故池对**僵尸任务**持续占位（槽位
///    在底层 Isolate 真正结束时才释放）——超池快速失败留痕，禁止无限积压。
library;

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:isolate';

/// 卸载阈值（§S5 初值；调参集中此处，不到处散落）。
abstract final class OffloadThresholds {
  /// JSON（反）序列化：文本体积 ≥ 256KB 必卸载。
  static const int jsonBytes = 256 * 1024;

  /// 正则/文本处理：作用文本 ≥ 64KB 必卸载。
  static const int regexTextBytes = 64 * 1024;

  /// 加解密 / 散列：输入 ≥ 128KB 必卸载。
  static const int cryptoBytes = 128 * 1024;

  /// Isolate 入参总字节 ≥ 1MB 时，调用方改用 `TransferableTypedData`
  /// 传大缓冲（避免跨 Isolate 全量深拷贝）——本助手不做自动转移（转移后
  /// 原缓冲不可再用，语义变化须调用方显式决定）。
  static const int transferBytes = 1024 * 1024;
}

/// 卸载判定（按输入体积的可判定谓词，无「预估耗时」）。
enum OffloadKind { json, regexText, crypto }

bool shouldOffload(OffloadKind kind, int inputBytes) => switch (kind) {
      OffloadKind.json => inputBytes >= OffloadThresholds.jsonBytes,
      OffloadKind.regexText => inputBytes >= OffloadThresholds.regexTextBytes,
      OffloadKind.crypto => inputBytes >= OffloadThresholds.cryptoBytes,
    };

/// 池满快速失败（DEGRADE 禁区之外的**背压**语义：调用方自行决定降级方向）。
class OffloadBusyException implements Exception {
  const OffloadBusyException(this.message);

  final String message;

  @override
  String toString() => 'OffloadBusyException: $message';
}

/// 有限并发卸载池。
///
/// 槽位语义：入池即占位，**底层 Isolate 真正结束才释放**——超时弃等不弃占，
/// 僵尸任务不会挤出合法任务的算力配额。
class OffloadPool {
  OffloadPool({this.maxConcurrent = 2, this.tag = 'offload'});

  final int maxConcurrent;
  final String tag;

  int _inFlight = 0;

  /// 共享池（无强隔离需求的调用方复用；需要独立预算的 owner 可自建实例）。
  static final OffloadPool shared = OffloadPool();

  /// 当前在途数（测试断言槽位回收用）。
  int get inFlight => _inFlight;

  /// 在 Worker Isolate 中执行同步闭包；超时 [TimeoutException] 原样上抛
  /// （由调用方决定 fail-closed 方向），其他异常原样透传。
  Future<T> run<T>(T Function() task, {required Duration timeout}) {
    if (_inFlight >= maxConcurrent) {
      throw OffloadBusyException(
          '$tag: 在途 Worker 已满（$maxConcurrent）——快速失败，禁无限积压');
    }
    _inFlight++;
    // 槽位挂在底层 future 上：超时弃等不弃占，Isolate 跑完才释放。
    final inner = Isolate.run(task);
    unawaited(inner.then<void>((_) => _inFlight--, onError: (Object _) {
      _inFlight--;
    }));
    return inner.timeout(timeout);
  }
}

/// 便捷封装：够阈值才卸载，否则主 Isolate 直算。
Future<T> offloadIfHeavy<T>({
  required OffloadKind kind,
  required int inputBytes,
  required T Function() heavy,
  required T Function() light,
  Duration timeout = const Duration(seconds: 3),
  OffloadPool? pool,
}) async {
  final target = pool ?? OffloadPool.shared;
  if (!shouldOffload(kind, inputBytes)) return light();
  try {
    return await target.run(heavy, timeout: timeout);
  } on OffloadBusyException catch (e) {
    // 非数据面降级：池满退主 Isolate 直算（有掉帧风险但保正确性），留痕。
    developer.log('[DEGRADE] offload: 池满退主 isolate: $e');
    return light();
  }
}
