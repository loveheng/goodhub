/// 历史策略选择持久化 + 解析器（2026-11-02 策略模式设置面接线）。
///
/// **策略挂模型本身（用户拍板 2026-11-02）**：每个模型独立持有一档历史策略
/// （键 = 模型身份锚点，shared_preferences 单键一模型，范式同
/// `OnDeviceModelSelection`）。默认均为 ① 滑窗——未设置过的模型行为与存量
/// 完全一致（云端/混合装配零变化）。
///
/// 锚点口径：
/// - 端侧 = `InstalledModel.dirName`（`models/` 落盘目录名，身份 SSOT）；
/// - 云端 = `ByokProfile.id`（BYOK 配置档案 id，生效面 =
///   `ByokStore.preferredProfileId`）。
///
/// 解析职责：偏好 id → 策略实例。③ 摘要实验位需要摘要器注入——当前消费方
/// 未接 `on_device_capability` 原语前，选 ③ 一律回落 ①（显式降级非静默：
/// UI 描述位已标注「实验位」）。
library;

import 'package:shared_preferences/shared_preferences.dart';

import 'cloud/cloud_llm.dart';
import 'on_device_chat_prompt.dart' show splitChatPromptTurns;
import 'on_device_history_policy.dart';

/// 策略偏好 id（持久化口径，UI 与解析共用）。
abstract final class HistoryPolicyIds {
  /// ⓪ 裸 prompt（对照实验 / 无状态单发）。
  static const String bare = 'bare';

  /// ① 滑窗丢最老（存量默认）。
  static const String dropOldest = 'drop_oldest';

  /// ② 锚点+近窗（≥2k 窗口推荐）。
  static const String anchorRecent = 'anchor_recent';

  /// ③ 滚动摘要（实验位，≥4k 窗口）。
  static const String rollingSummary = 'rolling_summary';

  /// 全部合法 id（存储校验白名单）。
  static const Set<String> all = {
    bare,
    dropOldest,
    anchorRecent,
    rollingSummary,
  };
}

/// 偏好存储 + 解析器（static 门面，无状态；键按模型 id）。
abstract final class HistoryPolicySelection {
  static const String _keyPrefix = 'llm.history_policy.model.';

  /// 云端路径历史预算（字符口径；云端窗口远大于端侧，预算只对 ②③ 的近窗
  /// 收收敛起作用，⓪ 不受预算影响）。24000 字符 ≈ 6k token 中位。
  static const int kCloudHistoryCharBudget = 24000;

  /// 端侧默认策略 = ⓪ 真裸（用户拍板 2026-11-03）：复读触发器（system 中文
  /// 长指令 + 历史注入）整根拔除，adb 自动化实测同问输出与 Gallery 一致；
  /// 代价 = 多轮上下文全丢（1B+1280 窗口下历史价值本就有限），用户可按模型
  /// 手动切回 ①②③。
  static const String kDeviceDefaultPolicyId = HistoryPolicyIds.bare;

  /// 云端默认策略 = ① 滑窗（存量零变化：云端大窗口无复读诱因，整体跳过裁剪）。
  static const String kCloudDefaultPolicyId = HistoryPolicyIds.dropOldest;

  /// 模型偏好键（锚点拼装单源：端侧 dirName / 云端 profile id 均直接作键，
  /// 两侧共用一个命名空间——两类 id 无碰撞面）。
  static String keyFor(String modelKey) => '$_keyPrefix$modelKey';

  /// 读某模型的历史策略偏好：prefs > 侧别默认（端侧 ⓪ / 云端 ①）。
  /// 非法 id / prefs 不可达 → 侧别默认。
  static Future<String> readForModel(String modelKey, {bool device = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final id = prefs.getString(keyFor(modelKey));
      if (id != null && HistoryPolicyIds.all.contains(id)) return id;
    } catch (_) {
      // prefs 不可达（测试环境）→ 默认。
    }
    return device ? kDeviceDefaultPolicyId : kCloudDefaultPolicyId;
  }

