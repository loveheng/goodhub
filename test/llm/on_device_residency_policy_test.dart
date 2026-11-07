import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/llm/on_device_residency_policy.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// S-R0-a 回归锚（on-device-residency）：驻留 TTL 策略位——缺省 0（不下发，
/// 引擎内建 5min 零行为变化）+ SharedPreferences 路径。dart-define 分支为
/// 编译期钩子（诊断构建用），单测不可注入，靠代码评审 + 真机冒烟覆盖。
void main() {
  test('缺省：无配置 → 0（不下发，零行为变化）', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await readResidencyTtlMs(), 0);
  });

  test('SharedPreferences 配置 → 原样透传（>0 才有意义）', () async {
    SharedPreferences.setMockInitialValues({'on_device.residency_ttl_ms': 30000});
    expect(await readResidencyTtlMs(), 30000);
  });

  test('配置 ≤0 视为不下发（透传 0/负值原样，引擎侧 >0 守卫兜底）', () async {
    SharedPreferences.setMockInitialValues({'on_device.residency_ttl_ms': -5});
    expect(await readResidencyTtlMs(), -5,
        reason: '策略位忠实透传，正负守卫归引擎侧 updateTtlMs');
  });
}
