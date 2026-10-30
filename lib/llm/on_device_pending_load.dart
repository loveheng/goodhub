import 'package:shared_preferences/shared_preferences.dart';

/// 端侧「待前台装载」暂存标记（OD4 最小可行闭环，2026-10-30 用户拍板）。
///
/// **场景 B**（未加载冷启动 + 后台任务触发）：**不切云、不报错**，只打本标记
/// 并暂存退出；下次用户进前台时提示「已检测到后台任务，正在为您启动端侧
/// 加速…」，并由前台流程自然触发装载（不自动并发消费暂存任务）。
///
/// 纪律（为何是单标志位而非队列）：
/// - **不做队列子系统**：多任务陈旧积压会引发「过期数据污染」（3 天前的定时
///   分析无价值）与前台「抢嘴」（并发消费多个后台任务撞 `ServiceBusyException`
///   或抢走前台请求的执行槽）；
/// - **前台不自动并发消费**：只提示 + 让前台流程装载，避免后台任务与用户
///   当次对话争抢端侧单执行槽；
/// - **TTL 30min**：过期即丢弃（避免陈旧标记长期误导 UI）。
abstract final class OnDevicePendingLoad {
  static const String _key = 'on_device.pending_foreground_load.at';
  static const Duration ttl = Duration(minutes: 30);

  /// 打标记（后台冷装载触发时）。
  static Future<void> mark() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, DateTime.now().toIso8601String());
    } catch (_) {
      // 标记失败不阻断流程（仅少一次提示）——刻意吞异常。
    }
  }

  /// 剩余有效期（无标记或已过期 → null；过期顺带清标记）。
  static Future<Duration?> remaining() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return null;
      final at = DateTime.tryParse(raw);
      if (at == null) {
        await prefs.remove(_key);
        return null;
      }
      final left = ttl - DateTime.now().difference(at);
      if (left <= Duration.zero) {
        await prefs.remove(_key);
        return null;
      }
      return left;
    } catch (_) {
      return null;
    }
  }

  /// 是否有待前台装载（未过期）。
  static Future<bool> hasPending() async => (await remaining()) != null;

  /// 清除标记（前台已提示并触发装载后消费掉）。
  static Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (_) {
      // 同上：清理失败不阻断。
    }
  }
}
