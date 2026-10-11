/// M2.5-T5 三级 Skill 单测：注册预算硬闸 / 分层注入组装 / 会话粒度激活 /
/// activate_skill 元工具拦截（L1 静默）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/agent_loop.dart';
import 'package:goodhub/coordinator/skill_activation_executor.dart';
import 'package:goodhub/coordinator/skill_registry.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';

Skill _skill(String name, SkillScope scope, {String? serverId, String content = '正文'}) =>
    Skill(
      name: name,
      scope: scope,
      description: '描述 $name',
      content: content,
      source: SkillSource.builtin,
      serverId: serverId,
    );

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
  group('SkillRegistry 注册闸', () {
    test('Global 超 300 Tokens 拒绝（fail-fast，禁静默裁剪）', () {
      final r = SkillRegistry();
      expect(
        () => r.register(_skill('fat', SkillScope.global,
            content: '字' * 301)),
        throwsA(isA<ArgumentError>()),
      );
      r.register(_skill('fit', SkillScope.global, content: '字' * 300));
      expect(r.byName('fit'), isNotNull);
    });

    test('name 重复拒绝（覆盖语义留给 T6 CoW 显式覆写）', () {
      final r = SkillRegistry()..register(_skill('a', SkillScope.global));
      expect(() => r.register(_skill('a', SkillScope.global)),
          throwsA(isA<ArgumentError>()));
    });

    test('仅 appScoped 可绑 serverId（assert 防呆）', () {
      expect(() => _skill('x', SkillScope.global, serverId: 'goodshare'),
          throwsA(isA<AssertionError>()));
    });

    test('builtinSkills 全过预算 + scope 分布齐 + \$ref 正文不被 Dart 插值吞', () {
      final r = SkillRegistry()..registerAll(builtinSkills());
      expect(r.globals().length, 2);
      expect(r.forServer('goodshare').length, 1);
      expect(r.onDemand().length, 1);
      expect(r.byName('ref-pipeline')!.content, contains(r'$ref:'),
          reason: '正文里的 \$ref 字面量必须完整（防插值事故）');
    });
  });

  group('composeSystemPrompt 分层注入', () {
    test('Global 常驻全注入；App-Scoped 只注入已连 Server；On-Demand 只注入已激活', () {
      final r = SkillRegistry()
        ..registerAll(builtinSkills());
      final out = r.composeSystemPrompt('你是 AI 宿主。', connectedServerIds: const ['goodshare']);
      expect(out.startsWith('你是 AI 宿主。'), isTrue, reason: 'base 原样在前');
      expect(out, contains('ref-pipeline'));
      expect(out, contains('task-discipline'));
      expect(out, contains('goodshare-data'));
      expect(out.contains('deep-organize'), isTrue, reason: '未激活 onDemand 只出现在「可激活」清单');
      expect(out, contains('### 可激活（activate_skill）'));
      expect(out.contains('（已激活）'), isFalse);
    });

    test('未连 Server 时 App-Scoped 不注入；On-Demand 激活后进正文并退出可激活清单', () {
      final r = SkillRegistry()..registerAll(builtinSkills());
      final noServer = r.composeSystemPrompt('base');
      expect(noServer.contains('goodshare-data'), isFalse);

      expect(r.activate('deep-organize'), isTrue);
      final out = r.composeSystemPrompt('base', connectedServerIds: const ['goodshare']);
      expect(out, contains('deep-organize（已激活）'));
      expect(out.contains('### 可激活（activate_skill）'), isFalse,
          reason: '唯一 onDemand 已激活，清单清空');
    });

    test('激活集会话粒度：新 registry 实例零激活（§15 会话持有）', () {
      final r1 = SkillRegistry()..registerAll(builtinSkills());
      r1.activate('deep-organize');
      final r2 = SkillRegistry()..registerAll(builtinSkills());
      expect(r2.activated, isEmpty);
      expect(r2.composeSystemPrompt('base').contains('（已激活）'), isFalse);
    });
  });

  group('SkillActivationExecutor 元工具拦截', () {
    late _RecordingExecutor inner;
    late SkillRegistry registry;
    late SkillActivationExecutor executor;

    setUp(() {
      inner = _RecordingExecutor();
      registry = SkillRegistry()..registerAll(builtinSkills());
      executor = SkillActivationExecutor(inner: inner, registry: registry);
    });

    test('activate_skill 拦截：本地激活生效 + inner 不被调（本地工具不外发）', () async {
      final r = await executor.execute(AssembledToolCall(
        id: 'c1',
        name: 'activate_skill',
        argumentsJson: jsonEncode({'name': 'deep-organize'}),
      ));
      expect(r.isError, isFalse);
      expect(registry.activated, contains('deep-organize'));
      expect(inner.executions, 0);
    });

    test('未知 Skill → isError 回填（C-2 同轨，不抛）', () async {
      final r = await executor.execute(AssembledToolCall(
        id: 'c1',
        name: 'activate_skill',
        argumentsJson: jsonEncode({'name': 'nope'}),
      ));
      expect(r.isError, isTrue);
      expect(inner.executions, 0);
    });

    test('缺 name / JSON 损坏 → isError；其他工具原样透传', () async {
      final missing = await executor.execute(AssembledToolCall(
        id: 'c1', name: 'activate_skill', argumentsJson: '{}'));
      expect(missing.isError, isTrue);

      final broken = await executor.execute(AssembledToolCall(
        id: 'c1', name: 'activate_skill', argumentsJson: '{oops'));
      expect(broken.isError, isTrue);

      await executor.execute(AssembledToolCall(
        id: 'c1', name: 'list_items', argumentsJson: '{}'));
      expect(inner.lastCall!.name, 'list_items');
      expect(inner.executions, 1);
    });
  });
}
