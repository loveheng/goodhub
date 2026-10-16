/// 记忆治理器（context-stepped-pruning §6，内核层）：Tick 判定矩阵 +
/// 单向栅栏时序 + TTL 注入 clock 行为锚定。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/memory_governor.dart';
import 'package:goodhub/sandbox/memory_store.dart';

void main() {
  late Directory dir;
  late MemoryStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('mem_gov_test');
    store = MemoryStore(dir: Directory('${dir.path}/mem'));
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  test('decideTick 矩阵：首装配必 Tick / 高水位 / 体量突发 / TTL', () {
    var now = DateTime(2026, 10, 16, 12, 0);
    final g = MemoryGovernor(
      clock: () => now,
      ttlMinutes: 5,
      tickRoundWatermark: 12,
      tickTokenBudget: 1000,
    );
    // 首装配必压实（建锚点，无 TTL 信息也不影响）。
    expect(g.decideTick(transcriptRounds: 0, transcriptTokens: 0), isTrue);
    g.journal.compact('BASE');
    // 非 Tick 常态。
    expect(g.decideTick(transcriptRounds: 6, transcriptTokens: 500), isFalse);
    // 轮次高水位命中（>12 严格大于）。
    expect(g.decideTick(transcriptRounds: 12, transcriptTokens: 500), isFalse);
    expect(g.decideTick(transcriptRounds: 13, transcriptTokens: 500), isTrue);
    g.journal.compact('BASE');
    // 体量突发兜底。
    expect(g.decideTick(transcriptRounds: 1, transcriptTokens: 1001), isTrue);
    g.journal.compact('BASE');
    // TTL：未 markRunEnded 不触发；mark 后 <5min 不触发、≥5min 触发。
    expect(g.decideTick(transcriptRounds: 1, transcriptTokens: 10), isFalse);
    g.markRunEnded();
    expect(g.decideTick(transcriptRounds: 1, transcriptTokens: 10), isFalse);
    now = now.add(const Duration(minutes: 4));
    expect(g.decideTick(transcriptRounds: 1, transcriptTokens: 10), isFalse);
    now = now.add(const Duration(minutes: 2));
    expect(g.decideTick(transcriptRounds: 1, transcriptTokens: 10), isTrue);
  });

  test('装配时序（单向栅栏 §6.7）：非 Tick 冻结快照 + footer 只追加', () async {
    final g = MemoryGovernor();
    // 首装配：建锚点。
    final base1 = await g.assembleSystemTail(
      store: store,
      serverScopes: const [],
      transcriptRounds: 0,
      transcriptTokens: 0,
    );
    expect(base1, '', reason: '空 store 渲染空串');
    // 写入记忆 → 本 Run 内 record（onCapsule 只写 pending 池）。
    await store.upsertFacts('env.os', 'mac', scope: 'user');
    // 落盘走 discarded_futures（真实文件 IO），等队列排空再让 Tick 压实读盘。
    await Future<void>.delayed(const Duration(milliseconds: 100));
    g.record(action: 'upsert', scope: 'user', key: 'env.os', value: 'mac');
    // 非 Tick 二次装配：快照不变（字节冻结）、footer 携带 delta。
    final base2 = await g.assembleSystemTail(
      store: store,
      serverScopes: const [],
      transcriptRounds: 1,
      transcriptTokens: 10,
    );
    expect(base2, base1, reason: '非 Tick 周期内快照字节级冻结');
    expect(g.renderFooter(), contains('- SET user.env.os = mac'));
    // Tick（高水位）：store 全量现渲染压实进快照、增量清空。
    final base3 = await g.assembleSystemTail(
      store: store,
      serverScopes: const [],
      transcriptRounds: 13,
      transcriptTokens: 10,
    );
    expect(base3, contains('mac'), reason: '压实后记忆进入冻结快照');
    expect(g.renderFooter(), '', reason: '压实清空增量');
  });

  test('reset：切会话锚点归零（首装配重回必压实）', () async {
    final g = MemoryGovernor();
    await store.upsertFacts('k', 'v', scope: 'user');
    final base = await g.assembleSystemTail(
      store: store,
      serverScopes: const [],
      transcriptRounds: 0,
      transcriptTokens: 0,
    );
    expect(base, isNotEmpty);
    g.reset();
    expect(g.journal.frozenBase, '');
    expect(g.lastRunEndedAt, isNull);
  });
}
