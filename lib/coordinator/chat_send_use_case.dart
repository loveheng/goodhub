/// 发送链路用例（施工稿 `docs/design/arch-consolidation.md` §S3）。
///
/// 从 `chat_page._sendGuarded` 下沉的 **Run 时序**：编排计划 → 事件消费 →
/// 会话写回 → 收口释放。窗口层只保留两件事：实现 [ChatRunSink]（把事件映射成
/// 轨道与状态带）与生命周期转发（PopScope / Abort）。
///
/// 纪律：本件**纯 Dart**（禁 `package:flutter`），可被 headless 路径复用；
/// 取消经 [ChatSendUseCase.cancel]，由它统一持有「已装配但未收口」的句柄。
library;

import 'dart:io';
import '../llm/cloud/cloud_llm.dart';
import '../sandbox/memory_store.dart';
import 'agent_loop.dart';
import 'cow_sync.dart';
import 'degradation_controller.dart';
import '../mcp/local_plugin_discovery.dart';
import '../mcp/server_endpoints.dart';
import '../mcp/sampling.dart' show SamplingQuota;
import 'task_plan.dart' show PlanRunState;
import 'mcp_tool_face.dart';
import 'resource_attachment_binder.dart' show ResourceAttachment;
import 'chat_run_orchestrator.dart';
import 'mcp_runtime.dart';
import 'skill_registry.dart';
import 'user_prompt_store.dart';

/// 窗口侧渲染端口（UI 实现，内核只发事件）。
abstract interface class ChatRunSink {
  /// 思考流增量（默认收起的思考轨）。
  void onThinking(String text);

  /// 正文增量（流控缓冲在 UI 侧）。
  void onText(String text);

  /// 工具调用起步。
  void onCallStarted(AssembledToolCall call);

  /// 工具进度。
  void onCallProgress(
    AssembledToolCall call,
    num progress,
    num? total,
    String? message,
  );

  /// 工具结果回填（`isError` 与「用户拒绝」语义由 UI 决定呈现）。
  void onCallFinished(AssembledToolCall call, ToolExecutionResult result);

  /// 收尾：模型自然结算或中断收口。transcript 为本 Run 末态（未配对尾巴已截）。
  void onFinished(String text, List<CloudChatMessage> transcript);
}

class ChatSendUseCase {
  ChatSendUseCase({required this.sink, required this.orchestrator});

  final ChatRunSink sink;
  final ChatRunOrchestrator orchestrator;

  /// 当前在途装配（取消与收口的唯一锚点；Run 结束即置空）。
  /// 装配期（[assembleRun] 返回）即置位，使连接期预中止可经 [cancel] 触达。
  McpAssembly? _active;

  /// 取消本次发送（UI Abort / PopScope 均转为调用此）。幂等：无在途 Run 即 no-op。
  void cancel({String reason = 'user abort'}) => _active?.abort(reason: reason);

  /// 执行一个完整 Run。异常**上抛**由调用方（窗口）转为错误卡；无论成败都在
  /// finally 收口（编排件 markRunEnded + 内核 close 释放）。
  Future<void> run({
    required McpAssembly assembly,
    required ConversationSession session,
    required MemoryStore memoryStore,
    required String conversationId,
    required List<CloudChatMessage> transcript,
    required SkillRegistry skills,
    required String baseSystemPrompt,
    required String userPrompt,
    required void Function(
      String key,
      String value,
      String action,
      String scope,
      void Function() undo,
    ) onCapsule,
    required void Function(String key, String scope)? onWriteFailure,
    required void Function(String? slotNotice) onSlotNotice,
    required void Function(ChatRunPlan plan) onAttribution,
  }) async {
    _active = assembly;
    try {
      final plan = await orchestrator.plan(
        assembly: assembly,
        memoryStore: memoryStore,
        wsStates: session.wsStates,
        conversationId: conversationId,
        transcript: transcript,
        skills: skills,
        baseSystemPrompt: baseSystemPrompt,
        onCapsule: onCapsule,
        onWriteFailure: onWriteFailure,
      );
      if (plan.slotNotice != null) onSlotNotice(plan.slotNotice);
      onAttribution(plan);

      await for (final e in assembly.loop.run(
        systemPrompt: plan.systemPrompt,
        systemTail: plan.memSection,
        contextFooter: plan.contextFooter,
        userPrompt: (assembly.resourceContextFooter ?? '') + userPrompt,
        history: List.of(transcript),
        workspaceFilter: plan.workspaceFilter,
        maskTool: plan.maskTool,
        tools: const [],
      )) {
        switch (e) {
          case LoopThinkingDelta(:final text):
            sink.onThinking(text);
          case LoopTextDelta(:final text):
            sink.onText(text);
          case LoopToolCallStarted(:final call):
            sink.onCallStarted(call);
          case LoopToolProgress(
            :final call,
            :final progress,
            :final total,
            :final message,
          ):
            sink.onCallProgress(call, progress, total, message);
          case LoopToolCallFinished(:final call, :final result):
            sink.onCallFinished(call, result);
          case LoopFinished(:final text, :final transcript):
            sink.onFinished(text, transcript);
        }
      }
      // 会话绑定捕获：模型可能经 use_server/activate 改写私有槽位，收尾落元数据。
      orchestrator.writebackSlot(router: assembly.router, session: session);
    } finally {
      orchestrator.markRunEnded();
      await assembly.close();
      if (identical(_active, assembly)) _active = null;
    }
  }

