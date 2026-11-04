import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/context_governor.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/llm/on_device_capability.dart';
import 'package:goodhub/llm/on_device_engine.dart';

class _FakeCapability implements OnDeviceCapabilityService {
  _FakeCapability(this.output);

  final String? output;
  String? lastInstruction;
  String? lastInput;

  @override
  Future<OnDeviceCapabilityAvailability> availability() async =>
      OnDeviceCapabilityAvailability.ready;

  @override
  Future<void> loadExplicit() async {}

  @override
  Stream<EngineChunk> completeStream({
    required String instruction,
    required String input,
    OnDevicePrimitiveConfig config = const OnDevicePrimitiveConfig(),
    String? traceId,
  }) {
    final out = output;
    return Stream.value(EngineChunk(deltaText: out ?? ''));
  }

  @override
  Future<String> complete({
    required String instruction,
    required String input,
    OnDevicePrimitiveConfig config = const OnDevicePrimitiveConfig(),
    PrimitiveFallbackPolicy fallback = PrimitiveFallbackPolicy.failFast,
    String? traceId,
  }) async {
    lastInstruction = instruction;
    lastInput = input;
    final out = output;
    if (out == null) throw const OnDevicePrimitiveException('fake unavailable');
    return out;
  }
}

AssistantMessage _assistantOf(String id) => AssistantMessage(
      toolCalls: [AssembledToolCall(id: id, name: 'f', argumentsJson: '{}')],
    );

/// System + User + n 轮「Assistant → ToolResult」完整对。
List<CloudChatMessage> _buildRounds(int n) => [
      const SystemMessage('s'),
      const UserMessage('u'),
      for (var i = 1; i <= n; i++) ...[
        _assistantOf('c$i'),
        ToolResultMessage(toolCallId: 'c$i', content: 'r$i'),
      ],
    ];

