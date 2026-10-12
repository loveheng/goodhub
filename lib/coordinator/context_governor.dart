/// Agent Loop 上下文治理（M2-T6，architecture §12）：滑动窗口 + 工具结果摘要化。
///
/// - 滑动窗口在**发送边界**裁剪，本地历史不裁——步数墙放宽 +10 续跑依赖完整
///   上下文，且与 T5 D5「本地历史保留原文、仅发送边界治理」同构；
/// - 摘要化在**回填前**（端侧小模型跑，D1 端侧路径不设防合规；N7 围栏仍在
///   云引擎 engine.send 单咽喉兜底，治理在 send 前、围栏在 send 上，顺序天然正确）；
/// - 摘要化失败兜底 = **保留原文发送 + [DEGRADE] 留痕**（E1 拍板 2026-10-11：
///   摘要化管上下文体积非安全边界，窗口上界兜住体积代价，中止任务代价不成比例）；
/// - 「原文退化为引用」M2 以「宿主注」标记落位，$ref 暂存池引用归 M3 Skill 编排。
library;

import '../core/tokens.dart';
import '../llm/cloud/cloud_llm.dart';
import '../llm/llm.dart';

/// token 字符级粗估口径已下沉 core/tokens.dart（M4-T1：记忆沙盒需同口径且
/// 层级更低，沙盒 ④ 不得逆向依赖编排 ②）——原位 re-export 保持既有 import
/// 兼容（agent_loop / skill_registry / 测试三处引用零改动）。
export '../core/tokens.dart' show estimateTokens;

/// 工具结果摘要器：原文 > 阈值时回填前调用。失败抛异常，由调用方按 E1 兜底。
typedef ToolResultSummarizer = Future<String> Function(String original);

/// 摘要化后的回填内容：摘要正文 + 宿主注引用标记（原文体量留审计可观测）。
/// [refHandle]（M3-T3 put 端）：原文已落 $ref 暂存池时升级为句柄注记——
/// 模型把句柄原样作为下游工具入参传引用（ref-pipeline 纪律），宿主分发前
/// 注水（architecture §9「翻译责任在网关」）。
String summarizedContent(String summary, String original, {String? refHandle}) =>
    '${summary.trim()}\n\n'
    '[宿主注：原工具结果约 ${estimateTokens(original)} tokens，'
    '已由端侧模型摘要化，原文未入上下文'
    '${refHandle == null ? '' : '；完整原文已暂存为 $refHandle，'
        '可把该句柄原样作为下游工具入参传引用（宿主分发前自动注水）'}]';

/// 滑动窗口裁剪（纯函数，不改入参表）：保留开头 System/User 与最近
/// [windowRounds] 轮「Assistant(+tool_calls) → ToolResult*」完整对。
///
/// 轮的起点只认 [AssistantMessage]，裁剪点只落在 Assistant 边界——
/// 严禁把 assistant(tool_calls) 与其后 ToolResult 拆开（OpenAI/Anthropic
/// 配对语义，拆对即协议 400）。可用轮不足 [windowRounds] 时原样返回。
List<CloudChatMessage> trimMessagesToWindow(
  List<CloudChatMessage> messages,
  int windowRounds,
) {
  if (windowRounds <= 0) return List.of(messages);
  final roundStarts = <int>[
    for (var i = 0; i < messages.length; i++)
      if (messages[i] is AssistantMessage) i,
  ];
  if (roundStarts.length <= windowRounds) return List.of(messages);
  // 前导消息（System/User，首轮之前的全部）+ 最近 windowRounds 轮完整对。
  // 保留起点 = 倒数第 windowRounds 轮的 Assistant——窗口滑向最新，旧轮丢弃。
  return [
    ...messages.sublist(0, roundStarts.first),
    ...messages.sublist(roundStarts[roundStarts.length - windowRounds]),
  ];
}

/// 摘要化失败（端侧引擎不可用/空产出/异常）——E1 兜底在调用方，禁静默放行。
class SummarizeException implements Exception {
  const SummarizeException(this.message);

  final String message;

  @override
  String toString() => 'SummarizeException: $message';
}

/// 端侧小模型摘要器（architecture §12：摘要是端侧「单一提取任务」职责内的活）。
///
/// 引擎 [OnDeviceLlmEngine.generate] 的翻译式降级（失败返 null 不抛）在此
/// 收敛为 [SummarizeException]——调用方（agent_loop）按 E1 统一兜底，
/// 本类不做降级决策。不预检 isAvailable：预检与生成间存在竞态，null 翻译
/// 已覆盖不可用路径。
class OnDeviceResultSummarizer {
  OnDeviceResultSummarizer(this._engine);

  final OnDeviceLlmEngine _engine;

  /// 摘要输出上限（端侧产出体量界；T7 调参）。
  static const int summaryMaxTokens = 256;

  static const _system = '你是工具结果摘要器。把给定工具结果压缩为要点，'
      '保留关键数值、状态、结论与错误信息，不添加解释、前言或代码块包裹。';

  Future<String> call(String original) async {
    final out = await _engine.generate(
      original,
      system: _system,
      maxTokens: summaryMaxTokens,
    );
    final t = out?.trim();
    if (t == null || t.isEmpty) {
      throw SummarizeException('端侧摘要产出为空（引擎：${_engine.name}）');
    }
    return t;
  }
}
