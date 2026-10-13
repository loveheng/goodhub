/// Agent Loop 核心环（M2-T2 建，T4b 挂熔断与步数墙排查卡）：流式推理 + 工具执行环。
///
/// - 正文 delta 以事件透传（UI 流式渲染），工具调用以事件通告执行前后；
///   M3-T2 增 [LoopToolProgress] 进度事件（face.onProgress 桥接，事件序
///   Started → Progress* → Finished）与 [abort] 用户中止（边界停下 + LoopFinished）；
/// - 工具执行错误以 isError 结果回填上下文继续循环（模型可自纠）；同工具连续
///   [breakerThreshold] 次报错触发两步熔断（C1 按工具计数）——有 [blockDelegate]
///   时出排查卡（单步重试/跳过/人工接管），无人值守强中止；
/// - 步数墙 [maxTurns] 耗尽仍要求工具 → 排查卡（人工批准放宽 +10 续跑）或终止；
/// - L1/L2 网关 T4a 已以装饰器插在 executor 之前（本环不做权限裁决）；
/// - 上下文治理 T6 已挂接：发送边界滑动窗口（本地历史不裁）+ 回填前工具
///   结果摘要化（端侧小模型；失败按 E1 保留原文 + [DEGRADE] 留痕）——
///   见 context_governor.dart；
/// - 接线约束：本环的引擎须能承接工具请求——混合路由下恒走云端（§2 端侧
///   不承担通用调度）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/errors/inference_error.dart';
import '../llm/cloud/cloud_llm.dart';
import '../llm/cloud/tool_call_accumulator.dart';
import 'context_governor.dart';
import 'ref_store.dart';
import 'tool_breaker.dart';

/// Agent Loop 事件（UI 双轨/遥测消费）。
sealed class AgentLoopEvent {
  const AgentLoopEvent();
}

class LoopTextDelta extends AgentLoopEvent {
  const LoopTextDelta(this.text);

  final String text;
}

class LoopToolCallStarted extends AgentLoopEvent {
  const LoopToolCallStarted(this.call);

  final AssembledToolCall call;
}

/// 工具执行进度（M3-T2，ai-app-split.md §3.9 收侧消费）：McpToolFace.onProgress
/// 桥接产物，操作轨卡 Running(progress) 态数据源。事件序恒
/// Started → Progress* → Finished（工具串行执行保证）。
class LoopToolProgress extends AgentLoopEvent {
  const LoopToolProgress({
    required this.call,
    required this.progress,
    this.total,
    this.message,
  });

  final AssembledToolCall call;
  final num progress;
  final num? total;
  final String? message;
}

class LoopToolCallFinished extends AgentLoopEvent {
  const LoopToolCallFinished({required this.call, required this.result});

  final AssembledToolCall call;
  final ToolExecutionResult result;
}

/// 收尾：模型自然结算（无工具调用待执行）。
class LoopFinished extends AgentLoopEvent {
  const LoopFinished({
    required this.text,
    required this.finishReason,
    required this.turns,
    required this.transcript,
  });

  final String text;
  final CloudFinishReason finishReason;

  /// 实际消耗轮数（步数墙观测）。
  final int turns;

  /// 会话历史切片（M4-T3 D11 多轮上下文）：本 run 结束时的完整消息序列，
  /// 不含 System（下轮 systemPrompt 重组装）与「未配对尾巴」（Abort 打断
  /// 工具环时 assistant(tool_calls) 可能只有部分结果回填——整段剔除，协议
  /// 可回放优先：拆对即 400，部分结果信息已在轨道呈现）。调用方原样作下轮
  /// `run(history:)` 传入。
  final List<CloudChatMessage> transcript;
}

/// 工具执行结果。
class ToolExecutionResult {
  const ToolExecutionResult({required this.content, this.isError = false});

  final String content;
  final bool isError;
}

/// 工具执行环接口（MCP 实现 mcp_tool_face.dart；L1/L2 网关装饰在其前）。
abstract interface class ToolExecutor {
  Future<ToolExecutionResult> execute(AssembledToolCall call);
}

class AgentLoop {
  AgentLoop({
    required this.engine,
    required this.executor,
    this.blockDelegate,
    this.maxTurns = 10,
    this.breakerThreshold = 2,
    this.windowRounds = 6,
    this.summarizeThresholdTokens = 1000,
    this.summarizer,
    this.refStore,
    this.refServerId = 'goodshare',
    this.serverResolver,
    this.toolsProvider,
  });

