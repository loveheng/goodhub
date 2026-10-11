/// 云端健康降级控制器（architecture §2 降级判据定值；M2-T7 实测调参）。
///
/// 判据（初值，纯状态机无 I/O，单测覆盖全部迁移）：
/// - 传输超时（连接 >[connectTimeout] / 首 Token >[firstTokenTimeout]）**单次即降级**；
/// - 连续 [maxConsecutiveServerErrors] 次 HTTP 5xx/429 降级（其余状态码不计）；
/// - 降级后 [recoveryCooldown] 冷却期内新请求直接走端侧；冷却期满新请求回归云端
///   探活（抢占语义 §2：不影响已开始的推理，仅新任务路由）。
library;

/// 云端健康态。
enum CloudHealth { healthy, degraded }

/// 可注入时钟（单测控制冷却期推进）。
typedef Clock = DateTime Function();

class DegradationController {
  DegradationController({
    this.maxConsecutiveServerErrors = 2,
    this.recoveryCooldown = const Duration(seconds: 30),
    this.connectTimeout = const Duration(seconds: 5),
    this.firstTokenTimeout = const Duration(seconds: 8),
    Clock? now,
  }) : _now = now ?? DateTime.now;

  /// 连接超时判据（引擎构造时取用：硬传输超时，超即 CloudNetworkException）。
  final Duration connectTimeout;

  /// 首 Token 超时判据（也作用于流内事件间隙，兼做卡流检测）。
  final Duration firstTokenTimeout;
  final int maxConsecutiveServerErrors;
  final Duration recoveryCooldown;
  final Clock _now;

  CloudHealth _health = CloudHealth.healthy;
  int _consecutiveServerErrors = 0;
  DateTime? _degradedAt;

  CloudHealth get health => _health;

  /// 当前连续 5xx/429 计数（观测用）。
  int get consecutiveServerErrors => _consecutiveServerErrors;

  /// 新请求是否应走云端（冷却期内 false；冷却期满 true = 允许探活）。
  bool get shouldUseCloud {
    if (_health == CloudHealth.healthy) return true;
    final at = _degradedAt;
    if (at == null) return true;
    return _now().difference(at) >= recoveryCooldown;
  }

  /// HTTP 服务端错误计数；仅 5xx/429 计入（判据口径），计满降级。
  void reportServerError(int statusCode) {
    final serverSide =
        (statusCode >= 500 && statusCode < 600) || statusCode == 429;
    if (!serverSide) return;
    _consecutiveServerErrors++;
    if (_consecutiveServerErrors >= maxConsecutiveServerErrors) {
      _enterDegraded();
    }
  }

  /// 传输超时/连接失败——单次即降级（判据：连接 >5s 或首 Token >8s）。
  void reportTransportTimeout() => _enterDegraded();

  /// 云端整流成功 → 复位计数与降级态（冷却期满探活成功即回归）。
  void reportSuccess() {
    _consecutiveServerErrors = 0;
    _health = CloudHealth.healthy;
    _degradedAt = null;
  }

  void _enterDegraded() {
    _health = CloudHealth.degraded;
    _degradedAt = _now();
    _consecutiveServerErrors = 0;
  }
}
