/// 受理期保活件（ai-capability-export M-B · 从受理链拆出的独立机械件）。
///
/// 引用计数语义：每个持保活的外部任务计 1，任务终态 / cancel / 调用方死亡
/// 任一触发 → [SupplyKeepalive.letGo]（三钥匙在受理链里汇于同一条任务收尾
/// 路径）。防抖红线（设计稿 §6.3）：仅冷装载窗口持有——`WARM_STANDBY` 短任务
/// 零通知零保活；平台侧（EngineServiceBridge）另带 15min 硬超时兜底键泄漏。
library;

import 'package:flutter/foundation.dart' show debugPrint;

/// 受理期保活（三钥匙释放的机械承载）。
///
/// **引用计数语义**：每个持保活的外部任务计 1，任务终态 / cancel / 调用方
/// 死亡任一触发 → [release]（三钥匙在受理链里汇于同一条任务收尾路径）。
/// **防抖红线（设计稿 §6.3）**：仅冷装载窗口持有——`WARM_STANDBY` 短任务
/// 零通知零保活；平台侧（EngineServiceBridge）另带 15min 硬超时兜底键泄漏。
class SupplyKeepalive {
  SupplyKeepalive({this.acquire, this.release});

  /// 平台挂钩（null = 未装配，纯计数空转——单测注入点）。
  final Future<void> Function(String key)? acquire;
  final Future<void> Function(String key)? release;

  final Set<String> _held = {};

  int get heldCount => _held.length;

  Future<void> hold(String key) async {
    if (!_held.add(key)) return;
    try {
      await acquire?.call(key);
    } on Object catch (e) {
      debugPrint('[DEGRADE] ai-keepalive acquire($key): $e');
    }
  }

  Future<void> letGo(String key) async {
    if (!_held.remove(key)) return;
    try {
      await release?.call(key);
    } on Object catch (e) {
      debugPrint('[DEGRADE] ai-keepalive release($key): $e');
    }
  }
}