  /// 写某模型的历史策略偏好（id 须经 [HistoryPolicyIds.all] 白名单，
  /// 非法抛 ArgumentError）。
  static Future<void> writeForModel(String modelKey, String id) async {
    if (!HistoryPolicyIds.all.contains(id)) {
      throw ArgumentError.value(id, 'id', '未知历史策略 id');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(keyFor(modelKey), id);
  }

  /// 解析偏好 id → 策略实例。
  ///
  /// [summarizer]：③ 的摘要器注入位；缺省（消费方未接原语）时选 ③ 显式
  /// 回落 ①——实验位未通电不假装可用。
  static OnDeviceHistoryPolicy resolve(
    String id, {
    OnDeviceSummarizer? summarizer,
  }) {
    switch (id) {
      case HistoryPolicyIds.bare:
        return const BarePromptHistoryPolicy();
      case HistoryPolicyIds.anchorRecent:
        return const AnchorAndRecentHistoryPolicy();
      case HistoryPolicyIds.rollingSummary:
        final s = summarizer;
        if (s == null) return const DropOldestHistoryPolicy();
        return RollingSummaryHistoryPolicy(summarize: s);
      case HistoryPolicyIds.dropOldest:
      default:
        return const DropOldestHistoryPolicy();
    }
  }

  /// 偏好 id → UI 显示名（设置页选项；与 id 一一对应）。
  static String label(String id) {
    switch (id) {
      case HistoryPolicyIds.bare:
        return '裸 Prompt（无历史）';
      case HistoryPolicyIds.anchorRecent:
        return '锚点 + 近窗';
      case HistoryPolicyIds.rollingSummary:
        return '滚动摘要（实验）';
      case HistoryPolicyIds.dropOldest:
      default:
        return '滑动窗口（默认）';
    }
  }

  /// 偏好 id → 一行说明（设置页副文案）。
  static String description(String id) {
    switch (id) {
      case HistoryPolicyIds.bare:
        return '只保留当前提问，历史全丢——输出异常时的对照归因档';
      case HistoryPolicyIds.anchorRecent:
        return '保留首轮任务锚点 + 最近若干轮（≥2k 窗口推荐）';
      case HistoryPolicyIds.rollingSummary:
        return '被裁剪历史压成摘要回注（≥4k 窗口；摘要器未接时回落滑窗）';
      case HistoryPolicyIds.dropOldest:
      default:
        return '超预算从最早一轮起丢弃（存量默认，行为最稳）';
    }
  }
}

/// 云端路径按策略裁剪消息列表（云端口径，2026-11-02 接线）。
///
/// 规则：
/// - **默认 ①（dropOldest）不适用**——云端大窗口本就无需裁剪，调用方对
///   默认档应整体跳过本函数（存量零变化约束）；
/// - 工具链路（消息含 ToolResultMessage）不裁剪：轮次化会把工具结果展平成
///   user 轮，破坏协议语义（tool 消息回放失配）——返回原列表；
/// - system 多条合并为一条（与端侧口径一致）；
/// - user/assistant 轮交 [policy] 选取后重建（保序）。
Future<List<CloudChatMessage>> applyHistoryPolicyToCloudMessages(
  List<CloudChatMessage> messages,
  OnDeviceHistoryPolicy policy,
  int budget,
) async {
  if (messages.any((m) => m is ToolResultMessage)) return messages;
  final (systemParts, turns) = splitChatPromptTurns(messages);
  final selected = await policy.select(turns, budget);
  final out = <CloudChatMessage>[
    // dropsSystem（2026-11-03 ⓪ 真裸语义）：与端侧同口径，连 system 一起丢。
    if (systemParts.isNotEmpty && !policy.dropsSystem)
      SystemMessage(systemParts.join('\n\n')),
  ];
  for (final (role, content) in selected) {
    out.add(role == 'assistant'
        ? AssistantMessage(content: content)
        : UserMessage(content));
  }
  return out;
}
