import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/sandbox/workspace_state_store.dart';

/// P2-1（G3 / §9.5）：会话级事实库——upsert 整行覆盖 / remove / 损坏兜底 /
/// per-conversation 隔离。
void main() {
  late Directory tmp;
  late Directory dir;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('workspace_state_test');
    dir = Directory('${tmp.path}/workspace_states');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  WorkspaceStateStore build() => WorkspaceStateStore(dir: dir);

  test('upsert 写入并可读回；同 key 整行覆盖（INSERT OR REPLACE 语义）', () async {
    final store = build();
    await store.upsert('conv1', 'page_size', '20');
    await store.upsert('conv1', 'api.method', 'GET');

    var all = await store.all('conv1');
    expect(all['page_size']!.value, '20');
    expect(all['api.method']!.value, 'GET');

    // 同 key 覆盖：不留旧条目（D-K：回归主键冲突整行替换）。
    final oldTs = all['page_size']!.updatedAtMs;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await store.upsert('conv1', 'page_size', '50');
    all = await store.all('conv1');
    expect(all, hasLength(2), reason: '同 key 覆盖不追加');
    expect(all['page_size']!.value, '50');
    expect(all['page_size']!.updatedAtMs, greaterThan(oldTs));
  });

  test('remove 删除指定 key；key 不存在幂等不抛', () async {
    final store = build();
    await store.upsert('conv1', 'k', 'v');
    await store.remove('conv1', 'k');
    expect(await store.all('conv1'), isEmpty);

    // 幂等：再删不抛。
    await store.remove('conv1', 'k');
    await store.remove('conv1', 'never-existed');
  });

  test('per-conversation 隔离：不同会话文件互不可见', () async {
    final store = build();
    await store.upsert('conv1', 'fact', 'a');
    await store.upsert('conv2', 'fact', 'b');
    expect((await store.all('conv1'))['fact']!.value, 'a');
    expect((await store.all('conv2'))['fact']!.value, 'b');
  });

  test('文件缺失 → 空表（首启形态）', () async {
    expect(await build().all('conv_none'), isEmpty);
  });

  test('损坏文件 → 空表（宁空勿炸，可重新沉淀）', () async {
    await dir.create(recursive: true);
    File('${dir.path}/conv_bad.json').writeAsStringSync('{not-json');
    expect(await build().all('conv_bad'), isEmpty);
  });

  test('conversation_id 含路径分隔符 / .. → ArgumentError（文件名锚防御）',
      () async {
    final store = build();
    for (final bad in ['a/b', r'a\b', '..', 'a/../b']) {
      expect(() => store.upsert(bad, 'k', 'v'), throwsArgumentError,
          reason: '非法 id: $bad');
    }
  });

  test('串行链：并发 upsert 不交错丢写（读-改-写排队）', () async {
    final store = build();
    await Future.wait([
      for (var i = 0; i < 20; i++) store.upsert('conv1', 'k$i', 'v$i'),
    ]);
    final all = await store.all('conv1');
    expect(all, hasLength(20), reason: '20 个不同 key 全部落盘');
  });
}
