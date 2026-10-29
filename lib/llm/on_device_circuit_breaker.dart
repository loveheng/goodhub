import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

/// 端侧引擎重启风暴两级阶梯熔断（on-device epic S1-6；立法源
/// on-device-npu-deployment.md §6.5 v2.4/v2.6/v2.7）。
///
/// | 级别 | 触发 | 惩罚 | 恢复 |
/// |---|---|---|---|
/// | L1（单进程级，默认） | 5 分钟内连续 Crash ≥ 2 次 | 内存标志，**本进程生命周期**内所有推理走云端 | 杀进程冷启动自愈 |
/// | L2（持久化级） | 当天累计触发 L1 达 2 次 | 持久化时间戳，**锁定 24h** 强制切云 | 24h 过期 / 模型版本更新 / 手动清缓存 |
///
/// **计数口径（§6.5 v2.6 收窄）**：仅本端 NPU 驱动 Panic / 算子越界 abort 计入
/// L1/L2；以下严格不计：① 驱动不兼容（脏删重拉路径）② ION/CMA 分配失败
/// ③ 外部处决（OEM SIGKILL / LMK）。不计入者仍走 [report]（维护 500ms 冷却
/// 窗口），只是不推进熔断计数。
///
/// **驱动释放冷却（§6.5 v2.7）**：进程死亡后 FastRPC 会话拆除存在异步延迟
///（具体毫秒数未官方公布），死亡后 500ms 内阻断本地暖机/生成请求——期间
/// 推理直接走云端，不阻塞用户。
class EngineCircuitBreaker {
  EngineCircuitBreaker({
    Future<String?> Function()? readLock,
    Future<void> Function(String isoDeadline)? writeLock,
    Future<void> Function()? clearLock,
    DateTime Function()? now,
  })  : _readLock = readLock ?? _defaultRead,
        _writeLock = writeLock ?? _defaultWrite,
        _clearLock = clearLock ?? _defaultClear,
        _now = now ?? DateTime.now;

  static const String _lockKey = 'on_device.engine.l2_lock_until';
  static const Duration l1Window = Duration(minutes: 5);
  static const Duration l2LockDuration = Duration(hours: 24);
  static const Duration cooldownWindow = Duration(milliseconds: 500);

  final Future<String?> Function() _readLock;
  final Future<void> Function(String) _writeLock;
  final Future<void> Function() _clearLock;
  final DateTime Function() _now;

  /// L1 内存态：窗口内 crash 时间戳（进程生命周期，冷启动即复位）。
  final List<DateTime> _l1Crashes = [];

  /// L1 触发态（窗口清空后仍须保持熔断，进程生命周期）。
  bool _l1Broken = false;

  /// 当天累计 L1 触发次数（L2 判据）。
  int _l1TriggerCount = 0;
  DateTime? _l1WindowStart;

  /// L2 持久化截止（启动时异步恢复）。
  DateTime? _l2LockUntil;
  bool _lockRestored = false;

  DateTime? _lastDeathAt;

  /// 进程死亡上报。[countable] = 是否计入熔断（§6.5 收窄口径：仅本端驱动
  /// Panic / 算子越界 abort 为 true；SIGKILL/LMK/驱动不兼容/CMA 失败为 false，
  /// 但同样进入冷却窗口）。
  Future<void> report({required bool countable}) async {
    final now = _now();
    _lastDeathAt = now;
    if (!countable) return;
    // L1：5 分钟滑动窗口内连续 crash ≥ 2。
    if (_l1WindowStart == null || now.difference(_l1WindowStart!) > l1Window) {
      _l1WindowStart = now;
      _l1Crashes.clear();
    }
    _l1Crashes.add(now);
    if (_l1Crashes.length < 2) return;

    // L1 触发。
    _l1Broken = true;
    _l1Crashes.clear();
    _l1WindowStart = null;
    _l1TriggerCount++;
    if (_l1TriggerCount < 2) return;

    // L2 触发：持久化 24h 锁。
    final until = now.add(l2LockDuration);
    _l2LockUntil = until;
    _l1TriggerCount = 0;
    try {
      await _writeLock(until.toIso8601String());
    } catch (_) {
      // 持久化失败按内存态兜底（本进程内仍锁定），不阻断切云路径。
    }
  }

  /// 是否处于熔断期（L1 内存态或 L2 持久化态）。熔断期间即便本地有产物
  /// 也不启用端侧（§6.5）；独立于 §4.1 COLD-EVICTED 状态机。
  Future<bool> get isBroken async {
    await _restoreLockIfNeeded();
    final now = _now();
    if (_l2LockUntil != null && now.isBefore(_l2LockUntil!)) return true;
    if (_l2LockUntil != null && now.isAfter(_l2LockUntil!)) {
      _l2LockUntil = null; // 24h 自然过期
    }
    return _l1Broken;
  }

  /// 是否处于 500ms 驱动释放冷却窗口（窗口内阻断暖机/生成，防撞 FastRPC
  /// 僵尸通道 `QNN_COMMON_ERROR_SYSTEM_COMMUNICATION` 族；数值未官方公布，
  /// 500ms 为 §6.5 拍板兜底值）。
  bool get inCooldown {
    final last = _lastDeathAt;
    if (last == null) return false;
    return _now().difference(last) < cooldownWindow;
  }

  /// 复位（§6.5）：模型版本更新（新 hash）或用户手动清缓存解除 L1/L2。
  Future<void> reset() async {
    _l1Crashes.clear();
    _l1WindowStart = null;
    _l1TriggerCount = 0;
    _l1Broken = false;
    _l2LockUntil = null;
    _lastDeathAt = null;
    try {
      await _clearLock();
    } catch (_) {
      // 清理失败不阻断复位语义（内存态已清）。
    }
  }

  Future<void> _restoreLockIfNeeded() async {
    if (_lockRestored) return;
    _lockRestored = true;
    try {
      final raw = await _readLock();
      if (raw != null && raw.isNotEmpty) {
        _l2LockUntil = DateTime.parse(raw);
      }
    } catch (_) {
      // 恢复失败按无锁处理（DEGRADE 语义：宁可重试端侧也不永久锁死）。
    }
  }

  // 默认持久化：shared_preferences（L2 锁时间戳单键）。
  static Future<String?> _defaultRead() async =>
      (await SharedPreferences.getInstance()).getString(_lockKey);

  static Future<void> _defaultWrite(String iso) async =>
      (await SharedPreferences.getInstance()).setString(_lockKey, iso);

  static Future<void> _defaultClear() async =>
      (await SharedPreferences.getInstance()).remove(_lockKey);
}
