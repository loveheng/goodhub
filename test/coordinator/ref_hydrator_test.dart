/// M2.5-T4 HydratingExecutor 单测：$ref 注水语义（§9 时序 + C-2 查无回填）。
/// 钉死三条语义：①目标 Server 永不见 $ref 字符串（注水后零残留）；
/// ②查无/过期立即 isError 不执行（禁挂起等待）；③跨源 fail-closed + 授权卡
/// 摘要消费（单 Server 阶段跨源不可达，语义单测钉住）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/agent_loop.dart';
import 'package:goodhub/coordinator/ref_hydrator.dart';
import 'package:goodhub/coordinator/ref_store.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';

class _RecordingExecutor implements ToolExecutor {
  AssembledToolCall? lastCall;
  int executions = 0;

  @override
  Future<ToolExecutionResult> execute(AssembledToolCall call) async {
    executions++;
    lastCall = call;
    return const ToolExecutionResult(content: 'ok');
  }
}

void main() {
  late Directory tmpDir;
  late RefStore store;
  late _RecordingExecutor inner;
  late HydratingExecutor hydrator;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('hydrator_test_');
    store = RefStore(cacheDir: tmpDir, gcInterval: null);
    inner = _RecordingExecutor();
    hydrator = HydratingExecutor(
      inner: inner,
      refStore: store,
      targetServerId: 'goodshare',
    );
  });

  tearDown(() async {
    await store.expireAll();
    store.dispose();
    await tmpDir.delete(recursive: true);
  });

  AssembledToolCall callOf(Map<String, Object?> args) => AssembledToolCall(
        id: 'c1',
        name: 'some_tool',
        argumentsJson: jsonEncode(args),
      );

  Map<String, Object?> innerArgs() =>
      jsonDecode(inner.lastCall!.argumentsJson) as Map<String, Object?>;

  test('同源静默注水：整值句柄 → 真实载荷，encode 后零 \$ref 残留', () async {
    final handle = await store.put(serverId: 'goodshare', payload: '真实载荷数据');
    final r = await hydrator.execute(callOf({'text': handle, 'n': 1}));
    expect(r.isError, isFalse);
    expect(inner.executions, 1);
    expect(innerArgs()['text'], '真实载荷数据');
    expect(inner.lastCall!.argumentsJson.contains(r'$ref:'), isFalse,
        reason: '§9 语义写死：目标 Server 永不见 \$ref 字符串');
  });

  test('嵌套 Map/List 内的整值句柄同样注水', () async {
    final handle = await store.put(serverId: 'goodshare', payload: '深载荷');
    await hydrator.execute(callOf({
      'outer': {'inner': [handle]},
    }));
    final args = innerArgs();
    expect((args['outer'] as Map)['inner'], ['深载荷']);
  });

  test('非整值（描述性文本内嵌 \$ref: 子串）不注水——误注水防线', () async {
    final handle = await store.put(serverId: 'goodshare', payload: 'x');
    await hydrator.execute(callOf({'note': '见 $handle 的说明'}));
    expect(inner.executions, 1, reason: '无整值句柄 → 透传 inner');
    expect(innerArgs()['note'], '见 $handle 的说明');
  });

  test('查无/过期句柄：立即 isError 回填、inner 不执行（C-2 禁挂起）', () async {
    final r = await hydrator.execute(callOf({'text': r'$ref:goodshare:nope'}));
    expect(r.isError, isTrue);
    expect(r.content, contains(r'$ref:goodshare:nope'));
    expect(inner.executions, 0);
  });

  test('伪造句柄（serverId 不匹配）→ 查无处理，inner 不执行', () async {
    final handle = await store.put(serverId: 'goodshare', payload: 'x');
    final forged = handle.replaceFirst(r'$ref:goodshare:', r'$ref:evil:');
    final r = await hydrator.execute(callOf({'text': forged}));
    expect(r.isError, isTrue);
    expect(inner.executions, 0);
  });

  test('跨源 + delegate 同意 → 注水执行，delegate 收到摘要（禁盲签）', () async {
    final handle = await store.put(serverId: 'otherapp', payload: '标题行\n第二行');
    String? seenPreview;
    final hydrator2 = HydratingExecutor(
      inner: inner,
      refStore: store,
      targetServerId: 'goodshare',
      crossSourceDelegate: (h, from, to, preview) async {
        expect(from, 'otherapp');
        expect(to, 'goodshare');
        seenPreview = preview;
        return true;
      },
    );
    final r = await hydrator2.execute(callOf({'text': handle}));
    expect(r.isError, isFalse);
    expect(seenPreview, contains('标题行'));
    expect(innerArgs()['text'], '标题行\n第二行');
  });

  test('跨源 + delegate 拒绝 → isError 不执行', () async {
    final handle = await store.put(serverId: 'otherapp', payload: 'x');
    final hydrator2 = HydratingExecutor(
      inner: inner,
      refStore: store,
      targetServerId: 'goodshare',
      crossSourceDelegate: (_, __, ___, ____) async => false,
    );
    final r = await hydrator2.execute(callOf({'text': handle}));
    expect(r.isError, isTrue);
    expect(inner.executions, 0);
  });

  test('跨源 + delegate 缺省 → fail-closed 拒绝（D4 无人值守同构）', () async {
    final handle = await store.put(serverId: 'otherapp', payload: 'x');
    final r = await hydrator.execute(callOf({'text': handle}));
    expect(r.isError, isTrue);
    expect(r.content, contains('拒绝注水'));
    expect(inner.executions, 0);
  });

  test('无句柄 / JSON 损坏 → 透传 inner（argumentsJson 原样）', () async {
    const raw = '{"a": 1}';
    await hydrator.execute(AssembledToolCall(id: 'c', name: 't', argumentsJson: raw));
    expect(inner.lastCall!.argumentsJson, raw);

    const broken = '{oops';
    await hydrator.execute(AssembledToolCall(id: 'c', name: 't', argumentsJson: broken));
    expect(inner.lastCall!.argumentsJson, broken, reason: 'JSON 损坏交 face 既有 isError 轨');
  });
}
