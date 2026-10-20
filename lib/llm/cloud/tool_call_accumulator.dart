/// 流式事件累积器：把 [CloudStreamEvent] 流拼装为完整正文与成品工具调用（M2-T1）。
///
/// architecture §2「正文 Token 与 tool_calls 分离」的结算侧：正文 token 流式渲染
/// 走事件流本身；落上下文的 [AssistantMessage]（文本 + 完整 tool_calls）由本器拼装，
/// T2 coordinator 的多轮回填要用。
///
/// 空名调用纪律（2026-10-19，防幻觉直调熔断链）：模型想直接说话或输出格式紊乱时
/// 会吐出 `tool_call(name="")` 这类畸形调用——抛错会炸掉整轮 Run，故与「缺
/// id/name」的协议违规（仍抛 [CloudProtocolException]）区别对待：**丢弃 +
/// DEGRADE 留痕**，[toAssistantMessage] 同口径（回放无失配 tool 消息）。
///
/// **判别前置（2026-10-21 实测）**：真·空名只可能是「首个 delta 即空」；部分
/// OpenAI 兼容端（GLM 系）在每个 arguments 分片里重复带 `name:""`，那不是畸形
/// 调用而是冗余重申——若被写进 [add]，真名会被冲掉、整轮工具全部误判丢弃。
library;

import 'package:flutter/foundation.dart' show debugPrint;

import '../../core/errors/cloud_llm_error.dart';
import 'cloud_llm.dart';

class CloudStreamAccumulator {
  final StringBuffer _text = StringBuffer();
  final Map<int, _ToolCallBuilder> _calls = {};

  /// 结算原因（每流恰好一个 CloudDone；缺失在事件源侧已按协议违规抛错）。
  CloudFinishReason? finishReason;
  CloudUsage? usage;

  void add(CloudStreamEvent event) {
    switch (event) {
      case CloudTextDelta(:final text):
        _text.write(text);
      case CloudToolCallDelta(
          :final index,
          :final id,
          :final name,
          :final argumentsDelta,
        ):
        final builder = _calls.putIfAbsent(index, _ToolCallBuilder.new);
        if (id != null) builder.id = id;
        // 空名覆盖防御（2026-10-21 实测根因）：OpenAI 兼容端（SiliconFlow
        // `zai-org/GLM-5.3-Flash`）在首个 delta 给出真名后，**后续每个
        // arguments 分片仍重复携带 `name:""`**——无条件覆盖会把真名冲成空串，
        // 结算即按畸形调用丢弃（表现为整轮「空名 tool_call」、工具永不执行）。
        // 区分两种空名：① 首帧即空（真·畸形调用）→ 照常写入，留给结算层丢弃；
        // ② 已有真名后重申空串 → 忽略（空串不是"未提供"，是分片的冗余重申）。
        if (name != null && (name.isNotEmpty || builder.name == null)) {
          builder.name = name;
        }
        builder.arguments.write(argumentsDelta);
      case CloudDone(:final finishReason, :final usage):
        this.finishReason = finishReason;
        if (usage != null) this.usage = usage;
    }
  }

  /// 顺序消费整个流并累积（协议错误原样透传给调用方）。
  static Future<CloudStreamAccumulator> drain(Stream<CloudStreamEvent> events) async {
    final acc = CloudStreamAccumulator();
    await for (final e in events) {
      acc.add(e);
    }
    return acc;
  }

  String get text => _text.toString();

  /// 成品工具调用（按增量 index 升序）。
  ///
  /// 空名（含纯空白）调用不计入成品：丢弃 + DEGRADE 留痕（原始 index/id/
  /// 入参摘要，真机复现可对账成因）——丢弃后本轮若无其他调用即走自然结算
  /// （纯文本交付），历史不同步该调用（回放无失配 tool 消息）。
  List<AssembledToolCall> get toolCalls {
    final indices = _calls.keys.toList()..sort();
    final out = <AssembledToolCall>[];
    for (final i in indices) {
      final builder = _calls[i]!;
      final name = builder.name;
      if (name != null && name.trim().isEmpty) {
        debugPrint('[DEGRADE] tool-call-accumulator: 丢弃空名 tool_call'
            '（index=$i, id=${builder.id}, arguments=${builder.arguments}）');
        continue;
      }
      out.add(builder.build());
    }
    return out;
  }

  /// 结算为可回填上下文的助手消息。
  AssistantMessage toAssistantMessage() => AssistantMessage(
        content: text.isEmpty ? null : text,
        toolCalls: toolCalls,
      );
}

class _ToolCallBuilder {
  String? id;
  String? name;
  final StringBuffer arguments = StringBuffer();

  AssembledToolCall build() {
    final i = id;
    final n = name;
    if (i == null || n == null) {
      throw const CloudProtocolException('tool_call 流结束仍缺 id/name，无法结算');
    }
    return AssembledToolCall(id: i, name: n, argumentsJson: arguments.toString());
  }
}
