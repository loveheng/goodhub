/// 端侧单发（single-shot）prompt 构造（端侧职责内的「一轮提取」语义）。
///
/// 端侧路径只做**单发提取**：把一次请求的多轮会话历史压平成**一个 user 轮**
/// 投给端侧模型（§2 端侧不承担通用调度）。压平形态直接决定端侧小模型的
/// 输入质量——真机实证（2026-10-30「同一对话第二次提问没有输出」）：
///
/// - 旧形态：各角色内容**无标注**直接 `join('\n\n')` → 模型在同一段里看到
///   「用户问题 + 上一轮 AI 回答 + 新问题」三者，无法区分角色 → 复读上一轮
///   回答，或在正文里的 `<|im_end|>` 处提前闭合模板 → **零产出**。
/// - 新形态：**历史带角色标注**（`[上文]` / `[用户]` / `[助手]` / `[工具结果]`）
///   + **当前提问单独标注**（`[当前问题]`）+ 正文清洗 ChatML 控制 token。
///
/// **首轮（无历史）逐字节保持旧形态**（不加任何标注）——首轮是已实证正常的
/// 路径，不得回归；只有「带历史」的多轮场景才启用标注形态。
///
/// 纯逻辑件（无平台依赖）：构造规则可单测，见
/// `test/llm/on_device_single_shot_prompt_test.dart`。
library;

import 'cloud/cloud_llm.dart';

/// ChatML 控制 token（Qwen 系）。
///
/// 出现在任何正文里都会破坏模板边界：`<|im_end|>` 提前闭合 user 轮 → 模型
/// 直接收尾 → **零产出**（首轮也可能中招：用户粘贴的文本含该串）。
final RegExp kChatMLControlToken =
    RegExp(r'<\|(?:im_start|im_end|im_sep|endoftext)\|>');

/// 清洗 ChatML 控制 token（模板拥有方的最后一道防线）。
///
/// 与 `:engine` 侧（`GenieSession`）的模板级清洗互为双保险：Dart 侧清洗覆盖
/// 宿主构造的正文，Kotlin 侧覆盖一切旁路来源。
String sanitizeChatMLControlTokens(String text) =>
    text.replaceAll(kChatMLControlToken, '');

/// 历史轮次字符预算（超出从**最早**一轮开始裁剪）。
///
/// 端侧小模型上下文窗口小：长历史既拖慢首 token，又抬升复读概率；且预算
/// 裁剪让「最近轮次」天然优先（保留与当前提问最相关的上下文）。
const int kOnDeviceHistoryCharBudget = 1200;

/// 单发 prompt 构造结果。
class OnDeviceSingleShotPrompt {
  const OnDeviceSingleShotPrompt({
    required this.system,
    required this.prompt,
    required this.historyTurns,
  });

  /// 任务指令（system 段）；无 system 时为 null。
  final String? system;

  /// 投给端侧模型的正文（= 一个 user 轮的内容）。
  final String prompt;

  /// 参与压平的历史轮次数（0 = 首轮，无历史 → 正文与旧形态逐字节一致）。
  final int historyTurns;
}

/// 构造端侧单发 prompt（system 段 + 单发正文）。
///
/// 规则：
///  1. system 段 = 全部 SystemMessage 合并（`\n\n` 分隔）；
///  2. **当前提问** = 最后一条 UserMessage 轮及其之后的轮次；
///  3. **历史** = 当前提问之前的全部轮次（用户/助手/工具结果）；
///  4. 无历史 → 正文 = 当前提问原文（**不加标注**，与旧形态逐字节一致）；
///  5. 有历史 → 正文 = `[上文]` 分段（每轮带角色标注）+ `[当前问题]` 段；
///  6. 全部正文清洗 ChatML 控制 token；历史超预算时从最早一轮起裁剪。
OnDeviceSingleShotPrompt buildOnDeviceSingleShotPrompt(
  List<CloudChatMessage> messages,
) {
  final systemParts = <String>[];
  final turns = <_Turn>[];
  for (final m in messages) {
    switch (m) {
      case SystemMessage(:final content):
        if (content.trim().isNotEmpty) systemParts.add(content);
      case UserMessage(:final content):
        if (content.trim().isNotEmpty) turns.add(_Turn('用户', content));
      case AssistantMessage(:final content):
        final c = content;
        if (c != null && c.trim().isNotEmpty) turns.add(_Turn('助手', c));
      case ToolResultMessage(:final content):
        if (content.trim().isNotEmpty) turns.add(_Turn('工具结果', content));
    }
  }
  final system = systemParts.isEmpty
      ? null
      : sanitizeChatMLControlTokens(systemParts.join('\n\n'));

  // 当前提问 = 最后一条用户轮；其后轮次（工具结果等）并入当前提问段。
  var lastUser = -1;
  for (var i = turns.length - 1; i >= 0; i--) {
    if (turns[i].role == '用户') {
      lastUser = i;
      break;
    }
  }
  if (lastUser < 0) {
    // 无用户轮（异常形态，如仅助手历史）：全文按历史处理，当前提问为空。
    final hist = _renderHistory(_fitToBudget(turns));
    return OnDeviceSingleShotPrompt(
      system: system,
      prompt: hist,
      historyTurns: turns.length,
    );
  }

  final current = turns.sublist(lastUser);
  final currentText = current
      .map((t) => t.role == '用户' ? t.text : '[${t.role}] ${t.text}')
      .join('\n\n');
  final history = turns.sublist(0, lastUser);
  if (history.isEmpty) {
    // 首轮：旧形态（不加标注）——已实证正常路径不回归。
    return OnDeviceSingleShotPrompt(
      system: system,
      prompt: sanitizeChatMLControlTokens(currentText),
      historyTurns: 0,
    );
  }
  final fitted = _fitToBudget(history);
  final histText = _renderHistory(fitted);
  final prompt = sanitizeChatMLControlTokens(
    '$histText\n\n[当前问题]\n$currentText',
  );
  return OnDeviceSingleShotPrompt(
    system: system,
    prompt: prompt,
    historyTurns: fitted.length,
  );
}

/// 历史渲染：每轮带角色标注，轮间空行分隔。
String _renderHistory(List<_Turn> history) {
  if (history.isEmpty) return '';
  final buf = StringBuffer('[上文]\n');
  for (final t in history) {
    buf.write('[${t.role}] ${t.text}\n\n');
  }
  return buf.toString().trimRight();
}

/// 历史字符预算裁剪：从最早一轮起丢（保留最近轮次 = 与当前提问最相关）。
List<_Turn> _fitToBudget(List<_Turn> history) {
  if (history.isEmpty) return history;
  var total = history.fold<int>(0, (a, t) => a + t.text.length);
  var start = 0;
  while (start < history.length - 1 &&
      total > kOnDeviceHistoryCharBudget) {
    total -= history[start].text.length;
    start++;
  }
  return start == 0 ? history : history.sublist(start);
}

/// 单条对话轮（角色标签 + 正文）。
class _Turn {
  const _Turn(this.role, this.text);

  final String role;
  final String text;
}
