import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/agent_loop.dart';
import 'package:goodhub/coordinator/memory_tool_executor.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/sandbox/memory_store.dart';

class _RecordingInner implements ToolExecutor {
  AssembledToolCall? lastCall;

  @override
  Future<ToolExecutionResult> execute(AssembledToolCall call) async {
    lastCall = call;
    return const ToolExecutionResult(content: 'inner-ok');
  }
}

AssembledToolCall call(String name, [Map<String, Object?> args = const {}]) =>
    AssembledToolCall(id: 'c1', name: name, argumentsJson: jsonEncode(args));

Future<Directory> tmpDir() =>
    Directory.systemTemp.createTemp('memory_tool_test').then((d) async {
      addTearDown(() async {
        if (await d.exists()) await d.delete(recursive: true);
      });
      return d;
    });

/// 审计行直读（JSONL → Map 列表）。
Future<List<Map<String, Object?>>> auditLines(Directory dir) async {
  final f = File('${dir.path}/ops.log');
  if (!await f.exists()) return [];
  return [
    for (final l in await f.readAsLines())
      if (l.isNotEmpty) jsonDecode(l) as Map<String, Object?>,
  ];
}

void main() {
  group('update_memory（写路径，D8 作用域 + §7.3 快照回显）', () {
    test('默认 user 作用域写入：返回落库条目快照 + 沙盒读回保真', () async {
      final dir = await tmpDir();
      final store = MemoryStore(dir: dir);
      final ex = MemoryToolExecutor(inner: _RecordingInner(), store: store);

      final r = await ex.execute(call('update_memory', {
        'content': '用户偏好深色主题',
        'tags': ['pref', 'ui'],
      }));

      expect(r.isError, isFalse);
      final out = jsonDecode(r.content) as Map<String, Object?>;
      expect(out['status'], 'ok');
      expect((out['entry'] as Map)['id'], 'mem_001');
      expect((out['entry'] as Map)['scope'], 'user');
      final saved = (await store.listMemories()).single;
      expect(saved.content, '用户偏好深色主题');
      expect(saved.tags, {'pref', 'ui'});
    });

    test('srv 作用域写入落盘（D8 服务绑定）', () async {
      final dir = await tmpDir();
      final store = MemoryStore(dir: dir);
      final ex = MemoryToolExecutor(inner: _RecordingInner(), store: store);

      final r = await ex.execute(call('update_memory', {
        'content': 'apply 要带 expected_version',
        'scope': 'srv:goodshare',
      }));

      expect(r.isError, isFalse);
      expect((await store.listMemories()).single.scope, 'srv:goodshare');
    });

    test('缺 content / 非法 scope → isError 带 hint（§7.4，模型可自纠）', () async {
      final dir = await tmpDir();
      final ex =
          MemoryToolExecutor(inner: _RecordingInner(), store: MemoryStore(dir: dir));

      final missing = await ex.execute(call('update_memory', {'tags': ['x']}));
      expect(missing.isError, isTrue);
      expect(missing.content, contains('content'));

      final badScope =
          await ex.execute(call('update_memory', {'content': 'x', 'scope': 'global'}));
      expect(badScope.isError, isTrue);
      expect(badScope.content, contains('srv'));
    });

    test('入参 JSON 损坏 → isError（禁抛穿执行环）', () async {
      final dir = await tmpDir();
      final ex =
          MemoryToolExecutor(inner: _RecordingInner(), store: MemoryStore(dir: dir));
      final r = await ex.execute(AssembledToolCall(
          id: 'c1', name: 'update_memory', argumentsJson: '{broken'));
      expect(r.isError, isTrue);
    });
  });

  group('query_memory（只读检索）', () {
    test('q 关键词命中 + scope 过滤 + 空命中结构化空集', () async {
      final dir = await tmpDir();
      final store = MemoryStore(dir: dir);
      final ex = MemoryToolExecutor(inner: _RecordingInner(), store: store);
      await store.remember('用户偏好深色主题', tags: {'pref'});
      await store.remember('goodshare 教训', scope: 'srv:goodshare');

      final hit = await ex.execute(call('query_memory', {'q': '深色'}));
      final hitOut = jsonDecode(hit.content) as Map<String, Object?>;
      expect((hitOut['entries'] as List), hasLength(1));

      final scoped =
          await ex.execute(call('query_memory', {'scope': 'srv:goodshare'}));
      final scopedOut = jsonDecode(scoped.content) as Map<String, Object?>;
      expect(((scopedOut['entries'] as List).single as Map)['scope'],
          'srv:goodshare');

      final none = await ex.execute(call('query_memory', {'q': '不存在'}));
      final noneOut = jsonDecode(none.content) as Map<String, Object?>;
      expect(noneOut['entries'], isEmpty);
      expect(noneOut['note'], isNotNull);
      expect(none.isError, isFalse, reason: '空命中非错误');
    });
  });

  group('透传与审计（N4）', () {
    test('非记忆工具透传 inner，且不落本地审计（remote 归 face 自审计）', () async {
      final dir = await tmpDir();
      final inner = _RecordingInner();
      final ex =
          MemoryToolExecutor(inner: inner, store: MemoryStore(dir: dir));

      final r = await ex.execute(call('list_items'));
      expect(r.content, 'inner-ok');
      expect(inner.lastCall?.name, 'list_items');
      expect(await auditLines(dir), isEmpty);
    });

    test('记忆调用成功/失败都落 ops.log（server=local）', () async {
      final dir = await tmpDir();
      final ex =
          MemoryToolExecutor(inner: _RecordingInner(), store: MemoryStore(dir: dir));

      await ex.execute(call('update_memory', {'content': '事实一'}));
      await ex.execute(call('update_memory', {})); // 缺 content → 失败
      final lines = await auditLines(dir);

      expect(lines, hasLength(2));
      expect(lines[0]['server'], 'local');
      expect(lines[0]['tool'], 'update_memory');
      expect(lines[0]['ok'], true);
      expect(lines[1]['ok'], false);
      expect(lines[1]['error'], isNotNull);
    });
  });
}