  final CloudLlmEngine engine;
  final ToolExecutor executor;

  /// 排查卡委托（熔断三操作 + 步数墙放宽/终止）；null = 无人值守强中止。
  final BlockDelegate? blockDelegate;

  /// 步数墙初值（architecture §12：max_turns=10 可配；人工批准后 +10 续跑）。
  final int maxTurns;

  /// 两步熔断阈值（C1 拍板：同工具连续 2 次报错，T7 实测调参）。
  final int breakerThreshold;

  /// 滑动窗口轮数（architecture §12：仅留最近 N 轮原始对，N 初值 6 可配）。
  /// 发送边界裁剪、本地历史不裁——步数墙放宽续跑依赖完整上下文。
  final int windowRounds;

  /// 工具结果摘要化阈值（token 字符级粗估，>阈值回填前端侧摘要；T7 调参）。
  final int summarizeThresholdTokens;

  /// 端侧结果摘要器；null = 不摘要化（纯窗口治理，测试/无端侧引擎路径）。
  final ToolResultSummarizer? summarizer;

  /// $ref 暂存池（M3-T3 put 端）：摘要化成功路径原文落池、宿主注升级句柄
  /// 注记（§9 句柄是模型侧行话，翻译责任在网关域——与 HydratingExecutor
  /// 读端同域）；null = 不落池（宿主注维持 M2 引用标记形态）。
  final RefStore? refStore;

  /// 落池句柄的来源 Server 绑定（单 Server 阶段恒 'goodshare'，多 Server
  /// ToolRouter 接线时随连接装配，与 McpToolFace.serverId 同口径）。
  final String refServerId;

  /// 前缀工具名 → 来源 serverId（M4-T6：装配层接 ToolRouter.serverFor）——
  /// put 端 $ref 句柄来源按调用目标标注；null = 落 [refServerId]。
  final String? Function(String toolName)? serverResolver;

  /// 每轮工具清单提供器（M4-T6：支持运行时 JIT 激活后刷新 tools 列表——装配层
  /// 接 `ToolRouter.activatedSchemas()` + JIT 元工具静态声明；null = 用 [run]
  /// 传入的静态 [tools]）。
  final List<CloudToolSchema> Function()? toolsProvider;

  /// 步数墙人工批准的单次放宽步长（C3 拍板：+10 续跑）。
  static const int stepWallRelaxStep = 10;

  /// run() 期间的输出通道（M3-T2 控制器承载——async* 生成器无法在工具执行
  /// await 期间插入 [LoopToolProgress]）；非 run 期为 null（进度注入 no-op）。
  StreamController<AgentLoopEvent>? _out;

  /// 当前执行中的调用（进度事件归属锚点；工具串行执行保证唯一）。
  AssembledToolCall? _activeCall;
  bool _aborted = false;

  /// 工具进度注入口（M3-T2）：装配层把 McpToolFace.onProgress 桥接到此——
  /// run() 消费期间收到的进度以 [LoopToolProgress] 事件流出（挂当前活跃调用；
  /// 工具名不匹配的迟到帧丢弃）。run() 期外调用为 no-op。
  void emitToolProgress(String toolName, num progress, num? total, String? message) {
    final out = _out;
    final call = _activeCall;
    if (out == null || call == null || call.name != toolName) return;
    out.add(LoopToolProgress(
      call: call,
      progress: progress,
      total: total,
      message: message,
    ));
  }

  /// 用户中止（M3-T2，architecture §10 级联的环内侧）：在下一个边界（引擎
  /// 流 / 工具执行前）停下并发 [LoopFinished]。已 Started 的在途调用不打断
  /// （Dart Future 不可中断）——其 Finished 事件照常回填后收尾；未 Started
  /// 的调用不再执行。UI Abort 级联的 ③ $/cancelRequest 由 McpToolFace 负责。
  void abort() => _aborted = true;

