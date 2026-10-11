/// 设备环境探针快照（§16 门禁数据源，原生 deviceProbe 回传的强类型化）。
///
/// 未知语义（探针不可用 / 平台未实现 / 字段缺失）：字段取 null → [DeviceTierGate]
/// 按「未知 = 放行」处理——门禁是保护性闸门（防烫防耗尽），未知 ≠ 已知有害；
/// RAM 硬门槛兜住真正的弱设备（Android 探针恒可读，iOS 走 FoundationModels 不经此门）。
class DeviceProbe {
  const DeviceProbe({
    this.totalRamBytes,
    this.availRamBytes,
    this.batteryPct,
    this.isCharging,
    this.isPowerSave,
    this.thermalStatus,
  });

  factory DeviceProbe.fromMap(Map<Object?, Object?> m) => DeviceProbe(
        totalRamBytes: (m['totalRamBytes'] as num?)?.toInt(),
        availRamBytes: (m['availRamBytes'] as num?)?.toInt(),
        batteryPct: (m['batteryPct'] as num?)?.toInt(),
        isCharging: m['isCharging'] as bool?,
        isPowerSave: m['isPowerSave'] as bool?,
        thermalStatus: (m['thermalStatus'] as num?)?.toInt(),
      );

  final int? totalRamBytes;
  final int? availRamBytes;
  final int? batteryPct; // -1 = 原生未知
  final bool? isCharging;
  final bool? isPowerSave;
  final int? thermalStatus; // -1 = API < 29 无公开温控 API

  @override
  String toString() =>
      'DeviceProbe(ram=${totalRamBytes == null ? '?' : '${totalRamBytes! >> 20}MB'}'
      '/avail=${availRamBytes == null ? '?' : '${availRamBytes! >> 20}MB'}'
      ', battery=$batteryPct${isCharging == true ? '(充电)' : ''}'
      ', powerSave=$isPowerSave, thermal=$thermalStatus)';
}

/// 设备分级与环境门禁（architecture §16 初值，T7 实测调参）。
///
/// - 硬件准入：RAM 总量 ≥ [minTotalRamBytes] 且可用 ≥ [minAvailRamBytes]，不达标硬性
///   禁用端侧（退化「无网报错提示」，杜绝无差别兜底）；
/// - 环境门禁：电量 < [minBatteryPct] 且未充电、或系统省电模式、或温控 ≥ SEVERE
///   → 端侧抑制（§16「连续推理温控降频→会话级冷却」的会话粒度留 T7 实测定形，
///   M2 初值按逐请求实时探针执行）；
/// - 未知 = 放行（见 [DeviceProbe] 类注释）。
abstract final class DeviceTierGate {
  /// RAM 总量门槛：6GB（§16 评审修正——8GB 会误杀主流中端机）。
  static const int minTotalRamBytes = 6 << 30;

  /// RAM 可用门槛：2.5GB（INT4 1.5B 实测 0.8~1.2GB 权重 + 运行时开销的安全余量）。
  static const int minAvailRamBytes = 2560 << 20; // 2.5GB

  /// 电量门槛：15%（充电豁免）。
  static const int minBatteryPct = 15;

  /// Android PowerManager 温控档位：SEVERE（≥3）即降频明显，抑制端侧。
  static const int _thermalSevere = 3;

  /// §16 初值门禁裁决。pass=false 时 [reason] 给人类可读原因（留痕可观测）。
  static ({bool pass, String reason}) check(DeviceProbe p) {
    final total = p.totalRamBytes;
    if (total != null && total < minTotalRamBytes) {
      return (pass: false, reason: 'RAM ${total >> 20}MB < 6GB 门槛（§16 硬件准入）');
    }
    final avail = p.availRamBytes;
    if (avail != null && avail < minAvailRamBytes) {
      return (pass: false, reason: '可用 RAM ${avail >> 20}MB < 2.5GB 门槛');
    }
    final battery = p.batteryPct;
    if (battery != null && battery >= 0 && battery < minBatteryPct) {
      final charging = p.isCharging;
      if (charging != true) {
        return (pass: false, reason: '电量 $battery% < $minBatteryPct%（未充电）');
      }
    }
    if (p.isPowerSave == true) {
      return (pass: false, reason: '系统省电模式（§16 环境门禁）');
    }
    final thermal = p.thermalStatus;
    if (thermal != null && thermal >= _thermalSevere) {
      return (pass: false, reason: '温控 SEVERE+ 档（status=$thermal，§16 环境门禁）');
    }
    return (pass: true, reason: 'ok');
  }
}
