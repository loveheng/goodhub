import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/llm/on_device_engine.dart';
import 'package:goodhub/llm/on_device_ready_gate.dart';

/// 就绪闸单测（on-device S2 正式接线）：bind 时序竞态收口逻辑——
/// 未就绪超时快速失败 / 就绪事件解除挂起 / 死亡事件作废过期就绪态。
void main() {
  group('waitReady 超时快速失败', () {
    test('未就绪 + 短超时 → null（禁死等）', () async {
      final gate = EngineReadyGate();
      expect(gate.isReady, isFalse);
      final r = await gate.waitReady(timeout: const Duration(milliseconds: 50));
      expect(r, isNull);
    });
  });

  group('就绪事件收口', () {
    test('noteReady 后 waitReady 即时返回记录态（isReady=true）', () async {
      final gate = EngineReadyGate();
      gate.noteReady(EngineStatus.ready.index); // 0
      expect(gate.isReady, isTrue);
      final r = await gate.waitReady(timeout: const Duration(milliseconds: 50));
      expect(r, EngineStatus.ready);
    });

    test('挂起中的等待被 noteReady 解除（真实竞态序列：bind→挂起→事件到达）',
        () async {
      final gate = EngineReadyGate();
      final pending = gate.waitReady(timeout: const Duration(seconds: 5));
      // 事件在挂起 20ms 后到达（模拟 onServiceConnected 异步完成）
      await Future<void>.delayed(const Duration(milliseconds: 20));
      gate.noteReady(EngineStatus.assetMissing.index); // 2
      expect(await pending, EngineStatus.assetMissing);
    });

    test('重复 noteReady 幂等（首个事件为准）', () async {
      final gate = EngineReadyGate();
      gate.noteReady(EngineStatus.assetMissing.index);
      gate.noteReady(EngineStatus.ready.index);
      expect(await gate.waitReady(), EngineStatus.assetMissing);
    });

    test('越界序数折算 unsupportedDevice（防跨端漂移崩溃）', () async {
      final gate = EngineReadyGate();
      gate.noteReady(99);
      expect(await gate.waitReady(), EngineStatus.unsupportedDevice);
    });
  });

  group('死亡事件作废（禁以过期就绪态放行）', () {
    test('noteReady → noteGone → 未就绪，须等新事件', () async {
      final gate = EngineReadyGate();
      gate.noteReady(EngineStatus.ready.index);
      gate.noteGone();
      expect(gate.isReady, isFalse);
      expect(await gate.waitReady(timeout: const Duration(milliseconds: 50)),
          isNull);
    });

    test('作废后新 noteReady 恢复（进程重连重 init 序列）', () async {
      final gate = EngineReadyGate();
      gate.noteReady(EngineStatus.ready.index);
      gate.noteGone();
      gate.noteReady(EngineStatus.assetMissing.index);
      expect(gate.isReady, isTrue);
      expect(await gate.waitReady(), EngineStatus.assetMissing);
    });

    test('noteGone 幂等（重复死亡事件不破坏闸状态）', () async {
      final gate = EngineReadyGate();
      gate.noteGone();
      gate.noteGone();
      gate.noteReady(EngineStatus.ready.index);
      expect(await gate.waitReady(), EngineStatus.ready);
    });
  });
}