  /// 控制器承载：进度回调与 abort 检查要求在工具执行 await 期间仍能注入
  /// 事件——async* 生成器做不到。消费者 `await for` 语义与生成器完全一致
  /// （错误经流传递、正常关闭）；与生成器的差异仅在「消费者提前取消订阅」
  /// 时环不再被暂停而会跑完——宿主唯一消费者（debug 页/双轨流）只经 [abort]
  /// 主动停止，不裸取消订阅。
  Stream<AgentLoopEvent> run({
    required String systemPrompt,
    required String userPrompt,
    List<CloudToolSchema> tools = const [],
    List<CloudChatMessage> history = const [],
  }) {
    final out = StreamController<AgentLoopEvent>();
    _out = out;
    unawaited(Future<void>(() async {
      try {
        await _runCore(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            tools: tools,
            history: history);
      } catch (e, st) {
        out.addError(e, st);
      } finally {
        _out = null;
        _activeCall = null;
        await out.close();
      }
    }));
    return out.stream;
  }

  Future<void> _runCore({
    required String systemPrompt,
    required String userPrompt,
    List<CloudToolSchema> tools = const [],
    List<CloudChatMessage> history = const [],
  }) async {
    final out = _out!;
    void emit(AgentLoopEvent e) => out.add(e);
    // D11 多轮上下文：System 每轮重组（Skill 激活集跨 run 演进），历史原样
    // 前插（不含 System——见 [LoopFinished.transcript] 口径）。
    final messages = <CloudChatMessage>[
      SystemMessage(systemPrompt),
      ...history,
      UserMessage(userPrompt),
    ];
    var wallLimit = maxTurns;
    var turn = 0;
    // 熔断按工具计数（C1）；本方法 = 一个用户轮次，计数天然从零开始
    final failures = <String, int>{};
    while (true) {
      if (_aborted) {
        emit(LoopFinished(
            text: '',
            finishReason: CloudFinishReason.stop,
            turns: turn,
            transcript: _sessionTranscript(messages)));
        return;
      }
      turn++;
      final acc = CloudStreamAccumulator();
      await for (final e in engine.send(
        // 滑动窗口在发送边界裁剪（T6）：本地 messages 不动，步数墙放宽
        // 续跑时上下文完整；裁剪纯函数保证 Assistant/ToolResult 配对完整。
        CloudChatRequest(
          messages: trimMessagesToWindow(messages, windowRounds),
          tools: toolsProvider?.call() ?? tools,
        ),
      )) {
        if (_aborted) break; // 引擎流中途中止：断流结算（已收 delta 保留在 acc）
        acc.add(e);
        if (e is CloudTextDelta) emit(LoopTextDelta(e.text));
      }
      if (_aborted) {
        // 引擎流中途中止：部分产出按普通 assistant 消息入历史（协议安全）。
        if (acc.text.isNotEmpty) {
          messages.add(AssistantMessage(content: acc.text));
        }
        emit(LoopFinished(
            text: acc.text,
            finishReason: CloudFinishReason.stop,
            turns: turn,
            transcript: _sessionTranscript(messages)));
        return;
      }
      final calls = acc.toolCalls;
      if (calls.isEmpty) {
        // 自然结算：终文入历史（transcript 完整供下轮续接）。
        if (acc.text.isNotEmpty) {
          messages.add(AssistantMessage(content: acc.text));
        }
        emit(LoopFinished(
          text: acc.text,
          finishReason: acc.finishReason ?? CloudFinishReason.stop,
          turns: turn,
          transcript: _sessionTranscript(messages),
        ));
        return;
      }
      messages.add(acc.toAssistantMessage());
      for (final call in calls) {
        if (_aborted) {
          emit(LoopFinished(
              text: acc.text,
              finishReason: CloudFinishReason.stop,
              turns: turn,
              transcript: _sessionTranscript(messages)));
          return;
        }
        emit(LoopToolCallStarted(call));
        _activeCall = call;
        final result = await _executeWithBreaker(call, failures);
        _activeCall = null;
        emit(LoopToolCallFinished(call: call, result: result));
        messages.add(ToolResultMessage(
          toolCallId: call.id,
          content: await _governedContent(
            result.content,
            serverId: serverResolver?.call(call.name),
          ),
          isError: result.isError,
        ));
      }
      if (turn >= wallLimit) {
        final delegate = blockDelegate;
        if (delegate == null) {
          throw InferenceException('步数墙触发：连续 $wallLimit 轮工具调用未收尾');
        }
        final relax = await delegate.onStepWallReached(
          StepWallReport(turnsUsed: turn, limit: wallLimit),
        );
        if (!relax) {
          throw InferenceException('步数墙终止：$turn 轮未收尾，用户选择终止');
        }
        wallLimit += stepWallRelaxStep;
      }
    }
  }

