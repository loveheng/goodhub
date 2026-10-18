/// LocalResourceToolExecutor + 资源附件绑定单测（resource-center M1-T3）。
///
/// 覆盖：binder 落池/footer 形态/失效附件降级；工具执行器 64KB 窗口截断宿主注
/// （RC4）/not_found 结构化 isError（C-2）/参数缺失与坏 JSON/防死循环契约
/// （description + annotations readOnlyHint=false = L2 hint 源）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/agent_loop.dart';
import 'package:goodhub/coordinator/local_resource_tool_executor.dart';
import 'package:goodhub/coordinator/ref_store.dart';
import 'package:goodhub/coordinator/resource_attachment_binder.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/resources/resource_store.dart';

void main() {
  late Directory tmp;
  late ResourceStore store;
  late RefStore refStore;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('local_resource_tool_test');
    store = ResourceStore.underSupportDir(tmp.path);
    refStore = RefStore(cacheDir: tmp);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  AssembledToolCall call(Map<String, Object?> args, {String name = 'read_local_resource'}) =>
      AssembledToolCall(
        id: 't1',
        name: name,
        argumentsJson: args.isEmpty ? '' : '{"resource_id":"${args['resource_id']}"}',
      );

  group('ResourceAttachmentBinder', () {
    test('footer 形态：resource_id + 句柄 + 全文落池（resourceUri 合流）',
        () async {
      final entry = await store.importContent('附件全文', 'a.txt');
      final footer = await bindResourceAttachments(
          store, refStore, [(id: entry.id, name: 'a.txt')]);
      expect(footer, contains('resource_id=${entry.id}'));
      expect(footer, contains('\$ref:local:'));
      expect(footer, contains('<用户附加资源>'));
      // 落池可读回原文（run 级注水通道成立）。
      final handle =
          RegExp(r'\$ref:local:[0-9a-f]+').firstMatch(footer)!.group(0)!;
      expect(await refStore.read(handle), '附件全文');
      expect(refStore.list().single.resourceUri, 'local://resource/${entry.id}');
    });

    test('失效附件降级为「已失效」行，不阻断其余附件', () async {
      final entry = await store.importContent('ok', 'b.txt');
      final footer = await bindResourceAttachments(store, refStore, [
        (id: 'gone', name: 'missing.txt'),
        (id: entry.id, name: 'b.txt'),
      ]);
      expect(footer, contains('《missing.txt》已失效'));
      expect(footer, contains('resource_id=${entry.id}'));
    });

    test('空附件列表返回空串', () async {
      expect(await bindResourceAttachments(store, refStore, const []), '');
    });
  });

  group('LocalResourceToolExecutor', () {
    test('窗口内读取回原文', () async {
      final entry = await store.importContent('正文内容', 'f.txt');
      final exec = LocalResourceToolExecutor(
          inner: _ThrowingExecutor(), store: store);
      final r = await exec.execute(call({'resource_id': entry.id}));
      expect(r.isError, isFalse);
      expect(r.content, '正文内容');
    });

    test('64KB 截断 + 宿主注防死循环明示（RC4）', () async {
      final entry =
          await store.importContent('甲乙丙丁' * 20000, 'big.txt'); // 240KB。
      final exec = LocalResourceToolExecutor(
          inner: _ThrowingExecutor(), store: store);
      final r = await exec.execute(call({'resource_id': entry.id}));
      expect(r.isError, isFalse);
      expect(r.content.length, lessThanOrEqualTo(64 * 1024 + 200));
      expect(r.content, contains('已截断'));
      expect(r.content, contains('严禁对同一 resource_id 重复调用'));
    });

    test('not_found → 结构化 isError + hint（C-2 禁挂起）', () async {
      final exec = LocalResourceToolExecutor(
          inner: _ThrowingExecutor(), store: store);
      final r = await exec.execute(call({'resource_id': 'nope'}));
      expect(r.isError, isTrue);
      expect(r.content, contains('not_found'));
      expect(r.content, contains('hint:'));
    });

    test('参数缺失 / 坏 JSON → bad_request isError', () async {
      final exec = LocalResourceToolExecutor(
          inner: _ThrowingExecutor(), store: store);
      final missing = await exec
          .execute(const AssembledToolCall(id: 't', name: 'read_local_resource', argumentsJson: '{}'));
      expect(missing.isError, isTrue);
      expect(missing.content, contains('bad_request'));
      final bad = await exec.execute(const AssembledToolCall(
          id: 't', name: 'read_local_resource', argumentsJson: 'not-json'));
      expect(bad.isError, isTrue);
    });

    test('非本工具调用透传 inner', () async {
      final exec = LocalResourceToolExecutor(
          inner: _EchoExecutor(), store: store);
      final r = await exec.execute(
          call({'resource_id': 'x'}, name: 'other__tool'));
      expect(r.content, 'echo');
    });

    test('schema 契约：防死循环明示 + readOnlyHint=false（L2 hint 源）', () {
      final schema = LocalResourceToolExecutor.toolSchemas().single;
      expect(schema.name, 'read_local_resource');
      expect(schema.description, contains('严禁对同一 resource_id 重复调用'));
      expect(schema.description, contains('64KB'));
      expect(schema.annotations?['readOnlyHint'], isFalse);
      expect(
        (schema.parametersSchema['properties']
            as Map)['resource_id'],
        isA<Map>(),
      );
    });
  });
}

class _ThrowingExecutor implements ToolExecutor {
  @override
  Future<ToolExecutionResult> execute(AssembledToolCall call) =>
      throw StateError('inner 不应被触达');
}

class _EchoExecutor implements ToolExecutor {
  @override
  Future<ToolExecutionResult> execute(AssembledToolCall call) async =>
      const ToolExecutionResult(content: 'echo');
}
