/// 端侧启用门禁的用户覆盖偏好（架构 §16 的「用户授权覆盖」层）。
///
/// §16 门禁本是保护性闸门（防 OOM / 过热 / 烫）；本覆盖把三道物理门槛
/// （可用 RAM / 电量省电 / 温控）暴露为用户**可选放宽**（各 `ignore*` 开关），
/// 并附「偏好优先端侧」与「紧急强行启用」两位用户显式开关。默认全关（保留
/// 保护）；用户按需开启。持久化于 shared_preferences（沿用 OnDeviceModelSelection
/// 模式），跨启动生效。
///
/// 硬约束：§2 工具面不可绕过（见 HybridCloudEngine）——本覆盖只动门禁与路由意图，
/// 不动工具面判据。RAM 总量 6GB 硬件准入不受 `ignoreAvailRam` 影响（真弱设备
/// 1.5B 也跑不动），绕过它需 `forceOnDevice`（紧急强行，bypass 全部含总量）。
library;

import 'package:shared_preferences/shared_preferences.dart';

/// 端侧启用门禁的用户覆盖偏好（不可变快照）。
class GateOverride {
  const GateOverride({
    this.ignoreAvailRam = false,
    this.ignoreBattery = false,
    this.ignoreThermal = false,
    this.preferOnDevice = false,
    this.forceOnDevice = false,
  });

  /// 忽略「可用 RAM ≥ 2.5GB」门槛（只卡总量 6GB）。**针对 12GB 大内存机**——
  /// 后台占用常把「可用」瞬时压到 2.5GB 以下，导致门禁关闸、端侧起不来。
  final bool ignoreAvailRam;

  /// 忽略电量 / 省电模式门禁。
  final bool ignoreBattery;

  /// 忽略温控门禁。
  final bool ignoreThermal;

  /// 用户偏好优先端侧（云端可用也想走端侧）。
  final bool preferOnDevice;

  /// 紧急强行启用（bypass 全部门禁含 RAM 总量，危险）。
  final bool forceOnDevice;

  GateOverride copyWith({
    bool? ignoreAvailRam,
    bool? ignoreBattery,
    bool? ignoreThermal,
    bool? preferOnDevice,
    bool? forceOnDevice,
  }) =>
      GateOverride(
        ignoreAvailRam: ignoreAvailRam ?? this.ignoreAvailRam,
        ignoreBattery: ignoreBattery ?? this.ignoreBattery,
        ignoreThermal: ignoreThermal ?? this.ignoreThermal,
        preferOnDevice: preferOnDevice ?? this.preferOnDevice,
        forceOnDevice: forceOnDevice ?? this.forceOnDevice,
      );
}

abstract final class OnDeviceGateOverride {
  static const String _kIgnoreAvailRam = 'on_device.gate.ignore_avail_ram';
  static const String _kIgnoreBattery = 'on_device.gate.ignore_battery';
  static const String _kIgnoreThermal = 'on_device.gate.ignore_thermal';
  static const String _kPreferOnDevice = 'on_device.prefer';
  static const String _kForceOnDevice = 'on_device.force';

  /// 读取全量覆盖偏好。读取失败（无存储 / 异常）按全默认（保留保护）处理——
  /// 宁默认勿炸。
  static Future<GateOverride> read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return GateOverride(
        ignoreAvailRam: prefs.getBool(_kIgnoreAvailRam) ?? false,
        ignoreBattery: prefs.getBool(_kIgnoreBattery) ?? false,
        ignoreThermal: prefs.getBool(_kIgnoreThermal) ?? false,
        preferOnDevice: prefs.getBool(_kPreferOnDevice) ?? false,
        forceOnDevice: prefs.getBool(_kForceOnDevice) ?? false,
      );
    } on Object catch (_) {
      return const GateOverride();
    }
  }

  static Future<void> writeIgnoreAvailRam(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kIgnoreAvailRam, v);

  static Future<void> writeIgnoreBattery(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kIgnoreBattery, v);

  static Future<void> writeIgnoreThermal(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kIgnoreThermal, v);

  static Future<void> writePreferOnDevice(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kPreferOnDevice, v);

  static Future<void> writeForceOnDevice(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kForceOnDevice, v);
}