  /// S3 二期：装配段下沉（原 `chat_page` 内联段）——skills 装载（注册闸降噪
  /// 经 [onNoticeOnce] 回窗口）、会话绑定、`McpRuntime.assemble`。
  ///
  /// 信任闸门（本地插件信任卡片）是 UI——窗口先裁出 [mountedLocals] 再传，
  /// 内核只挂载（§7.1 纪律）。
  Future<AssembledChatRun> assembleRun({
    required ConversationSession session,
    required SessionContext sessionContext,
    required List<ServerEndpoint> endpoints,
    required List<LocalPluginInfo> mountedLocals,
    required ServerEndpointStore epStore,
    required String supportPath,
    required Future<Directory> Function() documentsDirResolver,
    required RuntimeDelegates delegates,
    required SamplingQuota quota,
    CloudLlmEngine? engine,
    List<ResourceAttachment> resourceAttachments = const [],
    Map<String, McpToolFace> sharedFaces = const {},
    PlanRunState? planState,
    void Function()? onSamplingBegin,
    void Function()? onSamplingEnd,
    Future<UserGlobalPromptsStore> Function()? userPromptStoreProvider,
    Future<CowOverridesStore> Function()? cowStoreProvider,
    required void Function(String key, String message) onNoticeOnce,
  }) async {
    final memoryStore = MemoryStore.underSupportDir(supportPath);
    final existingSkills = session.skills;
    final baseSkills = existingSkills != null
        ? BaseSkillRegistry(registry: existingSkills, skipped: const [])
        : await buildBaseSkillRegistry(
            dirResolver: documentsDirResolver,
            storeProvider: userPromptStoreProvider,
          );
    for (final skip in baseSkills.skipped) {
      // P0-3 降噪：同会话同条目只告一次（键随条目变则再告——窗口裁决）。
      onNoticeOnce('skill-skip:$skip', '⚠ 全局 Prompt 注册跳过: $skip');
    }
    session.bindSkills(baseSkills.registry);
    session.bindDegradation(session.degradation ?? DegradationController());
    final assembly = await const McpRuntime().assemble(
      engine: engine,
      resourceAttachments: resourceAttachments,
      sharedFaces: sharedFaces,
      context: sessionContext,
      endpoints: endpoints,
      locals: mountedLocals,
      apiKeyReader: epStore.apiKey,
      memoryStore: memoryStore,
      skills: session.skills!,
      delegates: delegates,
      quota: quota,
      cowStoreProvider: cowStoreProvider,
      planState: planState,
      onSamplingBegin: onSamplingBegin,
      onSamplingEnd: onSamplingEnd,
    );
    // 取消锚点前置：装配完成即可经 [cancel] 中止（含连接期预中止，F19），
    // 与窗口原 `_activeAssembly?.abort()` 语义等价（run 期再置一次，幂等）。
    _active = assembly;
    return (assembly: assembly, memoryStore: memoryStore);
  }
}

/// 装配产物（Run 输入）。
typedef AssembledChatRun = ({McpAssembly assembly, MemoryStore memoryStore});
