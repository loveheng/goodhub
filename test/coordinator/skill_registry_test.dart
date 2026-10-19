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

    test('appScoped() 跨 server 全集投影（记忆看板「MCP 服务 Prompt」总览用）', () {
      final r = SkillRegistry()..registerAll(builtinSkills());
      r.register(_skill('cow/x', SkillScope.appScoped, serverId: 's1'));
      r.register(_skill('cow/y', SkillScope.appScoped, serverId: 's2'));
      expect(
        r.appScoped().map((s) => s.name).toSet(),
        {'goodshare-data', 'cow/x', 'cow/y'},
        reason: '全集含官方预置 + CoW 产物，不含 global/onDemand',
      );
    });
  });

  group('composeSystemPrompt 分层注入', () {
    test('Global 常驻全注入；App-Scoped 只注入已连 Server；On-Demand 只注入已激活', () {
      final r = SkillRegistry()
        ..registerAll(builtinSkills());
      final out = r.composeSystemPrompt('你是 AI 宿主。', publicServerIds: const ['goodshare']);
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
      final out = r.composeSystemPrompt('base', publicServerIds: const ['goodshare']);
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

  group('composeSystemPrompt 确定性拼接（prompt-mgmt Phase 1）', () {
    Skill pub(String name, String serverId, {String content = '正文'}) =>
        _skill(name, SkillScope.appScoped, serverId: serverId, content: content);

    test('注册序无关：乱序注册任意置换均产出字节一致输出', () {
      final skills = [
        _skill('b-global', SkillScope.global),
        pub('z', 'goodshare'),
        _skill('a-global', SkillScope.global),
        pub('y', 'goodshare'),
        _skill('m', SkillScope.appScoped, serverId: 'privA'),
        _skill('k', SkillScope.appScoped, serverId: 'privA'),
      ];
      final out1 = SkillRegistry()..registerAll(skills);
      final out2 = SkillRegistry()..registerAll(skills.reversed);
      final a = out1.composeSystemPrompt('base',
          publicServerIds: const ['goodshare'], activePrivateSlotId: 'privA');
      final b = out2.composeSystemPrompt('base',
          publicServerIds: const ['goodshare'], activePrivateSlotId: 'privA');
      expect(a, b, reason: '注册序变化不得引起字节漂移（前缀缓存稳定）');
    });

    test(r"段内字典序：'${serverId ?? 'global'}:${name}' 严格一致", () {
      final r = SkillRegistry()
        ..registerAll([
          _skill('zz', SkillScope.global),
          _skill('aa', SkillScope.global),
          pub('zeta', 'goodshare'),
          pub('alpha', 'goodshare'),
          _skill('mm', SkillScope.appScoped, serverId: 'privA'),
        ]);
      final out = r.composeSystemPrompt('base',
          publicServerIds: const ['goodshare'], activePrivateSlotId: 'privA');
      int pos(String needle) => out.indexOf(needle);
      expect(pos('### Skill: aa'), lessThan(pos('### Skill: zz')),
          reason: 'global 段按名排序');
      expect(pos('### Skill: alpha'), lessThan(pos('### Skill: zeta')),
          reason: 'appScoped 段按名排序');
      expect(pos('### Skill: zz'), lessThan(pos('### Skill: alpha')),
          reason: '易变度宏序：Global → 公共 → 私有');
      expect(pos('### Skill: alpha'), lessThan(pos('### Skill: mm')),
          reason: '公共段先于私有槽位段');
      expect(out.contains('null:'), isFalse, reason: 'serverId null 归一化为 global，禁裸插值');
    });

    test('空私有槽位：activePrivateSlotId == null 时私有块严格空串，无 \\n\\n\\n 与悬挂换行', () {
      final r = SkillRegistry()
        ..registerAll([
          _skill('g', SkillScope.global),
          pub('p', 'goodshare'),
          _skill('m', SkillScope.appScoped, serverId: 'privA'),
        ]);
      final out = r.composeSystemPrompt('base', publicServerIds: const ['goodshare']);
      expect(out.contains('Skill: m'), isFalse,
          reason: '无激活私有槽位时私有 appScoped 不注入');
      expect(out.contains('\n\n\n'), isFalse, reason: '禁连带空行');
      expect(out.endsWith('\n') || out.endsWith(' '), isFalse, reason: '禁悬挂换行/空格');
      expect(out, isNot(contains('（[privA]）')));
    });

    test('激活私有槽位：私有 appScoped 注入且公共面不变', () {
      final r = SkillRegistry()
        ..registerAll([
          pub('p', 'goodshare'),
          _skill('m', SkillScope.appScoped, serverId: 'privA', content: '私有正文M'),
        ]);
      final withSlot = r.composeSystemPrompt('base',
          publicServerIds: const ['goodshare'], activePrivateSlotId: 'privA');
      final withoutSlot = r.composeSystemPrompt('base',
          publicServerIds: const ['goodshare']);
      expect(withSlot, contains('私有正文M'));
      expect(withoutSlot, isNot(contains('私有正文M')));
      expect(withSlot.contains('### Skill: p'), withSlot.contains('### Skill: p'),
          reason: '公共面不受私有槽位影响');
      expect(withoutSlot.contains('### Skill: p'), isTrue);
    });

    test('空列表恒返回 base 原文：无「宿主 Skills」标题、无多余分隔', () {
      final r = SkillRegistry();
      expect(r.composeSystemPrompt('base'), 'base');
      final r2 = SkillRegistry()..register(_skill('od', SkillScope.onDemand));
      final out = r2.composeSystemPrompt('base');
      expect(out, contains('### 可激活（activate_skill）'),
          reason: '仅有未激活 onDemand 时仍列清单');
      expect(out.startsWith('base\n\n### 可激活'), isTrue);
    });

    test('已激活 On-Demand 段按名排序（激活集 Set 迭代序不外泄）', () {
      final r = SkillRegistry()
        ..registerAll([
          _skill('beta', SkillScope.onDemand),
          _skill('alpha', SkillScope.onDemand),
        ]);
      r.activate('beta');
      r.activate('alpha');
      final out = r.composeSystemPrompt('base');
      expect(out.indexOf('### Skill: alpha（已激活）'),
          lessThan(out.indexOf('### Skill: beta（已激活）')));
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
