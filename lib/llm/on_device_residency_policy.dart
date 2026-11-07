/// 驻留策略位（on-device-residency S-R0-a）：TTL 参数化读取。
///
/// 优先级 = dart-define（测试/诊断钩子，编译期）> SharedPreferences（未来
/// 配置面）> 0（不下发 = 引擎内建缺省 5min，行为零变化）。**红线：本策略位
/// 仅为 L1 策略（R7/R8）备好注入缝——5min 缺省翻动须观测数据支撑**，P0 不
/// 下发任何非缺省值（dart-define 仅诊断构建显式使用）。
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// dart-define 诊断钩子键：`--dart-define=ON_DEVICE_RESIDENCY_TTL_MS=30000`。
const String kOnDeviceResidencyTtlMsEnv = 'ON_DEVICE_RESIDENCY_TTL_MS';

const String _kPrefKey = 'on_device.residency_ttl_ms';

/// 读取驻留 TTL（毫秒；0 = 不下发）。
Future<int> readResidencyTtlMs() async {
  const env = int.fromEnvironment(kOnDeviceResidencyTtlMsEnv);
  if (env > 0) return env;
  try {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_kPrefKey) ?? 0;
  } on Object catch (e) {
    debugPrint('[DEGRADE] residency-policy read: $e');
    return 0;
  }
}
