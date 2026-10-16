/// 记忆增量日志（context-stepped-pruning §6）：Append-Only 协议 + Squash +
/// 压实语义锚定。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/memory_journal.dart';

void main() {
  test('record：周期内同 key 首次 SET、再次 OVERRIDE、remove → DEL', () {
    final j = MemoryJournal();
    j.record(action: 'upsert', scope: 'user', key: 'env.lang', value: 'python');
    j.record(action: 'upsert', scope: 'user', key: 'env.lang', value: 'go');
    j.record(action: 'remove', scope: 'user', key: 'env.lang', value: '');
    final ops = j.squashed().map((d) => d.op).toList();
    expect(ops, ['del'], reason: 'Squash last-wins：终态 DEL 唯一保留');
  });

  test('squash：last-wins 折叠同 key，保留首现序（只读视图不改日志本体）', () {
    final j = MemoryJournal();
    j.record(action: 'upsert', scope: 'user', key: 'env.os', value: 'mac');
    j.record(action: 'upsert', scope: 'user', key: 'env.lang', value: 'py');
    j.record(action: 'upsert', scope: 'user', key: 'env.os', value: 'linux');
    j.record(action: 'upsert', scope: 'srv:s1', key: 'db.host', value: 'h1');
    final sq = j.squashed();
    // 顺序 = key 首现序（env.os, env.lang, db.host）；值 = 各 key 终态。
    expect(
      sq.map((d) => '${d.scope}.${d.key}=${d.value}').toList(),
      ['user.env.os=linux', 'user.env.lang=py', 'srv:s1.db.host=h1'],
    );
    // 日志本体不被 squash 破坏（追加纪律）。
    expect(j.deltaCount, 4);
  });

  test('renderDeltas：显式标记行格式（squashed 口径）+ 空日志空串', () {
    final j = MemoryJournal();
    expect(j.renderDeltas(), '', reason: '空增量不注 footer');
    j.record(action: 'upsert', scope: 'user', key: 'env.os', value: 'mac');
    j.record(action: 'upsert', scope: 'user', key: 'env.os', value: 'linux');
    j.record(action: 'remove', scope: 'user', key: 'env.tmp', value: '');
    expect(
      j.renderDeltas(),
      '[Recent Memory Updates]\n'
      '- SET user.env.os = linux\n' // 同 key 折叠为终态单行（保留 SET 形态）
      '- DEL user.env.tmp',
    );
  });

  test('renderDeltas（squashed 口径）：同 key 折叠为终态单行', () {
    final j = MemoryJournal();
    j.record(action: 'upsert', scope: 'user', key: 'env.os', value: 'mac');
    j.record(action: 'upsert', scope: 'user', key: 'env.os', value: 'linux');
    expect(
      j.renderDeltas(),
      '[Recent Memory Updates]\n- SET user.env.os = linux',
      reason: '折叠后单行且保留 SET 形态（周期内该 key 首现即 SET）',
    );
  });

  test('compact：store 全量渲染覆盖快照 + 清空增量；快照周期内字节冻结', () {
    final j = MemoryJournal();
    j.record(action: 'upsert', scope: 'user', key: 'k', value: 'v1');
    j.compact('[Established]\n- user.k = v1');
    expect(j.frozenBase, '[Established]\n- user.k = v1');
    expect(j.hasDeltas, isFalse);
    // 压实后新周期：同 key 再次变更从 SET 重新计数。
    j.record(action: 'upsert', scope: 'user', key: 'k', value: 'v2');
    expect(j.squashed().single.op, 'set', reason: '压实清空后首现即 SET');
    expect(j.frozenBase, '[Established]\n- user.k = v1',
        reason: '周期内快照字节级冻结（record 不得触碰）');
  });
}
