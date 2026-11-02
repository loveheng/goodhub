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

import 'dart:async';

import 'dart:convert';

import 'cloud/cloud_llm.dart';
import 'on_device_history_policy.dart';

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
///
/// **F3 解耦立法（2026-10-31 ADR）**：本预算是 **2B 模型 KV-Cache 推理窗口
/// 约束**，不是 Binder 迁就——通道升级（大载荷临时文件通道见
/// [kPromptInlineBinderLimitChars]）不解锁模型窗口，阶梯截断照常生效。
const int kOnDeviceHistoryCharBudget = 1200;

/// 历史预算动态推导的 token 预留（[buildOnDeviceChatPromptJson] 传入
/// `contextTokens` 时启用）：
/// - 输出预留 512：与 [GenerationConfig.maxTokens] 默认值对齐——上下文窗口
///   必须同时容纳输入与最大输出；
/// - 系统+用户预留 256：system 指令 ~64 + 当前 user 轮弹性（ASCII 最坏
///   1 字符 = 1 token；user 轮不可裁剪，超预留 = SDK 显式硬失败，不静默）。
const int kContextOutputReserveTokens = 512;
const int kContextSystemUserReserveTokens = 256;

/// promptJson 走 Binder 事务参数的字符内联上限（F3 传输约束）。
///
/// 超限 → Dart 侧落临时文件、`promptFilePath` 随 Bundle 传短元数据，:engine
/// 读后即删（两侧都不留持久化痕迹）。上限取 60000 字符（最坏 UTF-8 CJK
/// 3B/字符 ≈ 180KB，对 Binder 事务共享缓冲区 ~1MB 保持 >5x 余量）；与
/// [kOnDeviceHistoryCharBudget] 正交——本值只解除**传输**天花板，不放松
/// **推理**窗口。
const int kPromptInlineBinderLimitChars = 60000;

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
///
/// [contextTokens]（模型上下文窗口，[OnDeviceModelOption.contextTokens]）：
/// 非 null 时历史预算按 `contextTokens - 输出预留 - 系统+用户预留` 动态
/// 推导（ASCII 最坏 1 字符 = 1 token 的字符口径）；null = 保持全局
/// [kOnDeviceHistoryCharBudget]（存量 GenieX 系口径）。真机实证
/// （2026-11-02）：全局 1200 字符对 1280-context bundle 的 ASCII 退化
/// 历史必然溢出 → SDK 硬失败。
String buildOnDeviceChatPromptJson(
  List<CloudChatMessage> messages, {
  int? contextTokens,
}) {
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
  // 预算 = 模型感知动态推导（contextTokens 在场）或全局字符预算（存量口径）。
  final int budget = contextTokens != null
      ? (contextTokens -
            kContextOutputReserveTokens -
            kContextSystemUserReserveTokens)
          .clamp(200, 1 << 30)
      : kOnDeviceHistoryCharBudget;
  for (final (role, content)
      in dropOldestWithinBudget(turns, budget)) { // ① 算法单源（策略模式共享）
    out.add({'role': role, 'content': sanitizeChatMLControlTokens(content)});
  }
  return jsonEncode(out);
}

/// 异步构造入口（策略模式接线面）：同 [buildOnDeviceChatPromptJson]，历史
/// 选取改由 [historyPolicy] 承载（默认 ① 滑窗 = 同步入口同源行为）。
///
/// 两侧通用、每侧默认不同（2026-11-02 用户拍板）：云端/混合路径钉死默认 ①；
/// 端侧按模型窗口档位路由（<2k 强制 ①，≥4k 开放 ③ 实验位）。
Future<String> buildOnDeviceChatPromptJsonAsync(
  List<CloudChatMessage> messages, {
  int? contextTokens,
  OnDeviceHistoryPolicy historyPolicy = const DropOldestHistoryPolicy(),
}) async {
  final (systemParts, turns) = splitChatPromptTurns(messages);
  final out = <Map<String, String>>[];
  // dropsSystem（2026-11-03 ⓪ 真裸语义）：策略要求连 system 一起丢——
  // 对照实验与 Gallery 裸问题同形，单变量归因。
  if (systemParts.isNotEmpty && !historyPolicy.dropsSystem) {
    out.add({
      'role': 'system',
      'content': sanitizeChatMLControlTokens(systemParts.join('\n\n')),
    });
  }
  final int budget = contextTokens != null
      ? (contextTokens -
            kContextOutputReserveTokens -
            kContextSystemUserReserveTokens)
          .clamp(200, 1 << 30)
      : kOnDeviceHistoryCharBudget;
  final selected = await historyPolicy.select(turns, budget);
  for (final (role, content) in selected) {
    out.add({'role': role, 'content': sanitizeChatMLControlTokens(content)});
  }
  return jsonEncode(out);
}

/// 消息序列 → (合并后的 system 段, 时序轮次)：同步/异步入口共用的拆分单源。
(List<String>, List<OnDeviceHistoryTurn>) splitChatPromptTurns(
    List<CloudChatMessage> messages) {
  final systemParts = <String>[];
  final turns = <OnDeviceHistoryTurn>[];
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
  return (systemParts, turns);
}
