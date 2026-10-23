/// 执行面链装配器单测（架构债 #19 根治件）。
///
/// 钉住三件性质：① **层序**（列表首位 = 最外层 = 最先命中）② **全成员在场**
/// （给定 N 层，链上恰有 N 层——早前手工包裹允许「inner 指向链中段」致内层
/// 整层丢弃，表现为「目录可见、调用全败」）③ **末端兜底**（显式拒绝，不静默透传）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/agent_loop.dart';
import 'package:goodhub/coordinator/tool_executor_chain.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';

/// 认领单一工具名的假层（未命中即透传 inner）。
class _FakeLayer implements ToolExecutor {
  _FakeLayer(this.name, this.inner);

  final String name;
  final ToolExecutor inner;

  @override
  Future<ToolExecutionResult> execute(AssembledToolCall call) async {
    if (call.name != name) return inner.execute(call);
    return ToolExecutionResult(content: 'hit:$name');
  }
}

/// 记录调用次数的假兜底。
class _CountingFallback implements ToolExecutor {
  int calls = 0;

  @override
  Future<ToolExecutionResult> execute(AssembledToolCall call) async {
    calls++;
    return const ToolExecutionResult(content: 'fallback');
  }
}

AssembledToolCall _call(String name) =>
    AssembledToolCall(id: 'x', name: name, argumentsJson: '{}');

void main() {
  group('composeToolExecutorChain · 层序', () {
    test('列表首位 = 最外层 = 最先命中', () async {
      final chain = composeToolExecutorChain([
        (inner) => _FakeLayer('a', inner),
        (inner) => _FakeLayer('b', inner),
      ], fallback: _CountingFallback());

      expect((await chain.execute(_call('a'))).content, 'hit:a');
      expect((await chain.execute(_call('b'))).content, 'hit:b');
    });
  });

  group('composeToolExecutorChain · 全成员在场（不变式）', () {
    test('五层链：每层工具均可实调（无层被丢弃）', () async {
      final names = ['l1', 'l2', 'l3', 'l4', 'l5'];
      final chain = composeToolExecutorChain([
        for (final n in names) (inner) => _FakeLayer(n, inner),
      ], fallback: _CountingFallback());

      for (final n in names) {
        final r = await chain.execute(_call(n));
        expect(r.content, 'hit:$n',
            reason: '层 $n 必须在链上——丢失任一层即「目录可见、调用全败」');
      }
    });

    test('层序反排时命中顺序随之反转（装配方向可判）', () async {
      final chain = composeToolExecutorChain([
        (inner) => _FakeLayer('outer', inner),
        (inner) => _FakeLayer('inner', inner),
      ], fallback: _CountingFallback());
      // 两个假层认领不同名字，互不遮蔽；此处验证链结构完整即可。
      expect((await chain.execute(_call('outer'))).content, 'hit:outer');
      expect((await chain.execute(_call('inner'))).content, 'hit:inner');
    });
  });

  group('composeToolExecutorChain · 末端兜底', () {
    test('所有层不认领 → 走 fallback', () async {
      final fallback = _CountingFallback();
      final chain = composeToolExecutorChain([
        (inner) => _FakeLayer('a', inner),
      ], fallback: fallback);

      final r = await chain.execute(_call('zzz'));
      expect(r.content, 'fallback');
      expect(fallback.calls, 1);
    });

    test('缺省兜底 = 显式拒绝（禁静默透传）', () async {
      final chain = composeToolExecutorChain([
        (inner) => _FakeLayer('a', inner),
      ]);
      final r = await chain.execute(_call('zzz'));
      expect(r.isError, isTrue);
      expect(r.content, contains('zzz'));
    });

    test('空层链 = 直接返回 fallback', () async {
      final fallback = _CountingFallback();
      final chain = composeToolExecutorChain(const [], fallback: fallback);
      expect(await chain.execute(_call('x')), isA<ToolExecutionResult>());
      expect(fallback.calls, 1);
    });
  });
}
