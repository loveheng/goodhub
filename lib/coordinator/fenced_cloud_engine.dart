/// N7 出站隐私围栏云引擎装饰器（M2-T5b，拍板 D1/D2/D4/D5）。
///
/// 挂点 = CloudLlmEngine 装饰（D1 单咽喉）：对 [send] 全量出站消息
/// （系统/用户/助手结算含工具入参历史/工具结果）强制 PII 遮蔽后转发内层
/// 云引擎；推理返回流做反向还原——正文 delta 与工具入参 delta（按 index
/// 各持一个流式还原器，处理占位符被流式分片切开的场景），Done 前冲刷
/// 扣留缓冲。端侧路径不经过本装饰器（架构口径：局域网回环/端侧不设防）。
///
/// 会话粒度（D2）：**一个 FencedCloudEngine 实例 = 一次 Run 的映射集**
/// （构造即建会话、随实例废弃）。调用方须按 Run 装配——debug 联调页每
/// Run `assembleDefaultHybridEngine`，任务页每 runOnce 重建（降级判据
/// 记忆经 DegradationController 跨 Run 注入保留）。
///
/// 失败语义（D4）：遮蔽操作失败（[PiiMaskException]）→ 有 [PiiFenceDelegate]
/// 时出拦截确认（true=用户显式确认明文发送一次，不记忆不豁免；false=取消）；
/// 无 delegate（无人值守 claim 管道）= fail-closed 抛 [PiiSendBlockedException]，
/// 请求绝不外发——**严禁静默放行**（DEGRADE 禁区，本装饰器无降级路径）。
library;

import 'dart:async';

import '../llm/cloud/cloud_llm.dart';
import 'pii_fence.dart';

/// 遮蔽失败拦截委托（D4 有人值守面）：T5c 挂双选项确认卡。
abstract interface class PiiFenceDelegate {
  /// 返回 true = 用户确认「明文发送一次」（仅本次，不记忆不豁免）；
  /// false = 取消本次发送。
  Future<bool> onMaskBlocked(PiiMaskBlockInfo info);
}

/// 拦截确认上下文（卡片渲染素材）。
class PiiMaskBlockInfo {
  const PiiMaskBlockInfo({
    required this.engineName,
    required this.failureMessage,
    required this.cause,
  });

  final String engineName;

  /// 围栏失败原因（PiiMaskException.message，如「遮蔽超时（3s）」）。
  final String failureMessage;
  final Object cause;
}

/// 围栏拦截异常：请求未外发（用户取消 / 无人值守 fail-closed）。
/// 上抛给环调用方收敛为任务失败/排查卡，绝不含原文。
class PiiSendBlockedException implements Exception {
  const PiiSendBlockedException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => 'PiiSendBlockedException: $message';
}

/// 云引擎围栏装饰器：遮蔽出站 + 反向还原入站流。
class FencedCloudEngine implements CloudLlmEngine {
  FencedCloudEngine({
    required this.inner,
    this.delegate,
    this.maskOverride,
  });

  final CloudLlmEngine inner;

  /// null = 无人值守（fail-closed，D4）。
  final PiiFenceDelegate? delegate;

  /// 联调/测试注入点：替换会话遮蔽（失败路径注入 PiiMaskException）。
  /// 约定仅 debug 联调页与测试传入（注解不可用——同包转发链会报
  /// invalid_use_of_visible_for_testing_member，靠文档约定+评审把守）。
  final Future<String> Function(String text)? maskOverride;


  /// D2：一个实例 = 一次 Run 的映射集（按 Run 装配的纪律见库注释）。
  final PiiRedactionSession _session = PiiRedactionSession();

  @override
  String get name => 'fenced(${inner.name})';

  @override
  Stream<CloudStreamEvent> send(
    CloudChatRequest request, {
    void Function()? onActivity,
  }) async* {
    final masked = await _maskRequest(request);
    final textRestorer = _session.streamRestorer();
    final argRestorers = <int, PiiStreamRestorer>{};
    await for (final e in inner.send(masked, onActivity: onActivity)) {
      switch (e) {
        case CloudTextDelta(:final text):
          final out = textRestorer.push(text);
          if (out.isNotEmpty) yield CloudTextDelta(out);
        case CloudToolCallDelta(
            :final index,
            :final id,
            :final name,
            :final argumentsDelta,
          ):
          var args = argumentsDelta;
          if (args.isNotEmpty) {
            // 并行多工具调用按 index 各持缓冲，防跨流串缓冲
            final r = argRestorers.putIfAbsent(index, _session.streamRestorer);
            args = r.push(args);
          }
          if (id != null || name != null || args.isNotEmpty) {
            yield CloudToolCallDelta(
                index: index, id: id, name: name, argumentsDelta: args);
          }
        case CloudDone(:final finishReason, :final usage):
          // 流收尾：先冲刷全部扣留缓冲再放行 Done（保持「每流恰一 Done」
          // 契约与事件顺序；flush 产物在 Done 前抵达 accumulator）。
          final textTail = textRestorer.flush();
          if (textTail.isNotEmpty) yield CloudTextDelta(textTail);
          for (final entry in argRestorers.entries) {
            final argsTail = entry.value.flush();
            if (argsTail.isNotEmpty) {
              yield CloudToolCallDelta(index: entry.key, argumentsDelta: argsTail);
            }
          }
          yield CloudDone(finishReason: finishReason, usage: usage);
      }
    }
  }

  /// 出站遮蔽：逐消息遮蔽（AssistantMessage 的成品工具入参历史同样遮蔽
  /// ——入站还原后它持有原文，重发须再遮）。失败走 D4 拦截分派。
  Future<CloudChatRequest> _maskRequest(CloudChatRequest request) async {
    try {
      final messages = <CloudChatMessage>[];
      for (final m in request.messages) {
        messages.add(switch (m) {
          SystemMessage(:final content) => SystemMessage(await _mask(content)),
          UserMessage(:final content) => UserMessage(await _mask(content)),
          AssistantMessage(:final content, :final toolCalls) => AssistantMessage(
              content: content == null ? null : await _mask(content),
              toolCalls: [
                for (final c in toolCalls)
                  AssembledToolCall(
                    id: c.id,
                    name: c.name,
                    argumentsJson: await _mask(c.argumentsJson),
                  ),
              ],
            ),
          ToolResultMessage(
            :final toolCallId,
            :final content,
            :final isError,
          ) =>
            ToolResultMessage(
              toolCallId: toolCallId,
              content: await _mask(content),
              isError: isError,
            ),
        });
      }
      return CloudChatRequest(
        messages: messages,
        tools: request.tools,
        temperature: request.temperature,
        maxTokens: request.maxTokens,
      );
    } on PiiMaskException catch (e) {
      final delegate = this.delegate;
      if (delegate == null) {
        throw PiiSendBlockedException(
            'PII 围栏失败且无人值守，fail-closed 拦截发送: ${e.message}', e);
      }
      final approved = await delegate.onMaskBlocked(PiiMaskBlockInfo(
        engineName: inner.name,
        failureMessage: e.message,
        cause: e,
      ));
      if (!approved) {
        throw PiiSendBlockedException('用户取消发送（PII 围栏失败: ${e.message}）', e);
      }
      return request; // 明文发送一次：仅本次、不记忆不豁免（下次失败再确认）
    }
  }

  Future<String> _mask(String text) async {
    final override = maskOverride;
    if (override != null) return override(text);
    return (await _session.mask(text)).text;
  }
}
