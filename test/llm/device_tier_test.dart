import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/llm/device_tier.dart';

void main() {
  DeviceProbe probe({
    int? totalRamBytes = 8 << 30,
    int? availRamBytes = 4 << 30,
    int? batteryPct = 80,
    bool? isCharging = false,
    bool? isPowerSave = false,
    int? thermalStatus = 0,
  }) =>
      DeviceProbe(
        totalRamBytes: totalRamBytes,
        availRamBytes: availRamBytes,
        batteryPct: batteryPct,
        isCharging: isCharging,
        isPowerSave: isPowerSave,
        thermalStatus: thermalStatus,
      );

  test('健康设备全维放行', () {
    final v = DeviceTierGate.check(probe());
    expect(v.pass, isTrue);
    expect(v.reason, 'ok');
  });

  test('RAM 总量 < 6GB 硬性禁用（§16 硬件准入）', () {
    final v = DeviceTierGate.check(probe(totalRamBytes: 4 << 30));
    expect(v.pass, isFalse);
    expect(v.reason, contains('6GB'));
  });

  test('RAM 可用 < 2.5GB 禁用', () {
    final v = DeviceTierGate.check(probe(availRamBytes: 2 << 30));
    expect(v.pass, isFalse);
    expect(v.reason, contains('2.5GB'));
  });

  test('会话常驻豁免：availMem < 2.5GB 但驻留 → 放行（S2 自锁修正）', () {
    final v = DeviceTierGate.check(
      probe(availRamBytes: 2 << 30),
      sessionResident: true,
    );
    expect(v.pass, isTrue, reason: '权重已驻留，冷加载门槛对驻留态失义');
  });

  test('会话常驻不豁免总量/温控（保护语义不变）', () {
    final total = DeviceTierGate.check(
      probe(totalRamBytes: 4 << 30),
      sessionResident: true,
    );
    expect(total.pass, isFalse);
    expect(total.reason, contains('6GB'));

    final thermal = DeviceTierGate.check(
      probe(thermalStatus: 3),
      sessionResident: true,
    );
    expect(thermal.pass, isFalse);
    expect(thermal.reason, contains('温控'));
  });

  test('电量 < 15% 且未充电 → 禁用；充电豁免', () {
    final low = DeviceTierGate.check(probe(batteryPct: 14));
    expect(low.pass, isFalse);
    expect(low.reason, contains('14%'));

    final charging = DeviceTierGate.check(probe(batteryPct: 5, isCharging: true));
    expect(charging.pass, isTrue);
  });

  test('省电模式 → 禁用', () {
    final v = DeviceTierGate.check(probe(isPowerSave: true));
    expect(v.pass, isFalse);
    expect(v.reason, contains('省电'));
  });

  test('温控 SEVERE（≥3）→ 禁用；MODERATE 放行', () {
    expect(DeviceTierGate.check(probe(thermalStatus: 3)).pass, isFalse);
    expect(DeviceTierGate.check(probe(thermalStatus: 2)).pass, isTrue);
  });

  test('未知字段一律放行（门禁为保护性闸门，未知 ≠ 已知有害）', () {
    final v = DeviceTierGate.check(DeviceProbe(
      totalRamBytes: null,
      availRamBytes: null,
      batteryPct: -1, // 原生未知
      isCharging: null,
      isPowerSave: null,
      thermalStatus: -1, // API < 29
    ));
    expect(v.pass, isTrue);
  });

  test('探针整体缺失（null→全空 DeviceProbe）等价放行', () {
    final v = DeviceTierGate.check(const DeviceProbe());
    expect(v.pass, isTrue);
  });
}