  /// 执行单个调用并施两步熔断（C1 按工具计数 + C3 排查卡三操作）。
  Future<ToolExecutionResult> _executeWithBreaker(
    AssembledToolCall call,
    Map<String, int> failures,
  ) async {
    while (true) {
      ToolExecutionResult result;
      try {
        result = await executor.execute(call);
      } catch (e) {
        // 协议异常收敛为 isError 结果——与 isError 回填同轨计数（C1）
        result = ToolExecutionResult(content: '工具执行失败: $e', isError: true);
      }
      if (!result.isError) {
        failures[call.name] = 0; // 该工具成功重置；他工具成败不影响本工具计数
        return result;
      }
      final count = (failures[call.name] ?? 0) + 1;
      failures[call.name] = count;
      if (count < breakerThreshold) return result;
      final delegate = blockDelegate;
      if (delegate == null) {
        throw InferenceException(
          '两步熔断：工具 ${call.name} 连续 $count 次执行报错，强中止（排查卡需 UI 宿主）',
        );
      }
      final resolution = await delegate.onBreakerTripped(BreakerReport(
        toolName: call.name,
        consecutiveFailures: count,
        lastError: result.content,
        argumentsJson: call.argumentsJson,
      ));
      if (resolution is SkipOnce) return result; // 跳过不重置（C1）
      if (resolution is ManualResult) {
        return ToolExecutionResult(content: resolution.text, isError: false);
      }
      failures[call.name] = 0; // RetryOnce：人工干预=计数重置，重发同调用
    }
  }

  /// 会话历史切片（D11）：剔除 System 与「未配对尾巴」——Abort 打断工具环
  /// 时 assistant(tool_calls) 可能只有部分 ToolResult 回填，整段剔除（协议
  /// 可回放优先：拆对即 400；被剔除段的信息已在轨道呈现）。纯函数。
  List<CloudChatMessage> _sessionTranscript(List<CloudChatMessage> messages) {
    final out = <CloudChatMessage>[];
    var i = 0;
    while (i < messages.length) {
      final m = messages[i];
      if (m is SystemMessage) {
        i++;
        continue;
      }
      if (m is AssistantMessage && m.toolCalls.isNotEmpty) {
        final unpaired =
            m.toolCalls.map((c) => c.id).toSet();
        final paired = <CloudChatMessage>[];
        var j = i + 1;
        while (j < messages.length && messages[j] is ToolResultMessage) {
          final r = messages[j] as ToolResultMessage;
          if (!unpaired.remove(r.toolCallId)) break;
          paired.add(r);
          j++;
        }
        if (unpaired.isNotEmpty) break; // 未全配对：连同该 assistant 整段截断
        out.add(m);
        out.addAll(paired);
        i = j;
        continue;
      }
      out.add(m);
      i++;
    }
    return out;
  }

  /// 回填前治理（T6 + M3-T3 put 端）：>阈值走端侧摘要化；摘要化成功时原文
  /// 落 $ref 暂存池、宿主注升级句柄注记——「大出参 → 句柄 → 下游工具入参
  /// 注水」写管道闭环（§9/§12）。失败分层：摘要化失败按 E1 保留原文直传
  /// （原文已直传，不落池）；落池失败降级为无句柄注记（摘要照常回填）——
  /// 两处均禁静默，[DEGRADE] 留痕。
  Future<String> _governedContent(String original, {String? serverId}) async {
    final summarize = summarizer;
    if (summarize == null) return original;
    if (estimateTokens(original) <= summarizeThresholdTokens) return original;
    String summary;
    try {
      summary = await summarize(original);
    } catch (e) {
      debugPrint('[DEGRADE] context-governor: 摘要化失败保留原文: $e');
      return original;
    }
    String? handle;
    final store = refStore;
    if (store != null) {
      try {
        handle = await store.put(
            serverId: serverId ?? refServerId, payload: original);
      } catch (e) {
        debugPrint('[DEGRADE] context-governor: \$ref 落池失败（回填无句柄注记）: $e');
      }
    }
    return summarizedContent(summary, original, refHandle: handle);
  }
}
