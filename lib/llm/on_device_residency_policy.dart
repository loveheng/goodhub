/// 驻留策略位（on-device-residency S-R0-a）：TTL 参数化读取。
///
/// 优先级 = dart-define（测试/诊断钩子，编译期）> SharedPreferences（诊断
/// 注入）> 0（不下发 = 引擎内建缺省 5min，行为零变化）。**红线：5min 缺省
/// 翻动须观测数据支撑**——原始 TTL 覆盖缝退居诊断通路，用户面走 [OnDeviceResidencyStrategy]
/// 档位（smart 不下发任何键 = 缺省零变化；低电/压力归零安全阀引擎侧全档保留）。
/// 设计 SSOT = docs/design/residency-strategy-ui.md。
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// dart-define 诊断钩子键：`--dart-define=ON_DEVICE_RESIDENCY_TTL_MS=30000`。
const String kOnDeviceResidencyTtlMsEnv = 'ON_DEVICE_RESIDENCY_TTL_MS';

/// W6-c 夜间批处理用户开关键（SharedPreferences，默认关闭）。
const String _kNightlyBatchEnabled = 'on_device.nightly_batch_enabled';

/// W6-c：读取夜间批处理开关（默认 false——ADR 拍板"用户可见开关默认关"）。
Future<bool> readNightlyBatchEnabled() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kNightlyBatchEnabled) ?? false;
  } on Object catch (e) {
    debugPrint('[DEGRADE] residency-policy nightly read: $e');
    return false;
  }
}

/// W6-c：写入夜间批处理开关（设置面 toggle 调用）。
Future<void> setNightlyBatchEnabled(bool enabled) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kNightlyBatchEnabled, enabled);
  } on Object catch (e) {
    debugPrint('[DEGRADE] residency-policy nightly write: $e');
  }
}

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

/// P1 用户面驻留策略档位（on-device-residency 策略单源的 Dart 侧镜像）：
/// smart = 不下发（引擎环境矩阵原样，缺省零行为变化）；extended = 驻留更久
/// （宿主主体保底 30min，external 搭便车档不放大）；frugal = 快速释放（上限
/// 1min）。低电/压力归零安全阀在引擎侧短路序最前，全档保留。
enum OnDeviceResidencyStrategy { smart, extended, frugal }

const String _kResidencyStrategy = 'on_device.residency_strategy';

/// 读取用户驻留策略档位（缺省/存储非法值 = smart——矩阵原样零变化）。
Future<OnDeviceResidencyStrategy> readResidencyStrategy() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    return switch (prefs.getString(_kResidencyStrategy)) {
      'extended' => OnDeviceResidencyStrategy.extended,
      'frugal' => OnDeviceResidencyStrategy.frugal,
      _ => OnDeviceResidencyStrategy.smart,
    };
  } on Object catch (e) {
    debugPrint('[DEGRADE] residency-policy strategy read: $e');
    return OnDeviceResidencyStrategy.smart;
  }
}

/// 写入用户驻留策略档位（设置面下拉调用）。
Future<void> setResidencyStrategy(OnDeviceResidencyStrategy strategy) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kResidencyStrategy, strategy.name);
  } on Object catch (e) {
    debugPrint('[DEGRADE] residency-policy strategy write: $e');
  }
}

/// bind 参数组装单源（纯函数）：smart 档不出任何键（缺省零变化）；TTL 诊断
/// 缝 >0 才携带。优先级（引擎侧裁决）= 诊断 TTL > 用户档位 > 矩阵缺省。
Map<String, Object> residencyBindArgs(
  int ttlMs,
  OnDeviceResidencyStrategy strategy,
) =>
    {
      if (ttlMs > 0) 'residencyTtlMs': ttlMs,
      if (strategy != OnDeviceResidencyStrategy.smart)
        'residencyStrategy': strategy.name,
    };

/// UI 文案：档位显示名（人话中文，禁内部枚举名直出）。
String residencyStrategyLabel(OnDeviceResidencyStrategy s) => switch (s) {
      OnDeviceResidencyStrategy.smart => '智能跟随（默认）',
      OnDeviceResidencyStrategy.extended => '驻留更久',
      OnDeviceResidencyStrategy.frugal => '快速释放',
    };

/// UI 文案：档位一句话说明。
String residencyStrategyDescription(OnDeviceResidencyStrategy s) => switch (s) {
      OnDeviceResidencyStrategy.smart => '按电量、灭屏、充电状态自动调节驻留时长',
      OnDeviceResidencyStrategy.extended => '模型用完至少驻留 30 分钟，再次调用免冷启动',
      OnDeviceResidencyStrategy.frugal => '模型用完约 1 分钟即释放内存',
    };
