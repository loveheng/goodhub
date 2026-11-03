// CapabilityRequirement 回归钉（task-capability W2 · S13）。
//
// 红线：缺省一律保守侧（宁可选云端，不误判端侧可用）——缺省行为本身
// 是被测对象；缺省变更须同步改这里（设计稿 on-device-task-capability.md
// §4.1「缺省行为本身是被测对象」）。
import 'package:goodhub/core/capability_requirement.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('缺省保守侧（红线回归钉）', () {
    test('缺省 needsTools = true（保守取「需要」，端侧放行被挡）', () {
      expect(CapabilityRequirement().needsTools, isTrue);
    });

    test('缺省 latencyClass = batch（不误判端侧可等）', () {
      expect(CapabilityRequirement().latencyClass, LatencyClass.batch);
    });

    test('缺省 tokenBudget = null（不预留余量，由对照表与资产窗口裁决）', () {
      expect(CapabilityRequirement().tokenBudget, isNull);
    });

    test('缺省 preferLocal = false / localOnly = false / canRunOffline = false',
        () {
      final r = CapabilityRequirement();
      expect(r.preferLocal, isFalse);
      expect(r.localOnly, isFalse, reason: '缺省不禁止云端——云端是产出基线');
      expect(r.canRunOffline, isFalse);
      expect(r.payloadScale, PayloadScale.medium);
    });

    test('conservative 常量与缺省构造等价', () {
      expect(CapabilityRequirement.conservative, CapabilityRequirement());
    });
  });

  group('字段语义（K10 正交性 / K15 / S15 优先级）', () {
    test('localOnly 与 canRunOffline 正交：可同时为真（离线且不出境）', () {
      const r = CapabilityRequirement(canRunOffline: true, localOnly: true);
      expect(r.canRunOffline, isTrue);
      expect(r.localOnly, isTrue);
    });

    test('needsStructuredOutput 显式为真可声明（端侧须约束解码承载 S17b）',
        () {
      const r = CapabilityRequirement(needsStructuredOutput: true);
      expect(r.needsStructuredOutput, isTrue);
    });

    test('显式声明覆盖缺省（needsTools=false = 声明无需工具）', () {
      const r = CapabilityRequirement(needsTools: false);
      expect(r.needsTools, isFalse);
    });
  });

  group('值对象等价与校验', () {
    test('全字段相等 → == 为真且 hashCode 一致', () {
      const a = CapabilityRequirement(tokenBudget: 1024, preferLocal: true);
      const b = CapabilityRequirement(tokenBudget: 1024, preferLocal: true);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('任一字段差异 → 不等', () {
      const a = CapabilityRequirement();
      const b = CapabilityRequirement(needsTools: false);
      expect(a == b, isFalse);
    });

    test('tokenBudget 非正值被拒绝（debug assert）', () {
      expect(
        () => CapabilityRequirement(tokenBudget: 0),
        throwsA(anyOf(isA<AssertionError>(), isA<ArgumentError>())),
      );
    });
  });
}
