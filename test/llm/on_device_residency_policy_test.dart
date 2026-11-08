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

  group('P1 用户面驻留策略档位（residency-strategy-ui）', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('缺省 = smart（矩阵原样，存量零变化钉子）', () async {
      expect(await readResidencyStrategy(), OnDeviceResidencyStrategy.smart);
    });

    test('写入后读回一致（三档回路）', () async {
      await setResidencyStrategy(OnDeviceResidencyStrategy.extended);
      expect(await readResidencyStrategy(), OnDeviceResidencyStrategy.extended);
      await setResidencyStrategy(OnDeviceResidencyStrategy.frugal);
      expect(await readResidencyStrategy(), OnDeviceResidencyStrategy.frugal);
      await setResidencyStrategy(OnDeviceResidencyStrategy.smart);
      expect(await readResidencyStrategy(), OnDeviceResidencyStrategy.smart);
    });

    test('非法存储值回落 smart（白名单解析）', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('on_device.residency_strategy', 'bogus');
      expect(await readResidencyStrategy(), OnDeviceResidencyStrategy.smart);
    });

    test('bind 键组装：smart 不出档位键（缺省零变化）', () {
      expect(residencyBindArgs(0, OnDeviceResidencyStrategy.smart), isEmpty);
      expect(residencyBindArgs(30000, OnDeviceResidencyStrategy.smart),
          {'residencyTtlMs': 30000},
          reason: 'TTL 诊断缝独立于档位（>0 才携带）');
    });

    test('bind 键组装：非 smart 档只出档位键（矩阵在引擎侧自算）', () {
      expect(residencyBindArgs(0, OnDeviceResidencyStrategy.extended),
          {'residencyStrategy': 'extended'});
      expect(residencyBindArgs(0, OnDeviceResidencyStrategy.frugal),
          {'residencyStrategy': 'frugal'});
    });

    test('UI 文案三档全覆盖（禁内部枚举名直出，ui-design §2）', () {
      for (final s in OnDeviceResidencyStrategy.values) {
        expect(residencyStrategyLabel(s), isNotEmpty);
        expect(residencyStrategyLabel(s), isNot(contains(s.name)));
        expect(residencyStrategyDescription(s), isNotEmpty);
      }
    });
  });
}
