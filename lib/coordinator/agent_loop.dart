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
import '../core/tool_result.dart';
import '../llm/cloud/cloud_llm.dart';
import '../llm/cloud/tool_call_accumulator.dart';
import 'context_governor.dart';
import 'ref_store.dart';
import 'tool_breaker.dart';
import 'workspace_stream_filter.dart';

export '../core/tool_result.dart';

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

/// 思考过程增量（2026-10-21，M1）：云端推理型模型的思维流透传——UI 思考轨
/// 数据源（默认收起）。**展示 only**：环内 `continue` 早退，不进 accumulator
/// （不入历史）、不过 workspace_filter（In-band 提取只解析正文）、不影响
/// 空产出判定；契约见 [CloudThinkingDelta]。
class LoopThinkingDelta extends AgentLoopEvent {
  const LoopThinkingDelta(this.text);

  final String text;
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

/// 工具执行结果（已下沉 `core/tool_result.dart`，arch-hardening ②；本文件
/// 顶部 re-export 保既有引用稳定——Expand-Contract 收口时统一切 import）。

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
    this.windowStep = 6,
    this.summarizeThresholdTokens = 1000,
    this.summarizer,
    this.refStore,
    this.refServerId = 'goodshare',
    this.serverResolver,
    this.toolsProvider,
    this.onRoundCommitted,
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

  /// 阶梯截断步长（context-stepped-pruning §2.1，仅 [summarizer] != null 生效）：
  /// 可用轮 ≤ windowRounds + windowStep 时纯追加不裁剪（吃满前缀缓存），
  /// 触线一次性剪出 windowStep 轮交端侧摘要器归档，保留区回到 windowRounds。
  /// null/≤0 语义上等同关闭——默认 6 与低水位同宽（高低水位 6~12）。
  final int windowStep;

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

  /// 工具轮结算回调（prompt-mgmt §8.2.2 切域事务提交点）：一轮全部
  /// ToolResultMessage 回填进历史之后触发——装配层挂 `router.commitPendingSlot`
  /// 把 use_server 的 pending 槽位请求落到活跃槽位。提交前 Abort/失败不触发
  /// （槽位保持原状），提交后不回滚（切换是显式意图）。null = 无事务需求。
  final void Function()? onRoundCommitted;

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
  /// 的调用不再执行。UI Abort 级联的 ③ notifications/cancelled 由 McpToolFace 负责。
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

    /// 动态尾部段（P1-3b / §8.1 断点 A）：非空时 [systemPrompt] 视为静态前缀
    /// （挂 `cache_control: ephemeral` 断点），本段（如记忆区）作为无断点
    /// System 块置后——记忆增长不顶掉静态前缀缓存边界。null = 旧单块形态。
    String? systemTail,

    /// In-band 捎带提取分流器（P2-3 / §3.3，G2）：非空时正文 delta 经其
    /// 实时分流——UI 只收剥离后的纯文本；自然结算轮（`calls.isEmpty`）历史与
    /// 终文用剥离后文本；tool-call 结算轮挂 [WorkspaceStreamFilter.cancelCommit]
    /// 禁提交；abort 挂 [WorkspaceStreamFilter.discard]。null = 功能关闭。
    WorkspaceStreamFilter? workspaceFilter,

    /// 记忆增量区沉底注入（context-stepped-pruning §6.5）：非空时以
    /// UserMessage 形态插在 history 之后、userPrompt 之前——高频变化项沉底，
    /// 不推移其前的稳定前缀（快照+窗口原文）。内容经 [WorkspaceStreamFilter
    /// .escapeUserTag] 消毒。null/空 = 不注入。
    String? contextFooter,

