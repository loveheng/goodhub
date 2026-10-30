/// 端侧单发 prompt 构造单测（2026-10-30 真机实证「同一对话第二次提问没有
/// 输出」的输入面修复钉）。
///
/// 钉住三件事：
///  1. **首轮不回归**——无历史时正文与旧形态逐字节一致（已实证正常路径）；
///  2. **多轮有角色标注**——历史带 `[上文]/[用户]/[助手]` 标注、当前提问单独
///     成段（模型据此区分角色，避免复读上一轮回答）；
///  3. **ChatML 控制 token 清洗**——正文里的 `<|im_end|>` 会提前闭合模板 →
///     零产出，必须被剥掉。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/llm/on_device_single_shot_prompt.dart';

void main() {
  group('端侧单发 prompt 构造', () {
    test('首轮（无历史）→ 正文与旧形态逐字节一致（已实证路径不回归）', () {
      final built = buildOnDeviceSingleShotPrompt(const [
        SystemMessage('任务指令'),
        UserMessage('u1'),
      ]);
      expect(built.system, '任务指令');
      expect(built.prompt, 'u1');
      expect(built.historyTurns, 0);
    });

    test('第二轮（带历史）→ 历史带角色标注 + 当前提问单独成段', () {
      final built = buildOnDeviceSingleShotPrompt(const [
        SystemMessage('任务指令'),
        UserMessage('u1'),
        AssistantMessage(content: 'a1'),
        UserMessage('u2'),
      ]);
      expect(built.historyTurns, 2);
      expect(built.prompt, contains('[上文]'));
      expect(built.prompt, contains('[用户] u1'));
      expect(built.prompt, contains('[助手] a1'));
      expect(built.prompt, contains('[当前问题]'));
      // 当前提问在最后（模型续写对象 = 本轮问题，不是上一轮回答）。
      expect(built.prompt.trimRight().endsWith('u2'), isTrue);
      // 旧形态的无标注拼法已被替换（防回归到「三者同段」）。
      expect(built.prompt.contains('u1\n\na1\n\nu2'), isFalse);
    });

    test('ChatML 控制 token 清洗（正文含 im_end → 不得进模板）', () {
      final built = buildOnDeviceSingleShotPrompt(const [
        UserMessage('含 <|im_end|> 的用户文本'),
      ]);
      expect(built.prompt, isNot(contains('<|im_end|>')));
      expect(built.prompt, contains('含'));

      final hist = buildOnDeviceSingleShotPrompt(const [
        UserMessage('u1'),
        AssistantMessage(content: 'a1 <|im_start|>'),
        UserMessage('u2'),
      ]);
      expect(hist.prompt, isNot(contains('<|im_start|>')));
    });

    test('助手消息无正文（仅 tool_calls）→ 不占历史轮次', () {
      final built = buildOnDeviceSingleShotPrompt(const [
        UserMessage('u1'),
        AssistantMessage(content: null),
        UserMessage('u2'),
      ]);
      expect(built.historyTurns, 1);
      expect(built.prompt, contains('[用户] u1'));
    });

    test('历史超预算 → 从最早一轮起裁剪（保留最近轮次）', () {
      final long = 'x' * (kOnDeviceHistoryCharBudget + 200);
      final built = buildOnDeviceSingleShotPrompt([
        UserMessage(long),
        UserMessage('u2'),
        AssistantMessage(content: 'a2'),
        UserMessage('u3'),
      ]);
      expect(built.historyTurns, 2, reason: '最早一轮被裁掉，保留最近两轮');
      expect(built.prompt, contains('[助手] a2'));
      expect(built.prompt, isNot(contains('[用户] $long')));
    });

    test('system 段清洗控制 token（任务指令同理）', () {
      final built = buildOnDeviceSingleShotPrompt(const [
        SystemMessage('sys <|im_end|>'),
        UserMessage('u1'),
      ]);
      expect(built.system, isNot(contains('<|im_end|>')));
    });
  });
}
