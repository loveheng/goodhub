/// 端侧对话 prompt 构造（多轮 ChatML 消息序列）。
///
/// **2026-10-31 设计修正（用户裁决：从底层设计找根因）**：复读环（第二轮复述
/// 首轮回答）的根因不在措辞，在**信息架构**——旧「单发压平」把 assistant 的
/// 历史回答塞进 user 轮（外加 `[用户]/[助手]` 人造标注），违背 Qwen 系训练
/// 分布（ChatML 多轮交替），4B 模型对 OOD 输入的行为退化 = 复述上下文。
/// 修正 = 消息结构回归模型原生形态：**多轮消息序列**（JSON 数组跨 AIDL），
/// 角色由 `:engine` 侧 ChatML 模板承载（模板拥有方单一职责归位），文字标注
/// 语法整体退役。
///
/// 保留的两个纯逻辑职责：system 合并（多条 → 一条）、历史字符预算裁剪
/// （从最早一轮起丢——上下文窗口与首 token 延迟约束不变）。
///
/// 纯逻辑件（无平台依赖）：构造规则可单测，见
/// `test/llm/on_device_chat_prompt_test.dart`。
library;

import 'dart:convert';

import 'cloud/cloud_llm.dart';

/// ChatML 控制 token（Qwen 系）。
///
/// 出现在任何正文里都会破坏模板边界：`<|im_end|>` 提前闭合轮次 → 模型直接
/// 收尾 → 零产出（用户粘贴的文本含该串也会中招）。清洗双保险的 Dart 侧；
/// Kotlin 侧（GenieSession）覆盖一切旁路来源。
final RegExp kChatMLControlToken =
    RegExp(r'<\|(?:im_start|im_end|im_sep|endoftext)\|>');

/// 清洗 ChatML 控制 token（模板拥有方的最后一道防线）。
String sanitizeChatMLControlTokens(String text) =>
    text.replaceAll(kChatMLControlToken, '');

/// 历史轮次字符预算（超出从**最早**一轮开始裁剪）。
///
/// 端侧小模型上下文窗口小：长历史既拖慢首 token，又抬升复读概率；且预算
/// 裁剪让「最近轮次」天然优先（保留与当前提问最相关的上下文）。
const int kOnDeviceHistoryCharBudget = 1200;

/// 构造端侧对话消息序列（JSON 数组字符串，跨 AIDL 契约 = promptJson）。
///
/// 规则：
///  1. 全部 SystemMessage 合并为一条 system 消息（`\n\n` 分隔）；
///  2. user / assistant / 工具结果按序保留为独立消息（角色由结构承载，
///     **不再加任何文字标注**）；
///  3. 全部 content 清洗 ChatML 控制 token；
///  4. 历史超预算时从最早一轮起裁剪（system 不占预算）；
///  5. 序列化 = `[{"role":"system"|"user"|"assistant","content":"..."}]`。
///
/// 返回值直接作为 `promptJson` 跨 AIDL 送达 `:engine`，由 ChatMLComposer
/// 构造多轮交替模板。
String buildOnDeviceChatPromptJson(List<CloudChatMessage> messages) {
  final systemParts = <String>[];
  final turns = <(String, String)>[];
  for (final m in messages) {
    switch (m) {
      case SystemMessage(:final content):
        if (content.trim().isNotEmpty) systemParts.add(content);
      case UserMessage(:final content):
        if (content.trim().isNotEmpty) turns.add(('user', content));
      case AssistantMessage(:final content):
        final c = content;
        if (c != null && c.trim().isNotEmpty) turns.add(('assistant', c));
      case ToolResultMessage(:final content):
        if (content.trim().isNotEmpty) turns.add(('user', content));
    }
  }
  final out = <Map<String, String>>[];
  if (systemParts.isNotEmpty) {
    out.add({
      'role': 'system',
      'content': sanitizeChatMLControlTokens(systemParts.join('\n\n')),
    });
  }
  // 历史预算裁剪（从最早一轮起丢；轮次 = 除 system 外全部消息）。
  var start = 0;
  var total = turns.fold<int>(0, (sum, t) => sum + t.$2.length);
  while (start < turns.length - 1 && total > kOnDeviceHistoryCharBudget) {
    total -= turns[start].$2.length;
    start++;
  }
  for (final (role, content) in turns.sublist(start)) {
    out.add({'role': role, 'content': sanitizeChatMLControlTokens(content)});
  }
  return jsonEncode(out);
}
