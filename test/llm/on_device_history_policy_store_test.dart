import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/llm/on_device_history_policy.dart';
import 'package:goodhub/llm/on_device_history_policy_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 历史策略设置面单测（2026-11-02 接线）：id 白名单/解析/云端裁剪。
///
/// 存取往返依赖 shared_preferences（测试环境 SharedPreferences.setMock-
/// InitialValues 可用），这里用 mock 值走真实读写路径。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('HistoryPolicySelection 偏好存取（模型键控）', () {
    test('侧别默认分化：云端未设置 = ① 滑窗（存量零变化钉子），端侧未设置 = ⓪ 真裸', () async {
      expect(
          await HistoryPolicySelection.readForModel('byok-profile-x'),
          HistoryPolicyIds.dropOldest,
          reason: '云端默认 ①（存量零变化）');
      expect(
          await HistoryPolicySelection.readForModel('model-a', device: true),
          HistoryPolicyIds.bare,
          reason: '端侧默认 ⓪（2026-11-03 用户拍板：复读触发器整根拔除）');
    });

    test('写入后读回一致（每模型独立一档，互不串键）', () async {
      await HistoryPolicySelection.writeForModel(
          'gemma3-1b', HistoryPolicyIds.anchorRecent);
      await HistoryPolicySelection.writeForModel(
          'byok-profile-1', HistoryPolicyIds.bare);
      expect(
          await HistoryPolicySelection.readForModel('gemma3-1b'),
          HistoryPolicyIds.anchorRecent);
      expect(
          await HistoryPolicySelection.readForModel('byok-profile-1'),
          HistoryPolicyIds.bare);
      expect(
          await HistoryPolicySelection.readForModel('other-model'),
          HistoryPolicyIds.dropOldest,
          reason: '未设置的模型落默认');
    });

    test('非法 id 写入抛 ArgumentError；读取侧非法 id 落默认', () async {
      expect(
          () => HistoryPolicySelection.writeForModel('m', 'x'),
          throwsArgumentError);
      // 直写非法值 → 读回落默认（白名单校验）。
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('llm.history_policy.model.m', 'bogus');
      expect(
          await HistoryPolicySelection.readForModel('m'),
          HistoryPolicyIds.dropOldest);
    });
  });

  group('HistoryPolicySelection.resolve', () {
    test('四 id 解析到对应策略类型', () {
      expect(HistoryPolicySelection.resolve(HistoryPolicyIds.bare),
          isA<BarePromptHistoryPolicy>());
      expect(HistoryPolicySelection.resolve(HistoryPolicyIds.dropOldest),
          isA<DropOldestHistoryPolicy>());
      expect(HistoryPolicySelection.resolve(HistoryPolicyIds.anchorRecent),
          isA<AnchorAndRecentHistoryPolicy>());
      expect(
          HistoryPolicySelection.resolve(HistoryPolicyIds.rollingSummary,
              summarizer: (_) async => 'S'),
          isA<RollingSummaryHistoryPolicy>());
    });

    test('③ 无摘要器注入 → 显式回落 ①（实验位未通电不假装可用）', () {
      expect(HistoryPolicySelection.resolve(HistoryPolicyIds.rollingSummary),
          isA<DropOldestHistoryPolicy>());
    });

    test('未知 id → 默认 ①', () {
      expect(HistoryPolicySelection.resolve('bogus'),
          isA<DropOldestHistoryPolicy>());
    });
  });

  group('applyHistoryPolicyToCloudMessages（云端裁剪）', () {
    test('⓪ 裸prompt：真裸（system 一并丢）仅保末轮', () async {
      final out = await applyHistoryPolicyToCloudMessages(
        [
          SystemMessage('S1'),
          SystemMessage('S2'),
          UserMessage('Q1'),
          AssistantMessage(content: 'A1'),
          UserMessage('Q2'),
        ],
        const BarePromptHistoryPolicy(),
        24000,
      );
      expect(out, hasLength(1));
      expect(out.single, isA<UserMessage>());
      expect((out.single as UserMessage).content, 'Q2');
    });

    test('① 滑窗（云端口径大预算）：预算内原样透传', () async {
      final messages = [
        SystemMessage('S'),
        UserMessage('Q1'),
        AssistantMessage(content: 'A1'),
        UserMessage('Q2'),
      ];
      final out = await applyHistoryPolicyToCloudMessages(
          messages, const DropOldestHistoryPolicy(), 24000);
      expect(out, hasLength(4));
      expect(out[1], isA<UserMessage>());
      expect(out[3], isA<UserMessage>());
    });

    test('含工具结果消息 → 整体豁免不裁剪（tool 协议回放保护）', () async {
      final messages = [
        SystemMessage('S'),
        UserMessage('Q1'),
        ToolResultMessage(toolCallId: 't1', content: 'tool-result'),
        UserMessage('Q2'),
      ];
      final out = await applyHistoryPolicyToCloudMessages(
          messages, const BarePromptHistoryPolicy(), 10);
      expect(identical(out, messages), isTrue, reason: '豁免 = 原列表透传');
    });
  });
}
