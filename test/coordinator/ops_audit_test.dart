import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/agent_loop.dart';
import 'package:goodhub/coordinator/skill_activation_executor.dart';
import 'package:goodhub/coordinator/skill_registry.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart' show AssembledToolCall;
import 'package:goodhub/sandbox/memory_store.dart';

class _Passthrough implements ToolExecutor {
  @override
  Future<ToolExecutionResult> execute(AssembledToolCall call) async =>
      const ToolExecutionResult(content: 'inner-ok');
}

AssembledToolCall call(String name, [Map<String, Object?> args = const {}]) =>
    AssembledToolCall(id: 'c1', name: name, argumentsJson: jsonEncode(args));

void main() {
  /// activate_skill 拦截分支的 ops.log 审计联动（M4-T2，N4 全链路：本地工具
  /// 自审计 server='local'，与 McpToolFace/MemoryToolExecutor 三点合围全链）。
  group('SkillActivationExecutor 审计（M4-T2）', () {
    Future<Directory> tmpDir() =>
        Directory.systemTemp.createTemp('skill_audit_test').then((d) async {
          addTearDown(() async {
            if (await d.exists()) await d.delete(recursive: true);
          });
          return d;
        });

    Future<List<Map<String, Object?>>> auditLines(Directory dir) async {
      final f = File('${dir.path}/ops.log');
      if (!await f.exists()) return [];
      return [
        for (final l in await f.readAsLines())
          if (l.isNotEmpty) jsonDecode(l) as Map<String, Object?>,
      ];
    }

    test('激活成功/失败落审计；透传调用不落（remote 归 face）', () async {
      final dir = await tmpDir();
      final registry = SkillRegistry()..registerAll(builtinSkills());
      final ex = SkillActivationExecutor(
        inner: _Passthrough(),
        registry: registry,
        opsLog: MemoryStore(dir: dir),
      );

      final ok = await ex.execute(
          call('activate_skill', {'name': 'deep-organize'}));
      expect(ok.isError, isFalse);

      final bad = await ex
          .execute(call('activate_skill', {'name': 'no-such-skill'}));
      expect(bad.isError, isTrue);

      await ex.execute(call('list_items')); // 透传——不在此审计

      final lines = await auditLines(dir);
      expect(lines, hasLength(2));
      expect(lines[0]['server'], 'local');
      expect(lines[0]['tool'], 'activate_skill');
      expect(lines[0]['ok'], true);
      expect(lines[1]['ok'], false);
      expect(lines[1]['error'], contains('no-such-skill'));
    });
  });
}
