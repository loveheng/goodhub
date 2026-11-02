import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/llm/on_device_chat_prompt.dart';
import 'package:goodhub/llm/on_device_history_policy.dart';

/// 历史策略族单测（2026-11-02 策略模式落地）。
///
/// 钉住四策略契约：⓪裸prompt（对照钉子）/ ①滑窗（存量行为零变化）/ ②锚点+近窗
/// （末轮必保、锚点配额回退）/ ③摘要（失败降级①、交替性、配额截断）。
void main() {
  OnDeviceHistoryTurn t(String role, String content) => (role, content);

  group('⓪ BarePromptHistoryPolicy', () {
    test('只保留末轮（当前提问），历史全丢', () async {
      final out = await const BarePromptHistoryPolicy().select(
          [t('user', 'Q1'), t('assistant', 'A1'), t('user', 'Q2')], 100);
      expect(out, [t('user', 'Q2')]);
    });

    test('空轮次 → 空', () async {
      expect(await const BarePromptHistoryPolicy().select([], 100), isEmpty);
    });
  });

  group('① DropOldestHistoryPolicy（存量行为钉子）', () {
    test('超预算从最早丢到预算内即停，至少保留末轮', () async {
      final out = await const DropOldestHistoryPolicy()
          .select([t('user', 'x' * 80), t('user', 'y' * 80), t('user', 'Q')],
              100);
      expect(out, [t('user', 'y' * 80), t('user', 'Q')],
          reason: '163 > 100 → 丢最早一轮至 83 ≤ 100 即停（存量语义）');
    });

    test('持续丢至只剩末轮（多轮连超）', () async {
      final out = await const DropOldestHistoryPolicy()
          .select([t('user', 'x' * 80), t('user', 'y' * 80), t('user', 'Q')],
              50);
      expect(out, [t('user', 'Q')]);
    });

    test('预算内原样透传', () async {
      final turns = [t('user', 'Q1'), t('assistant', 'A1')];
      expect(await const DropOldestHistoryPolicy().select(turns, 100), turns);
    });
  });

  group('② AnchorAndRecentHistoryPolicy', () {
    const policy = AnchorAndRecentHistoryPolicy();

    test('预算内原样透传（锚点不额外引入）', () async {
      final turns = [t('user', 'Q1'), t('assistant', 'A1'), t('user', 'Q2')];
      expect(await policy.select(turns, 1000), turns);
    });

    test('超预算：锚点+近窗共存，末轮必保', () async {
      final turns = [
        t('user', '锚' * 10), // 锚点 20 字符 ≤ 30%×120=36
        t('assistant', 'a' * 60), // 近窗预算 120-20=100：a*60 收不进
        t('user', 'b' * 60),
        t('user', 'Q'), // 末轮
      ];
      final out = await policy.select(turns, 120);
      expect(out.first, turns.first, reason: '锚点保留');
      expect(out.last, turns.last, reason: '末轮必保');
      expect(out, contains(turns[2]), reason: '近窗含次新轮');
      expect(out, isNot(contains(turns[1])), reason: '中间旧轮被驱逐');
      expect(out.fold<int>(0, (sum, t) => sum + t.$2.length),
          lessThanOrEqualTo(120), reason: '选取结果不超预算');
    });

    test('锚点超配额 → 回退 ①（丢锚点保近窗）', () async {
      final turns = [
        t('user', 'x' * 100), // > 30%×80=24 → 回退①
        t('user', 'Q'),
      ];
      final out = await policy.select(turns, 80);
      expect(out, [t('user', 'Q')], reason: '回退①后 101 > 80 → 丢至只剩末轮');
    });

    test('末轮收不进近窗 → 回退 ①（至少保末轮语义对齐）', () async {
      final turns = [
        t('user', '锚' * 10),
        t('user', 'x' * 200), // 近窗预算 170 收不进
        t('user', 'Q'),
      ];
      final out = await policy.select(turns, 200);
      expect(out.last, turns.last);
      expect(out.first.$1, 'user');
    });

    test('锚点为 assistant（异常序）→ 回退 ①', () async {
      final turns = [t('assistant', 'A'), t('user', 'x' * 150), t('user', 'Q')];
      final out = await policy.select(turns, 100);
      expect(out, [t('user', 'Q')]);
    });
  });

  group('③ RollingSummaryHistoryPolicy（实验位）', () {
    const summaryText = '早前讨论了 A 与 B';
    Future<String> ok(List<OnDeviceHistoryTurn> _) async => summaryText;
    Future<String> fail(List<OnDeviceHistoryTurn> _) async => throw StateError('boom');
    Future<String> blank(List<OnDeviceHistoryTurn> _) async => '  ';
    final policy = RollingSummaryHistoryPolicy(summarize: ok);

    test('预算内原样透传（不触发摘要推理）', () async {
      var called = false;
      final p = RollingSummaryHistoryPolicy(
          summarize: (_) async {
            called = true;
            return 'S';
          });
      final turns = [t('user', 'Q1'), t('assistant', 'A1')];
      expect(await p.select(turns, 1000), turns);
      expect(called, isFalse, reason: '未超预算零成本');
    });

    test('超预算：摘要轮(user) + assistant 开头近窗，模板交替成立', () async {
      final turns = [
        t('user', 'q' * 30), // 被驱逐
        t('assistant', 'a' * 20), // 近窗收不进
        t('user', 'u' * 10), // 引导 user 被丢（交替性）
        t('assistant', 'a' * 10), // 近窗首条 = assistant
        t('user', 'q' * 5), // 末轮
      ];
      final out = await policy.select(turns, 50); // 总 75 > 50
      expect(out.first, ('user', '【历史摘要】$summaryText'));
      expect(out[1].$1, 'assistant', reason: '摘要后须 assistant 开头（模板交替）');
      expect(out.last, turns.last, reason: '末轮必保');
    });

    test('摘要抛异常 → 回退 ①', () async {
      final p = RollingSummaryHistoryPolicy(summarize: fail);
      final turns = [t('user', 'x' * 50), t('assistant', 'a' * 50), t('user', 'Q')];
      final out = await p.select(turns, 60);
      expect(out, await const DropOldestHistoryPolicy().select(turns, 60));
      expect(out.any((t) => t.$2.contains('【历史摘要】')), isFalse);
    });

    test('摘要空白 → 回退 ①', () async {
      final p = RollingSummaryHistoryPolicy(summarize: blank);
      final turns = [t('user', 'x' * 50), t('assistant', 'a' * 50), t('user', 'Q')];
      final out = await p.select(turns, 60);
      expect(out.any((t) => t.$2.contains('【历史摘要】')), isFalse);
    });

    test('摘要超配额 → 截断（非回退）', () async {
      final p = RollingSummaryHistoryPolicy(
          summarize: (_) async => 's' * 1000);
      final turns = [
        t('user', 'x' * 50),
        t('assistant', 'a' * 30),
        t('user', 'Q'),
      ];
      final out = await p.select(turns, 80);
      final summaryTurn = out.first;
      expect(summaryTurn.$1, 'user');
      // 配额 = 0.25×80=20 字符 + 1 省略号；标记 6 字符
      expect((summaryTurn.$2.length) - '【历史摘要】'.length, 21);
    });
  });

  group('buildOnDeviceChatPromptJsonAsync（策略接线面）', () {
    test('默认策略 = ① 滑窗：与同步入口输出逐字节一致（行为零变化钉子）', () async {
      final messages = [
        SystemMessage('S1'),
        SystemMessage('S2'),
        UserMessage('你好'),
        AssistantMessage(content: '我是助手'),
        UserMessage('再问一句'),
      ];
      expect(
        await buildOnDeviceChatPromptJsonAsync(messages, contextTokens: 1280),
        buildOnDeviceChatPromptJson(messages, contextTokens: 1280),
      );
    });

    test('⓪ 真裸：只输出当前轮（system 一并丢弃，与 Gallery 裸问题同形）', () async {
      final j = (await buildOnDeviceChatPromptJsonAsync([
        SystemMessage('S'),
        UserMessage('Q1'),
        AssistantMessage(content: 'A1'),
        UserMessage('Q2'),
      ], historyPolicy: const BarePromptHistoryPolicy()));
      // 解 JSON 断言
      final list = (j.startsWith('[') ? j : '[]');
      expect(list, isNot(contains('"role":"system"')),
          reason: 'dropsSystem：system 一并丢（2026-11-03 用户拍板真裸语义）');
      expect(list, contains('Q2'));
      expect(list, isNot(contains('A1')), reason: '历史全丢');
      expect(list, isNot(contains('Q1')), reason: '历史全丢');
    });
  });
}
