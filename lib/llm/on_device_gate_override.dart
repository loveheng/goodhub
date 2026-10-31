/// 端侧路由的用户覆盖偏好（架构 §16 的「用户授权覆盖」层）。
///
/// **2026-10-31 裁决：路由门禁层降级 advisory（不拦截）**——RAM/电量/温控
/// 门槛的判定结果只留痕提示，不再拦路；真保护 = 运行时护栏链（:engine 进程
/// 隔离 + EngineDied→切云 + 两级熔断 + 内存护栏驱逐 + 装载期内存监控 +
/// MemGate 起跑闸/硬失败线 + :engine 温控连续确认沿）。误判史（RAM 门槛对
/// 常驻态自锁 / SoC 热档≠壳温 / 探测异常保守关闸）多次实证拦截成本高于收益，
/// 「紧急强行启用」与各 `ignore*` 放宽开关随门禁拦截语义一并退役。
///
/// 硬约束：§2 工具面不可绕过（见 HybridCloudEngine）。持久化于
/// shared_preferences（沿用 OnDeviceModelSelection 模式），跨启动生效。
library;

import 'package:shared_preferences/shared_preferences.dart';

/// 端侧路由的用户覆盖偏好（不可变快照）。
class GateOverride {
  const GateOverride({this.preferOnDevice = false});

  /// 用户偏好优先端侧（云端可用也想走端侧）。
  final bool preferOnDevice;

  GateOverride copyWith({bool? preferOnDevice}) =>
      GateOverride(preferOnDevice: preferOnDevice ?? this.preferOnDevice);
}

abstract final class OnDeviceGateOverride {
  static const String _kPreferOnDevice = 'on_device.prefer';

  /// 读取覆盖偏好。读取失败（无存储 / 异常）按全默认处理——宁默认勿炸。
  /// 历史键（on_device.gate.ignore_* / on_device.force）已随门禁拦截语义
  /// 退役，不再读取（stale 值自然失效，无需迁移）。
  static Future<GateOverride> read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return GateOverride(
        preferOnDevice: prefs.getBool(_kPreferOnDevice) ?? false,
      );
    } on Object catch (_) {
      return const GateOverride();
    }
  }

  static Future<void> writePreferOnDevice(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kPreferOnDevice, v);
}
