/// 云端健康降级控制器（architecture §2 降级判据定值；M2-T7 实测调参）。
///
/// 判据（初值，纯状态机无 I/O，单测覆盖全部迁移）：
/// - 传输超时（连接 >[connectTimeout] / 首 Token >[firstTokenTimeout] / 流内间隙
///   >[interEventGapTimeout] 自适应窗口）**单次即降级**；流内间隙不再用固定 30s
///   死计时——改由传输层字节活体（含 SSE 心跳）重置、随请求已耗时放宽、**无上限**
///   （[maxThinkingGap] 已移除）：活体连接永不掐断，长思考不误杀，仅真死连接被
///   兜底下限捕获，其余交给人工「中止」（见 [HybridCloudEngine._cloudSend]）；
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
    this.interEventGapTimeout = const Duration(seconds: 120),
    Clock? now,
  }) : _now = now ?? DateTime.now;

  /// 连接超时判据（引擎构造时取用：硬传输超时，超即 CloudNetworkException）。
  final Duration connectTimeout;

  /// 首 Token 超时判据（连接→首个可见事件的静默上限，死连接快速判定）。
  final Duration firstTokenTimeout;

  /// 流内事件间隙判据的**下限**（两事件/字节之间最大静默；超时才判卡流/降级）。
  /// 旧逻辑把它当固定 30s 死计时，思考期模型不产 token 即被误杀；现改为
  /// 「传输层字节活体 + 自适应预算」：心跳帧（SSE 注释）触发的 [CloudLlmEngine.send]
  /// 的 [onActivity] 会重置计时（存活即不触发），且预算随请求已耗时放宽、**无上限**
  /// （[maxThinkingGap] 已移除），故本字段仅作真死连接兜底下限（见 [HybridCloudEngine]）。
  final Duration interEventGapTimeout;

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

  /// 传输超时/连接失败——单次即降级（判据：连接 >5s、首 Token >8s、流内间隙 >${interEventGapTimeout.inSeconds}s）。
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
