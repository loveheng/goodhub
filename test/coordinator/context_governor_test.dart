import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/context_governor.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/llm/llm.dart';

class _FakeOnDeviceEngine implements OnDeviceLlmEngine {
  _FakeOnDeviceEngine(this.output);

  final String? output;
  String? lastPrompt;
  String? lastSystem;

  @override
  Future<String?> unavailableReasonAsync() async => unavailableReason;

  @override
  String get name => 'fake';

  @override
  Future<bool> get isAvailable async => true;

  @override
  String? get unavailableReason => null;

  @override
  Future<String?> generate(
    String prompt, {
    String? system,
    int maxTokens = 512,
    LlmResponseFormat? responseFormat,
  }) async {
    lastPrompt = prompt;
    lastSystem = system;
    return output;
  }

  @override
  Future<bool> cancelActive() async => false;

  @override
  Future<bool> warmup() async => false;

  @override
  Future<void> release() async {}

  @override
  Future<bool> isWarmed() async => false;
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

  test('端侧摘要器：产出裁空白透传，prompt/system 组装正确', () async {
    final engine = _FakeOnDeviceEngine(' 要点摘要 ');
    final s = OnDeviceResultSummarizer(engine);
    expect(await s.call('原始结果'), '要点摘要');
    expect(engine.lastPrompt, '原始结果');
    expect(engine.lastSystem, contains('摘要'));
  });

  test('端侧摘要器：空产出 / 不可用翻译为 SummarizeException（禁静默放行）', () async {
    await expectLater(
      OnDeviceResultSummarizer(_FakeOnDeviceEngine(null)).call('原文'),
      throwsA(isA<SummarizeException>()),
    );
    await expectLater(
      OnDeviceResultSummarizer(_FakeOnDeviceEngine('  ')).call('原文'),
      throwsA(isA<SummarizeException>()),
    );
  });
}