void main() {
  test('estimateTokens：字符级粗估口径', () {
    expect(estimateTokens('abc中文'), 5);
    expect(estimateTokens(''), 0);
  });

  test('summarizedContent：摘要正文 + 宿主注引用标记（原文体量留审计）', () {
    final out = summarizedContent('要点', 'x' * 1200);
    expect(out.startsWith('要点'), isTrue);
    expect(out, contains('[宿主注：原工具结果约 1200 tokens'));
    expect(out, contains('原文未入上下文'));
  });

  test('窗口：轮数未超 → 原样副本返回，入参不被裁', () {
    final msgs = _buildRounds(3);
    final out = trimMessagesToWindow(msgs, 6);
    expect(out.length, msgs.length);
    expect(identical(out, msgs), isFalse);
    expect(msgs.length, 2 + 3 * 2); // 本地历史不裁
  });

  test('窗口：超窗 → System/User + 最近 N 轮完整对，裁剪点落在 Assistant 边界', () {
    final msgs = _buildRounds(4);
    final out = trimMessagesToWindow(msgs, 2);
    expect(out.first, isA<SystemMessage>());
    expect(out[1], isA<UserMessage>());
    expect(out[2], isA<AssistantMessage>()); // 配对语义：不得以孤立 ToolResult 开头
    expect(
      out.whereType<AssistantMessage>().map((m) => m.toolCalls.single.id),
      ['c3', 'c4'],
    );
    expect(
      out.whereType<ToolResultMessage>().map((m) => m.toolCallId),
      ['c3', 'c4'],
    );
    // 每条 ToolResult 前一条必是其 Assistant（拆对即协议 400）
    for (var i = 1; i < out.length; i++) {
      if (out[i] is ToolResultMessage) {
        expect(out[i - 1], isA<AssistantMessage>());
      }
    }
  });

  test('窗口：windowRounds<=0 视为不设窗', () {
    final msgs = _buildRounds(3);
    expect(trimMessagesToWindow(msgs, 0).length, msgs.length);
    expect(trimMessagesToWindow(msgs, -1).length, msgs.length);
  });

  test('端侧摘要器：产出裁空白透传，instruction/input 组装正确', () async {
    final cap = _FakeCapability(' 要点摘要 ');
    // S17c 语义外注：instruction 由装配方解析传入（测试用同源文本模拟
    // resolveSupplyInstruction 的产物），断言其原样透传至原语。
    const injected = '你是工具结果摘要器。把给定工具结果压缩为要点，'
        '保留关键数值、状态、结论与错误信息，不添加解释、前言或代码块包裹。';
    final s = OnDeviceResultSummarizer(cap, instruction: injected);
    expect(await s.call('原始结果'), '要点摘要');
    expect(cap.lastInput, '原始结果');
    expect(cap.lastInstruction, injected,
        reason: '外注语义原样透传（不再有内置 _system 双源）');
  });

  test('端侧摘要器：原语失败 / 空产出翻译为 SummarizeException（禁静默放行）', () async {
    await expectLater(
      OnDeviceResultSummarizer(_FakeCapability(null), instruction: 'i')
          .call('原文'),
      throwsA(isA<SummarizeException>()),
    );
    await expectLater(
      OnDeviceResultSummarizer(_FakeCapability('  '), instruction: 'i')
          .call('原文'),
      throwsA(isA<SummarizeException>()),
    );
  });

  group('阶梯截断 steppedWindow（context-stepped-pruning §2.1）', () {
    test('轮数 ≤ 高水位（low+step）：纯追加原样放行，不产生归档', () {
      final msgs = _buildRounds(12); // 恰在高水位（6+6）
      final r = steppedWindow(msgs, low: 6, step: 6);
      expect(r.kept.length, msgs.length);
      expect(identical(r.kept, msgs), isFalse, reason: '纯函数不改入参');
      expect(r.pruned, isEmpty, reason: '未触线不归档');
    });

    test('触线（13 轮）：剪出最早 6 轮，保留区回到低水位且配对完整', () {
      final msgs = _buildRounds(13);
      final r = steppedWindow(msgs, low: 6, step: 6);
      // 保留区：前导 2 条（System+U1）+ 7 轮完整对（R7~R13）
      expect(r.kept.length, 2 + 7 * 2);
      expect(r.kept.first, isA<SystemMessage>());
      expect(
        r.kept.whereType<AssistantMessage>().map((m) => m.toolCalls.single.id),
        ['c7', 'c8', 'c9', 'c10', 'c11', 'c12', 'c13'],
      );
      // 被裁区：R1~R6 完整对（含各自 ToolResult，禁拆对）
      expect(r.pruned.length, 6 * 2);
      expect(
        r.pruned.whereType<AssistantMessage>().map((m) => m.toolCalls.single.id),
        ['c1', 'c2', 'c3', 'c4', 'c5', 'c6'],
      );
      for (var i = 1; i < r.pruned.length; i++) {
        if (r.pruned[i] is ToolResultMessage) {
          expect(r.pruned[i - 1], isA<AssistantMessage>());
        }
      }
    });

    test('阶梯波动：触线归档后回到 6 轮，再追加至 12 轮前不再触发', () {
      final msgs13 = _buildRounds(13);
      final first = steppedWindow(msgs13, low: 6, step: 6);
      expect(first.pruned, isNotEmpty);
      // 截断后（等效 6 轮 + 新一轮 = 7 轮）：不触发。
      final msgs7 = _buildRounds(7);
      expect(steppedWindow(msgs7, low: 6, step: 6).pruned, isEmpty);
    });

    test('step<=0 视为关闭阶梯：原样放行', () {
      final msgs = _buildRounds(20);
      expect(steppedWindow(msgs, low: 6, step: 0).pruned, isEmpty);
      expect(steppedWindow(msgs, low: 6, step: 0).kept.length, msgs.length);
    });

    test('low<=0 防御：原样放行（不产生空窗）', () {
      final msgs = _buildRounds(5);
      final r = steppedWindow(msgs, low: 0, step: 6);
      expect(r.pruned, isEmpty);
      expect(r.kept.length, msgs.length);
    });
  });
}
