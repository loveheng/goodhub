/// 驻留观测面（on-device-residency S-R0-b）：Piggyback 事件账本。
///
/// **No Active Polling 红线**：全部打点随路挂接在既有状态迁移事件（装载就绪 /
/// 驱逐 / 进程死亡 / send 腿入口）——零独立线程、零定时器；观测代码本身不得
/// 成为耗电源（采样风格 = P2-11 生成期有界守护线程先例）。
///
/// 落盘 = JSONL（`KeyedWriteQueue` 整本原子写——事件量级低（配额/沿稀疏），
/// 整本重写无压力；超 512 行滚动截半防膨胀）+ logcat 镜像行（`[RESIDENCY]`
/// 前缀，release 可由 capture 通道拉取——`run-as` 被 ROM 拒时的取数路径）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../core/storage/keyed_write_queue.dart';

class OnDeviceResidencyMetrics {
  OnDeviceResidencyMetrics._();

  static final OnDeviceResidencyMetrics instance = OnDeviceResidencyMetrics._();

  /// 测试注入位（目录解析器替换 + 状态重置）。
  OnDeviceResidencyMetrics.forTest(this._dirResolver);

  Future<Directory> Function()? _dirResolver;

  static const String _fileName = 'residency_metrics.jsonl';
  static const int _maxLines = 512;

  /// 事件打点（Piggyback 沿调用）：JSONL 追加 + logcat 镜像。失败仅 DEGRADE
  /// 留痕——观测是旁路面，严禁反噬主路径。
  Future<void> event(String event, Map<String, Object?> fields) async {
    final line = jsonEncode({
      'ts': DateTime.now().toIso8601String(),
      'event': event,
      ...fields,
    });
    debugPrint('[RESIDENCY] $event $fields');
    try {
      final dir =
          await (_dirResolver?.call() ?? getApplicationSupportDirectory());
      final path = '${dir.path}/$_fileName';
      final old = File(path).existsSync()
          ? const LineSplitter().convert(File(path).readAsStringSync())
          : const <String>[];
      final kept = old.length >= _maxLines
          ? old.sublist(old.length - _maxLines ~/ 2)
          : old;
      final body = kept.isEmpty ? line : '${kept.join('\n')}\n$line';
      await KeyedWriteQueue.instance
          .enqueueAtomicWrite(path, utf8.encode('$body\n'));
    } on Object catch (e) {
      debugPrint('[DEGRADE] residency-metrics: $e');
    }
  }

  /// 事件打点（同步场景快捷式——仅 logcat 镜像，不落盘）。
  void eventSync(String event, Map<String, Object?> fields) =>
      debugPrint('[RESIDENCY] $event $fields');
}

/// 进程级单例（llm 域内直用；coordinator 经 legs 打点同源）。
final onDeviceResidencyMetrics = OnDeviceResidencyMetrics.instance;
