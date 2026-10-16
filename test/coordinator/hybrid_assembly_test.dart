/// ux-hardening P2-1：BYOK 读取失败的用户可见性。
/// 历史病：assembleDefaultHybridEngine 的 BYOK 失败仅 debugPrint——用户自带
/// key 失效后效果变差（静默退端侧）而完全不知道为什么。现经 note 通道上轨。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/core/security/flutter_secure_key_value.dart';
import 'package:goodhub/coordinator/hybrid_assembly.dart';
import 'package:goodhub/llm/cloud/byok_store.dart';

/// 读取即抛的假 BYOK 库（模拟安全存储/配置读取失败）。
class _ThrowingByok extends ByokStore {
  _ThrowingByok() : super(secure: FlutterSecureKeyValue());

  @override
  Future<List<ByokProfile>> load() async =>
      throw Exception('安全存储通道不可用');
}

/// 空配置假库（未接入云端 ≠ 错误，不应误报警）。
class _EmptyByok extends ByokStore {
  _EmptyByok() : super(secure: FlutterSecureKeyValue());

  @override
  Future<List<ByokProfile>> load() async => const [];
}

void main() {
  test('P2-1：BYOK 读取失败 → note 通道告知用户（不再仅 debugPrint）', () async {
    final notes = <String>[];
    final engine = await assembleDefaultHybridEngine(
      byokStoreOverride: _ThrowingByok(),
      onNote: (m, {danger = false}) => notes.add(m),
    );
    expect(notes, hasLength(1));
    expect(notes.single, contains('云端模型配置读取失败'));
    expect(engine.cloud, isNull, reason: '退端侧行为不变，但用户现已知情');
  });

  test('空配置（未接入云端）不误报警示', () async {
    final notes = <String>[];
    final engine = await assembleDefaultHybridEngine(
      byokStoreOverride: _EmptyByok(),
      onNote: (m, {danger = false}) => notes.add(m),
    );
    expect(notes, isEmpty, reason: '没配 key = 正常态，不是故障');
    expect(engine.cloud, isNull);
  });
}
