import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/llm/on_device_mem_gate.dart';

/// 起跑闸（MemGate）三档判定回归钉（2026-10-30 步 0 + 场景 C 裁决）。
///
/// 背景：旧水位 4.5GB/5GB 依据「瞬态 ~6GB dmabuf」被 demo 实测推翻（PSS
/// 峰值 2.09GB、MemAvailable 956MB 下装载成功）→ 旧闸门永不可能满足 → 端侧
/// 从未真正起跑（「2 分钟没有首 token」第一直接原因）。本钉锁住新三档语义。
void main() {
  test('余量达标 → 起跑（go）', () {
    expect(
      decideMemGate(
          availRamBytes: kLoadMinAvailRamBytes + (1 << 20),
          threshold: kLoadMinAvailRamBytes),
      MemGateDecision.go,
    );
  });

  test('探针不可用 → 放行（未知 ≠ 已知有害）', () {
    expect(
      decideMemGate(availRamBytes: null, threshold: kLoadMinAvailRamBytes),
      MemGateDecision.go,
    );
  });

  test('高于硬失败线但不足起跑线 → 等待（wait）', () {
    final avail = (kLoadMinAvailRamBytes + kLoadHardFailAvailRamBytes) ~/ 2;
    expect(
      decideMemGate(availRamBytes: avail, threshold: kLoadMinAvailRamBytes),
      MemGateDecision.wait,
    );
  });

  test('跌破 0.9GB 硬失败线 → 放弃本轮（hardFail，终态失败）', () {
    expect(
      decideMemGate(
          availRamBytes: kLoadHardFailAvailRamBytes - 1,
          threshold: kLoadMinAvailRamBytes),
      MemGateDecision.hardFail,
    );
  });

  test('水位常量按实测重定（1.2GB / 1.6GB / 0.9GB）', () {
    expect(kLoadMinAvailRamBytes, 1200 << 20);
    expect(kRetryHighWaterBytes, 1600 << 20);
    expect(kLoadHardFailAvailRamBytes, 900 << 20);
  });

  test('硬失败文案白话且含可行动提示', () {
    final reason = memGateHardFailReason(800 << 20);
    expect(reason, contains('内存不足'));
    expect(reason, contains('清理后台应用'));
  });
}