    /// 合成桩判定（P3-2 / §9.1，D-H）：返回 true 的工具，其历史 `tool_call`
    /// 与配对 `tool_result` 在**发送边界**替换为合成占位桩（保留 matching id，
    /// 防 OpenAI/Anthropic 严格成对校验 400）。判定源 = 装配层读 router 投影
    /// 态（私有 server 已让位当前私有槽位）。null = 不脱敏。
    bool Function(String toolName)? maskTool,
  }) {
    // A03（review-fix-2026-10）：单次使用契约（Run 级句柄）——重入会覆盖
    // `_out`，首个 run 的 finally 置空会打掉第二个 run 的进度通道。预中止
    // （abort 先于 run，装配期取消通道 F19）是合法形态：run 后首个 _aborted
    // 检查即 LoopFinished(stop) 收尾。
    assert(_out == null, 'AgentLoop.run 不允许重入——单次使用（Run 级句柄），'
        '复用会覆盖 _out 打掉首个 run 的事件通道');
    final out = StreamController<AgentLoopEvent>();
    _out = out;
    unawaited(Future<void>(() async {
      try {
        await _runCore(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            tools: tools,
            history: history,
            systemTail: systemTail,
            workspaceFilter: workspaceFilter,
            contextFooter: contextFooter,
            maskTool: maskTool);
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
    String? systemTail,
    WorkspaceStreamFilter? workspaceFilter,
    String? contextFooter,
    bool Function(String toolName)? maskTool,
  }) async {
    final out = _out!;
    void emit(AgentLoopEvent e) => out.add(e);
    // D11 多轮上下文：System 每轮重组（Skill 激活集跨 run 演进），历史原样
    // 前插（不含 System——见 [LoopFinished.transcript] 口径）。
    // P1-3b（§8.1 断点 A）：带 tail 时静态前缀挂缓存断点、动态记忆置尾。
    // P2-4（§9.3）：用户侧 `<` 全量转义——只有模型自身生成的裸
    // `<workspace_update_v1>` 能触发提取；转义幂等（&lt; 不含 <）。
    final messages = <CloudChatMessage>[
      SystemMessage(
        systemPrompt,
        cacheControl:
            systemTail != null ? CacheControl.ephemeral : null,
      ),
      if (systemTail != null) SystemMessage(systemTail),
      for (final m in history)
        m is UserMessage
            ? UserMessage(WorkspaceStreamFilter.escapeUserTag(m.content))
            : m,
      // §6.5（context-stepped-pruning）：记忆增量区沉底——插在 history 之后、
      // 本轮提问之前，不推移其前的稳定前缀（快照+窗口原文）。
      if (contextFooter != null && contextFooter.isNotEmpty)
        UserMessage(WorkspaceStreamFilter.escapeUserTag(contextFooter)),
      UserMessage(WorkspaceStreamFilter.escapeUserTag(userPrompt)),
    ];
    var wallLimit = maxTurns;
    var turn = 0;
    // 熔断按工具计数（C1）；本方法 = 一个用户轮次，计数天然从零开始
    final failures = <String, int>{};
    // 归档摘要（context-stepped-pruning §2.2，Run 级滚动）：阶梯截断触线时
    // 被裁轮次经端侧摘要器归档于此，摘要块插装 System 后、保留窗口前。
    // Run 间不持久化——本地 transcript 全量，下个 Run 重算（端侧零计费）。
    var archivedSummary = '';
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
      // P2-3（G2）：剥离后纯文本累积——历史与终文用，防结构化 JSON 污染 canonical。
      final filteredText = StringBuffer();
      final filter = workspaceFilter;
      // 发送边界窗口治理（context-stepped-pruning §2.1/§2.3）：summarizer 在位
      // 走阶梯截断（高低水位 windowRounds ~ windowRounds+windowStep，触线归档
      // 摘要）；null = 纯云/测试路径，保持朴素滑动契约不变。摘要失败按 E1
      // 口径弃归档降级朴素滑动，[DEGRADE] 留痕（宁丢归档不失可用性）。
      var sendMessages = trimMessagesToWindow(messages, windowRounds);
      final summarize = summarizer;
      if (summarize != null && windowStep > 0) {
        final stepped = steppedWindow(
          messages,
          low: windowRounds,
          step: windowStep,
        );
        if (stepped.pruned.isNotEmpty) {
          try {
            final corpus = archivedSummary.isEmpty
                ? _roundsCorpus(stepped.pruned)
                : '既有归档摘要：\n$archivedSummary\n\n\n新完成轮次原文：\n'
                    '${_roundsCorpus(stepped.pruned)}';
            archivedSummary = (await summarize(corpus)).trim();
            if (archivedSummary.isEmpty) {
              throw const SummarizeException('归档摘要产出为空');
            }
          } on Object catch (e) {
            debugPrint('[DEGRADE] agent-loop: 归档摘要失败，弃归档降级朴素滑动: $e');
            archivedSummary = '';
          }
        }
        if (archivedSummary.isNotEmpty) {
          sendMessages = _withArchiveSummary(stepped.kept, archivedSummary);
        }
      }
      await for (final e in engine.send(
        // 滑动窗口在发送边界裁剪（T6）：本地 messages 不动，步数墙放宽
        // 续跑时上下文完整；裁剪纯函数保证 Assistant/ToolResult 配对完整。
        CloudChatRequest(
          messages: _applySyntheticMasking(
            sendMessages,
            maskTool: maskTool,
          ),
          tools: toolsProvider?.call() ?? tools,
        ),
      )) {
        if (_aborted) break; // 引擎流中途中止：断流结算（已收 delta 保留在 acc）
        // 思考流（2026-10-21 M1）：展示 only 早退——禁入 acc（不入历史/不参与
        // 空产出判定）、禁过 filter（In-band 提取 FSM 只解析正文）。
        if (e is CloudThinkingDelta) {
          emit(LoopThinkingDelta(e.text));
          continue;
        }
        acc.add(e);
        if (e is CloudTextDelta) {
          final passthrough = filter?.feed(e.text) ?? e.text;
          filteredText.write(passthrough);
          emit(LoopTextDelta(passthrough));
        }
      }
      if (_aborted) {
        // 引擎流中途中止：部分产出按普通 assistant 消息入历史（协议安全）。
        // G6：abort 全量复位 FSM——残留 pending/json 缓冲丢弃，下轮干净起步。
        filter?.discard();
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
        // 自然结算：终文入历史（transcript 完整供下轮续接）。G2：剥离
        // `<workspace_update_v1>` 段后再入历史（UI 已实时分流，此处保 canonical）。
        final clean = filter?.feed('') ?? ''; // 冲刷残留 Hold 前缀（若有）
        filteredText.write(clean);
        final settledText = filter == null ? acc.text : filteredText.toString();
        if (settledText.isNotEmpty) {
          messages.add(AssistantMessage(content: settledText));
        } else if (acc.finishReason == CloudFinishReason.toolCalls) {
          // 防静默洞：模型声明了工具调用但全部是空名畸形调用（accumulator 已
          // 丢弃并 DEGRADE 留痕）——既无执行也无文本，静默结算 = 用户零反馈
          // （比熔断更糟）。上抛走窗口白话错误卡（P0-2 重试入口），与步数墙
          // 终止同径；abort 路径与此无关（用户主动中止，允许空产出）。
          throw InferenceException(
              '模型本轮仅有无效工具调用（空名 tool_call），未产出可用内容');
        }
        emit(LoopFinished(
          text: settledText,
          finishReason: acc.finishReason ?? CloudFinishReason.stop,
          turns: turn,
          transcript: _sessionTranscript(messages),
        ));
        return;
      }
      // G2 tool-call 轮硬压（§3.3）：清空 FSM 累积缓冲并禁止本段提交。
      filter?.cancelCommit();
      messages.add(acc.toAssistantMessage());
      // P3-1（D-J/§10.2）：单轮多 tool_calls 并发编排——Future.wait 派发下游；
      // _executeWithBreaker 把任一异常收敛为 isError ToolResult（绝不向上抛
      // 中断流），全量回填 100% tool_call_id 配对（OpenAI/Anthropic 严格校验）。
      // 注：_activeCall 单槽在并发下交错——进度药丸为尽力而为 UI 信号。
      final settled = await Future.wait([
        for (final call in calls)
          () async {
            emit(LoopToolCallStarted(call));
            _activeCall = call;
            try {
              final result = await _executeWithBreaker(call, failures);
              final governed = await _governedContent(
                result.content,
                serverId: serverResolver?.call(call.name),
              );
              return (call: call, result: result, governed: governed);
            } finally {
              _activeCall = null;
            }
          }(),
      ]);
      // 回填按原序（Future.wait 保序）——canonical 历史与 tool_use 顺序一致。
      for (final s in settled) {
        emit(LoopToolCallFinished(call: s.call, result: s.result));
        messages.add(ToolResultMessage(
          toolCallId: s.call.id,
          content: s.governed,
          isError: s.result.isError,
        ));
      }
      // 切域事务提交点（§8.2.2）：ToolResultMessage 已全量落历史快照 →
      // 允许 pending 槽位请求提交（此后取消/失败不回滚）。
      onRoundCommitted?.call();
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

  /// 被裁轮次的归档语料（context-stepped-pruning §2.2）：平铺为角色前缀文本
  /// 供摘要器压缩。ToolResult 原文照送——摘要器输出有 maxTokens 封顶，
  /// 输入侧体量由批次步长天然有界。
  static String _roundsCorpus(List<CloudChatMessage> rounds) => [
        for (final m in rounds)
          switch (m) {
            SystemMessage(:final content) => 'System: $content',
            UserMessage(:final content) => 'User: $content',
            AssistantMessage(:final content) =>
              'Assistant: ${content ?? '(tool_calls)'}',
            ToolResultMessage(:final content) => 'ToolResult: $content',
          },
      ].join('\n\n');

  /// 归档摘要块插装：置于前导消息（System/静态区）之后、第一个保留轮
  /// （Assistant）之前——摘要变更频率低（每批一次），不顶掉静态前缀缓存。
  static List<CloudChatMessage> _withArchiveSummary(
    List<CloudChatMessage> kept,
    String summary,
  ) {
    final note = UserMessage(
      '[宿主注：以下为此前对话轮次的归档摘要（端侧生成，原文已移出上下文）'
      '——已定事实与结论以摘要为准]\n$summary',
    );
    final firstRound = kept.indexWhere((m) => m is AssistantMessage);
    if (firstRound <= 0) return [note, ...kept];
    return [
      ...kept.sublist(0, firstRound),
      note,
      ...kept.sublist(firstRound),
    ];
  }

  /// 回填前治理（T6 + M3-T3 put 端）：**入口先过 D-I 物理硬地板**（超大输出
  /// 无论摘要器是否可用先截断，摘要失败也不回退超界原文）；>摘要阈值再走
  /// 端侧摘要化；摘要化成功时原文落 $ref 暂存池、宿主注升级句柄注记——「大
  /// 出参 → 句柄 → 下游工具入参注水」写管道闭环（§9/§12）。失败分层：摘要化
  /// 失败按 E1 保留（截断后）原文直传；落池失败降级为无句柄注记——两处均
  /// 禁静默，[DEGRADE] 留痕。
  Future<String> _governedContent(String original, {String? serverId}) async {
    original = _hardTruncateOutput(original);
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

  /// D-I（P3-3 / §10.4）：超大工具输出的确定性硬地板——与摘要正交、始终
  /// 生效（`summarizer == null` 纯云路径与摘要失败旁路此前零上限直入上下文，
  /// 击穿单轮窗口与预算）。Head 50 + Tail 20 行折叠，中段插系统注记；折叠后
  /// 仍超界（长行）→ 字符级再截，保证 estimateTokens 恒不超上界。
  static const int kToolResultHardCapTokens = 2000; // T-调参：随真机预算校准

  String _hardTruncateOutput(String original) {
    if (estimateTokens(original) <= kToolResultHardCapTokens) return original;
    const headLines = 50, tailLines = 20;
    const noticeTmpl =
        '[... Output truncated: {n} characters omitted. '
        'Use specific filter or offset/limit to read more ...]';
    String folded;
    if (original.split('\n').length > headLines + tailLines) {
      final lines = original.split('\n');
      final head = lines.take(headLines).join('\n');
      final tail = lines.skip(lines.length - tailLines).join('\n');
      final omitted = original.length - head.length - tail.length;
      folded = '$head\n${noticeTmpl.replaceAll('{n}', '$omitted')}\n$tail';
    } else {
      folded = original;
    }
    // 字符级保底：折叠后仍超界（长行场景）→ 硬切，上界恒成立。
    if (estimateTokens(folded) > kToolResultHardCapTokens) {
      final omitted = folded.length - kToolResultHardCapTokens;
      folded =
          '${folded.substring(0, kToolResultHardCapTokens)}\n'
          '${noticeTmpl.replaceAll('{n}', '$omitted')}';
    }
    debugPrint('[DEGRADE] context-governor: 工具输出超 $kToolResultHardCapTokens tokens '
        '已物理截断（D-I 硬地板）');
    return folded;
  }

  /// D-H（P3-2 / §9.1）：切换私有域的发送边界投影——已让位私有域的历史
  /// `tool_call` / 配对 `tool_result` 保留 matching `id`、替换为合成占位桩
  /// （OpenAI/Anthropic 严格成对校验：物理删除任一方即 400）。本地 canonical
  /// 历史不动（D11 双轨口径：本地留全、发送侧治理）。null 判定 = 直通。
  static const kSyntheticMaskedTool = 'redacted_private_tool';
  static const kSyntheticMaskedNotice =
      '[System Notice: The output of this private tool execution has been '
      'masked because the active workspace domain was switched.]';

  List<CloudChatMessage> _applySyntheticMasking(
    List<CloudChatMessage> input, {
    bool Function(String toolName)? maskTool,
  }) {
    if (maskTool == null) return input;
    final maskedIds = <String>{};
    for (final m in input) {
      if (m is AssistantMessage) {
        for (final c in m.toolCalls) {
          if (maskTool(c.name)) maskedIds.add(c.id);
        }
      }
    }
    if (maskedIds.isEmpty) return input;
    return [
      for (final m in input)
        if (m is AssistantMessage && m.toolCalls.any((c) => maskedIds.contains(c.id)))
          AssistantMessage(
            content: m.content,
            toolCalls: [
              for (final c in m.toolCalls)
                maskedIds.contains(c.id)
                    ? AssembledToolCall(
                        id: c.id, name: kSyntheticMaskedTool, argumentsJson: '{}')
                    : c,
            ],
          )
        else if (m is ToolResultMessage && maskedIds.contains(m.toolCallId))
          ToolResultMessage(
            toolCallId: m.toolCallId,
            content: kSyntheticMaskedNotice,
            isError: false,
          )
        else
          m,
    ];
  }
}
