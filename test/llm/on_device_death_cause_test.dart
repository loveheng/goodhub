import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/llm/on_device_death_cause.dart';

/// G2-3 墓碑排除法裁定钉（死因可见性 ADR 2026-10-31）：
/// 有栈=硬崩溃；无栈+FLAG_LOADING=LMK；无栈+FLAG_READY=运行期终止；
/// 无 flag=冷启动未知（非快死）。证据缺失维度保守收口。
void main() {
  group('classifyEngineDeath（排除法三态 + 冷启动未知）', () {
    test('崩溃栈在场 = hardCrash（无论 flag 状态——栈的优先级最高）', () {
      expect(
        classifyEngineDeath(
            const TombstoneEvidence(flagState: 'FLAG_READY', hasCrashStack: true)),
        EngineDeathCause.hardCrash,
      );
      expect(
        classifyEngineDeath(
            const TombstoneEvidence(flagState: null, hasCrashStack: true)),
        EngineDeathCause.hardCrash,
      );
    });

    test('无栈 + FLAG_LOADING = lmkSigkill（装载窗口死亡）', () {
      expect(
        classifyEngineDeath(const TombstoneEvidence(
            flagState: 'FLAG_LOADING', hasCrashStack: false)),
        EngineDeathCause.lmkSigkill,
      );
    });

    test('无栈 + FLAG_READY = runtimeTerminated（运行期外部终止）', () {
      expect(
        classifyEngineDeath(const TombstoneEvidence(
            flagState: 'FLAG_READY', hasCrashStack: false)),
        EngineDeathCause.runtimeTerminated,
      );
    });

    test('flag 缺失 = unknownColdStart（冷启动窗口死亡，非快死）', () {
      expect(
        classifyEngineDeath(
            const TombstoneEvidence(flagState: null, hasCrashStack: false)),
        EngineDeathCause.unknownColdStart,
      );
      expect(
        classifyEngineDeath(const TombstoneEvidence(
            flagState: 'FLAG_LOADING', hasCrashStack: null)),
        EngineDeathCause.lmkSigkill,
        reason: '栈证据未知时按 flag 裁定（保守：装载中死亡仍是 LMK 候选）',
      );
    });

    test('未知 flag 取值 = unknownColdStart（禁猜测终态，I2 同族纪律）', () {
      expect(
        classifyEngineDeath(const TombstoneEvidence(
            flagState: 'GARBAGE', hasCrashStack: false)),
        EngineDeathCause.unknownColdStart,
      );
    });
  });
}
